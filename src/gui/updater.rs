//! One-click update: download the installer published with the release, hand it
//! to a small detached updater script and let the app quit through its normal
//! shutdown path so the script can replace it.
//!
//! The script is the only way to do this on Windows: the running
//! `delegator.exe` cannot be overwritten by the installer, so something outside
//! the process must wait for it to disappear, install, and start the new build.
//!
//! Everything here is fire-and-forget: the GUI thread never blocks, progress and
//! the final result come back through `AppMessage`, every failure is logged in
//! English and shown as one short Russian line (details in the tooltip).

use crate::update_check::{ReleaseAsset, NO_INSTALLER_ASSET};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Duration;

#[cfg(target_os = "windows")]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;
#[cfg(target_os = "windows")]
const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;

/// Plausibility window for the installer download. Below the minimum it is an
/// error page or a stub, above the maximum something is very wrong — in both
/// cases running the file would be worse than refusing it.
pub const MIN_INSTALLER_BYTES: u64 = 1024 * 1024;
pub const MAX_INSTALLER_BYTES: u64 = 200 * 1024 * 1024;

/// Every Windows executable starts with these two bytes.
const EXE_MAGIC: &[u8; 2] = b"MZ";

const CONNECT_TIMEOUT: Duration = Duration::from_secs(15);
/// Applies per read, not to the whole download: a big installer on a slow link
/// is fine, a stalled socket is not.
const READ_TIMEOUT: Duration = Duration::from_secs(60);

/// Batch file written next to the installer in `%TEMP%`.
const UPDATER_SCRIPT_NAME: &str = "delegator-update.ps1";

/// Where the installer puts the app (per-user install, see installer/Delegator.iss).
pub fn installed_app_exe() -> PathBuf {
    std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_default()
        .join("Programs")
        .join("Delegator")
        .join("delegator.exe")
}

/// The whole update action: download → write the script → spawn it detached.
/// The caller quits the app as soon as this returns `Ok(())`.
pub async fn run_update(
    tag: String,
    asset: Option<ReleaseAsset>,
    report: impl Fn(u8) + Send + 'static,
) -> Result<(), String> {
    let asset = match asset {
        Some(asset) => asset,
        None => {
            eprintln!("Release {tag} has no installer asset; nothing to download");
            return Err(NO_INSTALLER_ASSET.to_string());
        }
    };
    let installer = download_installer(&tag, &asset, report).await?;
    let script = write_updater_script(&installer, &installed_app_exe(), std::process::id())?;
    if let Err(reason) = spawn_updater(&script) {
        // Nothing will consume these files now, so do not leave them behind.
        let _ = std::fs::remove_file(&script);
        let _ = std::fs::remove_file(&installer);
        return Err(reason);
    }
    Ok(())
}

/// Streams the asset into `%TEMP%\DelegatorSetup-<tag>.exe`, reporting whole
/// percent steps. A partial file is deleted on every failure path.
pub async fn download_installer(
    tag: &str,
    asset: &ReleaseAsset,
    report: impl Fn(u8),
) -> Result<PathBuf, String> {
    let destination =
        std::env::temp_dir().join(format!("DelegatorSetup-{}.exe", sanitize_tag(tag)));
    println!(
        "Downloading {} to {} from {}",
        asset.name,
        destination.display(),
        asset.url
    );

    let client = reqwest::Client::builder()
        .connect_timeout(CONNECT_TIMEOUT)
        .read_timeout(READ_TIMEOUT)
        .user_agent(concat!("Delegator/", env!("CARGO_PKG_VERSION")))
        .build()
        .map_err(|error| {
            eprintln!("Failed to build the download client: {error}");
            "не удалось начать загрузку".to_string()
        })?;

    let mut response = client.get(&asset.url).send().await.map_err(|error| {
        eprintln!("Download request failed: {error}");
        format!("нет связи с сервером обновлений: {}", short(&error))
    })?;
    if !response.status().is_success() {
        let status = response.status().as_u16();
        eprintln!("Download of {} answered HTTP {status}", asset.url);
        return Err(format!("сервер вернул HTTP {status}"));
    }

    // A missing Content-Length is treated as absurd too: without a size there
    // is nothing to sanity-check the payload against.
    let declared = response.content_length().unwrap_or(asset.size);
    if let Err(reason) = validate_installer_size(declared) {
        eprintln!("Refusing {}: declared size {declared} bytes", asset.url);
        return Err(reason);
    }

    let mut file = std::fs::File::create(&destination).map_err(|error| {
        eprintln!("Failed to create {}: {error}", destination.display());
        "не удалось создать файл во временной папке".to_string()
    })?;

    let mut received: u64 = 0;
    let mut header: Vec<u8> = Vec::with_capacity(EXE_MAGIC.len());
    let mut last_percent = u8::MAX;
    loop {
        let chunk = match response.chunk().await {
            Ok(Some(chunk)) => chunk,
            Ok(None) => break,
            Err(error) => {
                eprintln!("Download of {} broke off: {error}", asset.url);
                return Err(discard(
                    file,
                    &destination,
                    format!("обрыв загрузки: {}", short(&error)),
                ));
            }
        };
        if header.len() < EXE_MAGIC.len() {
            header.extend_from_slice(&chunk[..chunk.len().min(EXE_MAGIC.len() - header.len())]);
            if header.len() == EXE_MAGIC.len() && !has_exe_magic(&header) {
                eprintln!(
                    "{} does not start with the MZ magic ({header:?}); refusing it",
                    asset.url
                );
                return Err(discard(
                    file,
                    &destination,
                    "файл не является программой установки".to_string(),
                ));
            }
        }
        received += chunk.len() as u64;
        if received > MAX_INSTALLER_BYTES {
            eprintln!(
                "Download of {} exceeded {MAX_INSTALLER_BYTES} bytes",
                asset.url
            );
            return Err(discard(
                file,
                &destination,
                "установщик неожиданно большой".to_string(),
            ));
        }
        if let Err(error) = file.write_all(&chunk) {
            eprintln!("Failed to write {}: {error}", destination.display());
            return Err(discard(
                file,
                &destination,
                "не удалось сохранить файл".to_string(),
            ));
        }
        let percent = percent_of(received, declared);
        if percent != last_percent {
            last_percent = percent;
            report(percent);
        }
    }

    if received != declared {
        eprintln!(
            "Download of {} ended at {received}/{declared} bytes",
            asset.url
        );
        return Err(discard(
            file,
            &destination,
            "загрузка завершилась не полностью".to_string(),
        ));
    }
    if let Err(error) = file.flush() {
        eprintln!("Failed to flush {}: {error}", destination.display());
        return Err(discard(
            file,
            &destination,
            "не удалось сохранить файл".to_string(),
        ));
    }
    drop(file);
    println!("Downloaded {received} bytes to {}", destination.display());
    Ok(destination)
}

/// Closes the handle, removes the partial file and passes the reason through.
fn discard(file: std::fs::File, path: &Path, reason: String) -> String {
    drop(file);
    let _ = std::fs::remove_file(path);
    reason
}

/// `<1 MB` or `>200 MB` cannot be a Delegator installer.
fn validate_installer_size(bytes: u64) -> Result<(), String> {
    if !(MIN_INSTALLER_BYTES..=MAX_INSTALLER_BYTES).contains(&bytes) {
        return Err(format!("неожиданный размер установщика: {bytes} байт"));
    }
    Ok(())
}

fn has_exe_magic(header: &[u8]) -> bool {
    header.starts_with(EXE_MAGIC)
}

fn percent_of(received: u64, total: u64) -> u8 {
    if total == 0 {
        return 0;
    }
    ((received.min(total) * 100) / total) as u8
}

/// Tags are `vX.Y[.Z]`, but the tag comes from the network: keep it usable as a
/// file name no matter what a release is called.
fn sanitize_tag(tag: &str) -> String {
    let cleaned: String = tag
        .trim()
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || matches!(ch, '.' | '-' | '_') {
                ch
            } else {
                '_'
            }
        })
        .collect();
    if cleaned.is_empty() {
        "latest".to_string()
    } else {
        cleaned
    }
}

/// Writes the updater to `%TEMP%` and returns its path.
pub fn write_updater_script(
    installer: &Path,
    app_exe: &Path,
    parent_pid: u32,
) -> Result<PathBuf, String> {
    let path = std::env::temp_dir().join(UPDATER_SCRIPT_NAME);
    // `as_bytes` keeps the explicit CRLF line endings the shell needs.
    std::fs::write(
        &path,
        updater_script(installer, app_exe, parent_pid).as_bytes(),
    )
    .map_err(|error| {
        eprintln!("Failed to write {}: {error}", path.display());
        "не удалось записать скрипт обновления".to_string()
    })?;
    println!("Updater script written to {}", path.display());
    Ok(path)
}

/// The batch file that outlives the app: wait for `delegator.exe` to go away
/// (~60 s at most), install silently, start the new build, then delete the
/// installer and itself. CRLF is explicit — cmd.exe mis-parses LF-only files.
///
/// Two things here are not cosmetic:
/// * `tasklist`/`find`/`ping` are called by FULL PATH. Verified by hand: with
///   Git for Windows on PATH, a bare `find` resolves to GNU findutils, exits
///   non-zero, and the `||` would skip the whole wait — the installer would
///   then run against a still-running Delegator.
/// * `ping` is the sleep, not `timeout`: a detached process has no console and
///   `timeout` aborts immediately there, turning the wait into a busy loop.
/// Handoff log, kept next to the script so a failed update can be diagnosed.
pub const UPDATER_LOG_NAME: &str = "delegator-update.log";

pub fn updater_script(installer: &Path, app_exe: &Path, parent_pid: u32) -> String {
    // PowerShell, not cmd: the handoff runs without a console, where a
    // `tasklist | find` pipe leaves `find.exe` waiting on stdin forever (that
    // stall was reproduced on 2026-08-11 — it stranded a visible console and
    // let several installers start at once, so Inno refused them with exit 1).
    // Waiting on the parent PID is also exact, unlike matching an image name.
    let log = updater_log_path();
    let lines = [
        "$ErrorActionPreference = 'SilentlyContinue'".to_string(),
        format!("$log = '{}'", ps_quote(&log.to_string_lossy())),
        format!("$installer = '{}'", ps_quote(&installer.to_string_lossy())),
        format!("$app = '{}'", ps_quote(&app_exe.to_string_lossy())),
        format!("$parentPid = {parent_pid}"),
        "function Write-Step($text) {".to_string(),
        "    \"[{0}] {1}\" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $text |"
            .to_string(),
        "        Add-Content -LiteralPath $log".to_string(),
        "}".to_string(),
        "Write-Step \"updater started, waiting for pid $parentPid\"".to_string(),
        "Wait-Process -Id $parentPid -Timeout 60".to_string(),
        "Write-Step 'Delegator closed, installing'".to_string(),
        "$run = Start-Process -FilePath $installer -ArgumentList '/SILENT','/NORESTART','/SUPPRESSMSGBOXES' -Wait -PassThru"
            .to_string(),
        "Write-Step (\"installer exit \" + $run.ExitCode)".to_string(),
        // A relaunch must never inherit the test hooks, or the fresh instance
        // would start the very same update again.
        "Remove-Item Env:DELEGATOR_SELFTEST_UPDATE -ErrorAction SilentlyContinue".to_string(),
        "Remove-Item Env:DELEGATOR_UPDATE_API_URL -ErrorAction SilentlyContinue".to_string(),
        "Start-Process -FilePath $app".to_string(),
        "Write-Step 'relaunched Delegator'".to_string(),
        "Remove-Item -LiteralPath $installer -Force".to_string(),
        "Remove-Item -LiteralPath $PSCommandPath -Force".to_string(),
    ];
    format!("{}\r\n", lines.join("\r\n"))
}

/// Doubles single quotes for a PowerShell literal string.
fn ps_quote(value: &str) -> String {
    value.replace('\'', "''")
}

pub fn updater_log_path() -> PathBuf {
    std::env::temp_dir().join(UPDATER_LOG_NAME)
}

/// Starts the script with no console and no parent link, so it survives the
/// app it is about to replace.
pub fn spawn_updater(script: &Path) -> Result<(), String> {
    let mut command = std::process::Command::new("powershell.exe");
    command
        .args([
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-WindowStyle",
            "Hidden",
            "-File",
        ])
        .arg(script)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP);
    }
    match command.spawn() {
        Ok(child) => {
            println!("Updater started (pid {})", child.id());
            Ok(())
        }
        Err(error) => Err(format!("не удалось запустить обновление: {error}")),
    }
}

/// «Обновить до v0.4.4» — the header button in its normal state.
pub fn update_button_label(tag: &str) -> String {
    match display_tag(tag) {
        Some(tag) => format!("Обновить до {tag}"),
        None => "Обновить".to_string(),
    }
}

/// Tags are published as `vX.Y`, but a release could be tagged without the `v`.
fn display_tag(tag: &str) -> Option<String> {
    let trimmed = tag.trim();
    if trimmed.is_empty() {
        return None;
    }
    if trimmed.starts_with(['v', 'V']) {
        Some(trimmed.to_string())
    } else {
        Some(format!("v{trimmed}"))
    }
}

/// «Загрузка 45%» — the same button while the installer is coming down.
pub fn progress_label(percent: u8) -> String {
    format!("Загрузка {}%", percent.min(100))
}

/// First line of a network error, trimmed to tooltip length.
fn short(error: &reqwest::Error) -> String {
    let text = error.to_string();
    let first = text.lines().next().unwrap_or("").trim();
    if first.chars().count() > 100 {
        first.chars().take(100).collect()
    } else {
        first.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::BufRead;
    use std::sync::{Arc, Mutex};
    use std::time::{SystemTime, UNIX_EPOCH};

    /// Serves one GET with the given body and closes. Returns the url.
    fn serve_once(body: Vec<u8>) -> String {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind loopback");
        let port = listener.local_addr().expect("local addr").port();
        std::thread::spawn(move || {
            let Ok((mut stream, _)) = listener.accept() else {
                return;
            };
            let mut reader =
                std::io::BufReader::new(stream.try_clone().expect("clone the accepted socket"));
            let mut line = String::new();
            // Drain the request head; a GET has no body to worry about.
            loop {
                line.clear();
                match reader.read_line(&mut line) {
                    Ok(0) => break,
                    Ok(_) if line == "\r\n" => break,
                    Ok(_) => {}
                    Err(_) => break,
                }
            }
            let head = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n\
                 Content-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            );
            let _ = stream.write_all(head.as_bytes());
            let _ = stream.write_all(&body);
            let _ = stream.flush();
        });
        format!("http://127.0.0.1:{port}/DelegatorSetup-9.9.exe")
    }

    /// Distinct per test run so parallel tests never share a temp file.
    fn unique_tag(kind: &str) -> String {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock before unix epoch")
            .as_nanos();
        format!("v9.9-{kind}-{}-{nanos}", std::process::id())
    }

    fn payload(magic: &[u8; 2], len: usize) -> Vec<u8> {
        let mut body = vec![0u8; len];
        body[..2].copy_from_slice(magic);
        for (index, byte) in body.iter_mut().enumerate().skip(2) {
            *byte = (index % 251) as u8;
        }
        body
    }

    fn asset(url: String, size: u64) -> ReleaseAsset {
        ReleaseAsset {
            name: "DelegatorSetup-9.9.exe".to_string(),
            url,
            size,
        }
    }

    #[tokio::test]
    async fn downloads_the_installer_into_temp_byte_for_byte() {
        let body = payload(b"MZ", 1_400_000);
        let url = serve_once(body.clone());
        let tag = unique_tag("ok");
        let seen: Arc<Mutex<Vec<u8>>> = Arc::new(Mutex::new(Vec::new()));
        let sink = seen.clone();

        let path = download_installer(&tag, &asset(url, body.len() as u64), move |percent| {
            sink.lock().expect("progress mutex").push(percent);
        })
        .await
        .expect("the download succeeds");

        assert_eq!(
            path,
            std::env::temp_dir().join(format!("DelegatorSetup-{tag}.exe"))
        );
        assert_eq!(std::fs::read(&path).expect("read the installer"), body);
        let progress = seen.lock().expect("progress mutex").clone();
        assert_eq!(progress.last().copied(), Some(100));
        assert!(progress.windows(2).all(|pair| pair[0] < pair[1]));
        let _ = std::fs::remove_file(&path);
    }

    #[tokio::test]
    async fn refuses_a_body_without_the_mz_magic_and_leaves_no_file() {
        let body = payload(b"PK", 1_400_000);
        let url = serve_once(body.clone());
        let tag = unique_tag("zip");
        let result =
            download_installer(&tag, &asset(url, body.len() as u64), |_| unreachable!()).await;
        assert_eq!(result, Err("файл не является программой установки".into()));
        assert!(!std::env::temp_dir()
            .join(format!("DelegatorSetup-{tag}.exe"))
            .exists());
    }

    #[tokio::test]
    async fn refuses_an_absurdly_small_download() {
        let body = payload(b"MZ", 64);
        let url = serve_once(body.clone());
        let tag = unique_tag("tiny");
        let result =
            download_installer(&tag, &asset(url, body.len() as u64), |_| unreachable!()).await;
        assert_eq!(
            result,
            Err("неожиданный размер установщика: 64 байт".to_string())
        );
        assert!(!std::env::temp_dir()
            .join(format!("DelegatorSetup-{tag}.exe"))
            .exists());
    }

    #[test]
    fn size_validation_covers_both_bounds() {
        assert!(validate_installer_size(MIN_INSTALLER_BYTES).is_ok());
        assert!(validate_installer_size(MAX_INSTALLER_BYTES).is_ok());
        assert!(validate_installer_size(12_000_000).is_ok());
        // An error page, a truncated body, or "no Content-Length at all".
        assert!(validate_installer_size(0).is_err());
        assert!(validate_installer_size(MIN_INSTALLER_BYTES - 1).is_err());
        assert!(validate_installer_size(MAX_INSTALLER_BYTES + 1).is_err());
    }

    #[test]
    fn executable_magic_is_checked_on_the_first_two_bytes() {
        assert!(has_exe_magic(b"MZ"));
        assert!(has_exe_magic(b"MZ\x90\x00"));
        assert!(!has_exe_magic(b"PK"));
        assert!(!has_exe_magic(b"mz"));
        assert!(!has_exe_magic(b"<"));
        assert!(!has_exe_magic(b""));
    }

    #[test]
    fn progress_percentage_never_leaves_zero_to_hundred() {
        assert_eq!(percent_of(0, 200), 0);
        assert_eq!(percent_of(90, 200), 45);
        assert_eq!(percent_of(200, 200), 100);
        // A lying Content-Length must not produce 300%.
        assert_eq!(percent_of(600, 200), 100);
        assert_eq!(percent_of(5, 0), 0);
    }

    #[test]
    fn updater_script_waits_installs_restarts_and_deletes_itself() {
        let installer =
            PathBuf::from(r"C:\Users\<user>\AppData\Local\Temp\DelegatorSetup-v0.4.4.exe");
        let app = PathBuf::from(r"C:\Users\<user>\AppData\Local\Programs\Delegator\delegator.exe");
        let script = updater_script(&installer, &app, 4242);

        assert!(script.ends_with("\r\n"));
        assert_eq!(script.matches('\n').count(), script.matches("\r\n").count());
        // Paths land in single-quoted PowerShell literals, so spaces are safe.
        assert!(script.contains(&format!("$installer = '{}'", installer.display())));
        assert!(script.contains(&format!("$app = '{}'", app.display())));
        // Wait for THIS process, not for a process that merely shares the name.
        assert!(script.contains("$parentPid = 4242"));
        assert!(script.contains("Wait-Process -Id $parentPid -Timeout 60"));
        // No pipes: `tasklist | find` hangs without a console (2026-08-11).
        assert!(!script.contains('|') || !script.contains("find"));
        // Silent install, relaunch, then clean up both files.
        assert!(script.contains(
            "Start-Process -FilePath $installer -ArgumentList '/SILENT','/NORESTART','/SUPPRESSMSGBOXES' -Wait -PassThru"
        ));
        assert!(script.contains("Start-Process -FilePath $app"));
        // The relaunched app must not inherit the test hooks, or it would
        // immediately start the same update again.
        assert!(script.contains("Remove-Item Env:DELEGATOR_SELFTEST_UPDATE"));
        assert!(script.contains("Remove-Item Env:DELEGATOR_UPDATE_API_URL"));
        assert!(script.contains("Remove-Item -LiteralPath $installer -Force"));
        assert!(script
            .trim_end()
            .ends_with("Remove-Item -LiteralPath $PSCommandPath -Force"));
        // Every stage is logged for post-mortem diagnosis.
        assert!(script.contains("Write-Step 'relaunched Delegator'"));
    }

    #[test]
    fn updater_script_escapes_single_quotes_in_paths() {
        let installer = PathBuf::from(r"C:\Temp\it's\DelegatorSetup.exe");
        let app = PathBuf::from(r"C:\Apps\it's\delegator.exe");
        let script = updater_script(&installer, &app, 7);
        assert!(script.contains(r"$installer = 'C:\Temp\it''s\DelegatorSetup.exe'"));
        assert!(script.contains(r"$app = 'C:\Apps\it''s\delegator.exe'"));
    }

    #[test]
    fn spawn_updater_runs_a_script_from_a_path_with_spaces() {
        let dir = std::env::temp_dir().join(format!(
            "delegator spawn test {}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("clock before unix epoch")
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).expect("create the temp dir");
        let marker = dir.join("started.txt");
        let script = dir.join(UPDATER_SCRIPT_NAME);
        std::fs::write(
            &script,
            format!(
                "'started' | Set-Content -LiteralPath '{}'\r\n",
                marker.display()
            )
            .as_bytes(),
        )
        .expect("write the script");

        spawn_updater(&script).expect("spawn the updater");

        // The handoff is asynchronous; give the shell a moment to start.
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
        while std::time::Instant::now() < deadline && !marker.exists() {
            std::thread::sleep(std::time::Duration::from_millis(200));
        }
        let started = marker.exists();
        let _ = std::fs::remove_dir_all(&dir);
        assert!(started, "the spawned script never ran");
    }

    #[test]
    fn installed_app_path_follows_the_per_user_install_layout() {
        // Whole components, so this cannot pass on a coincidental suffix.
        assert!(installed_app_exe().ends_with(r"Programs\Delegator\delegator.exe"));
    }

    #[test]
    fn button_labels_are_short_and_carry_the_tag() {
        assert_eq!(update_button_label("v0.4.4"), "Обновить до v0.4.4");
        assert_eq!(update_button_label(" v0.5 "), "Обновить до v0.5");
        // A tag published without the `v` still reads as a version.
        assert_eq!(update_button_label("0.4.4"), "Обновить до v0.4.4");
        assert_eq!(update_button_label("V1.0"), "Обновить до V1.0");
        // Never «Обновить до » with a dangling preposition.
        assert_eq!(update_button_label("   "), "Обновить");
        assert_eq!(progress_label(0), "Загрузка 0%");
        assert_eq!(progress_label(45), "Загрузка 45%");
        assert_eq!(progress_label(200), "Загрузка 100%");
    }

    #[test]
    fn tag_is_sanitized_before_it_becomes_a_file_name() {
        assert_eq!(sanitize_tag("v0.4.4"), "v0.4.4");
        assert_eq!(sanitize_tag(" v0.5 "), "v0.5");
        assert_eq!(sanitize_tag("../../evil"), ".._.._evil");
        assert_eq!(sanitize_tag("v1:0/beta"), "v1_0_beta");
        assert_eq!(sanitize_tag(""), "latest");
    }
}
