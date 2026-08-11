//! OpenCode CLI support for the «Модели OpenCode» tab:
//! * strength ordering of the Zen (`opencode/*`) block,
//! * background install of the missing dependencies (winget/npm chain),
//! * background update (`opencode upgrade`),
//! * the manual-download fallback links.
//!
//! Everything here is fire-and-forget: the GUI thread never blocks, results
//! come back through `AppMessage`, and every failure is logged in English and
//! surfaced as a short Russian line in the tab.

use crate::config::runtime_home_dir;
use crate::models_service::ModelInfo;
use serde::Deserialize;
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

#[cfg(target_os = "windows")]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// npm cold-installs and OpenCode self-updates can legitimately take minutes
/// on a slow link; the timeout only guards against a wedged child.
const CLI_JOB_TIMEOUT: Duration = Duration::from_secs(600);

/// Strength catalog written by the PowerShell runtime
/// (`update-free-models.ps1`, refreshed inline by `opencode-delegate.ps1`).
const ZEN_CATALOG_FILE: &str = "opencode-zen-catalog.json";

/// `<RT>\opencode-zen-catalog.json`: `{version, updatedAt, models:[{id,strength}]}`.
#[derive(Debug, Deserialize)]
struct ZenCatalogFile {
    #[serde(default)]
    models: Vec<ZenCatalogEntry>,
}

#[derive(Debug, Deserialize)]
struct ZenCatalogEntry {
    id: String,
    #[serde(default)]
    strength: Option<i32>,
}

/// Reads the runtime's strength catalog. A missing or corrupt file is not an
/// error — the caller then falls back to `zen_strength` per id.
pub fn load_zen_strengths() -> HashMap<String, i32> {
    load_zen_strengths_from(&runtime_home_dir())
}

fn load_zen_strengths_from(runtime_home: &Path) -> HashMap<String, i32> {
    let path = runtime_home.join(ZEN_CATALOG_FILE);
    let Ok(content) = fs::read_to_string(&path) else {
        return HashMap::new();
    };
    match serde_json::from_str::<ZenCatalogFile>(&content) {
        Ok(catalog) => catalog
            .models
            .into_iter()
            .filter_map(|entry| Some((entry.id, entry.strength?)))
            .collect(),
        Err(error) => {
            eprintln!("Failed to parse {}: {error}", path.display());
            HashMap::new()
        }
    }
}

/// Heuristic strength score of a Zen alias, mirroring `Get-ZenModelStrength`
/// in scripts/update-free-models.ps1 and scripts/opencode-delegate.ps1 (Zen
/// publishes no size or benchmark metadata for its free aliases).
///
/// DUPLICATION IS DELIBERATE: the runtime scores in PowerShell, the GUI needs
/// the same order before the runtime has ever written its catalog file. Keep
/// all three copies (and the ROADMAP description) in sync.
///
/// Scoring: base 50; the strongest matching positive qualifier ONLY —
/// ultra +40, pro/max +30, large/big +20, flash/standard +10; cumulative
/// negatives mini −20, tiny/nano/lite −30; plus the major version digit 1-9
/// when it appears as its own name part ("v2.5" → +2, "-3.0-" → +3).
/// Qualifiers count only as whole `-`/`_`/`.`-separated parts of the alias.
pub fn zen_strength(id: &str) -> i32 {
    let slug = match id.get(..9) {
        Some(prefix) if prefix.eq_ignore_ascii_case("opencode/") => &id[9..],
        _ => id,
    };
    let parts: Vec<String> = slug
        .split(['-', '_', '.'])
        .filter(|part| !part.is_empty())
        .map(|part| part.to_ascii_lowercase())
        .collect();
    let has = |word: &str| parts.iter().any(|part| part == word);

    let mut score = 50;
    if has("ultra") {
        score += 40;
    } else if has("pro") || has("max") {
        score += 30;
    } else if has("large") || has("big") {
        score += 20;
    } else if has("flash") || has("standard") {
        score += 10;
    }
    if has("mini") {
        score -= 20;
    }
    if has("tiny") || has("nano") || has("lite") {
        score -= 30;
    }
    if let Some(major) = parts.iter().find_map(|part| major_version_digit(part)) {
        score += major;
    }
    score
}

/// `"v4"`/`"3"` → Some(4)/Some(3); anything longer than one digit (with the
/// optional `v`) is a build number, not a major version — mirrors the
/// PowerShell regex `(^|[-_.])v?([1-9])(\.\d+)?([-_.]|$)`.
fn major_version_digit(part: &str) -> Option<i32> {
    let digits = part.strip_prefix('v').unwrap_or(part);
    let mut chars = digits.chars();
    let first = chars.next()?;
    if chars.next().is_some() {
        return None;
    }
    first
        .to_digit(10)
        .filter(|digit| (1..=9).contains(digit))
        .map(|digit| digit as i32)
}

/// Score used for ordering: the runtime catalog wins (it is what the router
/// actually routes by), the name heuristic covers ids the catalog lacks —
/// including the case where the runtime has never written the file at all.
fn strength_of(id: &str, catalog: &HashMap<String, i32>) -> i32 {
    catalog.get(id).copied().unwrap_or_else(|| zen_strength(id))
}

/// Orders the model list for the tab: the `opencode/*` Zen block first, by
/// strength DESC then id, followed by every other entry (`openrouter/*`) in
/// its existing relative order.
pub fn order_opencode_models(
    models: Vec<ModelInfo>,
    catalog: &HashMap<String, i32>,
) -> Vec<ModelInfo> {
    let (mut zen, rest): (Vec<ModelInfo>, Vec<ModelInfo>) = models
        .into_iter()
        .partition(|model| model.id.starts_with("opencode/"));
    zen.sort_by(|a, b| {
        strength_of(&b.id, catalog)
            .cmp(&strength_of(&a.id, catalog))
            .then_with(|| a.id.cmp(&b.id))
    });
    zen.extend(rest);
    zen
}

/// Which background CLI job produced a result (they share one code path but
/// get different Russian status lines).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CliJob {
    Install,
    Upgrade,
}

/// `Ok(())` on success, `Err(short Russian reason)` otherwise. The full
/// stdout/stderr always goes to the log in English.
pub type CliJobResult = Result<(), String>;

/// Manual fallback when nothing can be installed automatically.
pub const NODEJS_DOWNLOAD_URL: &str = "https://nodejs.org/en/download";
pub const OPENCODE_SITE_URL: &str = "https://opencode.ai";

/// Shown when neither winget nor npm exists, so no chain can even start.
pub const NO_INSTALLER_FOUND: &str = "не найдены winget и npm";

/// One command of the dependency install chain.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InstallStep {
    /// The preferred route: installs the CLI without Node.js at all.
    WingetOpenCode,
    /// Prerequisite of `NpmOpenCode` when npm is missing.
    WingetNodeJs,
    /// The classic route, also the fallback when winget refuses the package.
    NpmOpenCode,
}

impl InstallStep {
    /// The single short Russian line the user sees while the step runs.
    pub fn status_line(self) -> &'static str {
        match self {
            InstallStep::WingetNodeJs => "Устанавливаю Node.js…",
            InstallStep::WingetOpenCode | InstallStep::NpmOpenCode => "Устанавливаю OpenCode CLI…",
        }
    }

    /// Arguments exactly as spawned; the program is located at run time
    /// because PATH may have changed since the previous step.
    pub fn args(self) -> &'static [&'static str] {
        match self {
            InstallStep::WingetOpenCode => &[
                "install",
                "--id",
                "SST.opencode",
                "-e",
                "--silent",
                "--accept-package-agreements",
                "--accept-source-agreements",
            ],
            InstallStep::WingetNodeJs => &[
                "install",
                "--id",
                "OpenJS.NodeJS.LTS",
                "-e",
                "--silent",
                "--accept-package-agreements",
                "--accept-source-agreements",
            ],
            InstallStep::NpmOpenCode => &["install", "-g", "opencode-ai"],
        }
    }

    fn program_name(self) -> &'static str {
        match self {
            InstallStep::WingetOpenCode | InstallStep::WingetNodeJs => "winget",
            InstallStep::NpmOpenCode => "npm",
        }
    }

    /// Node.js is only a prerequisite — succeeding at it does not end the
    /// chain, succeeding at anything else does.
    fn installs_cli(self) -> bool {
        !matches!(self, InstallStep::WingetNodeJs)
    }
}

/// The command line as logged and as spawned (English, for the log only).
pub fn command_line(step: InstallStep) -> String {
    format!("{} {}", step.program_name(), step.args().join(" "))
}

/// Ordered install chain for the tooling found on this machine:
/// * winget → try `SST.opencode` first (no Node.js needed at all);
/// * npm present → `npm install -g opencode-ai` as the fallback;
/// * npm missing but winget present → install Node.js LTS, then npm;
/// * neither → empty, the GUI shows the manual download links instead.
pub fn install_plan(has_winget: bool, has_npm: bool) -> Vec<InstallStep> {
    let mut plan = Vec::new();
    if has_winget {
        plan.push(InstallStep::WingetOpenCode);
    }
    if has_npm {
        plan.push(InstallStep::NpmOpenCode);
    } else if has_winget {
        plan.push(InstallStep::WingetNodeJs);
        plan.push(InstallStep::NpmOpenCode);
    }
    plan
}

/// Runs the chain in the background, reporting the step it is about to start
/// so the tab can keep exactly one status line up to date. Stops at the first
/// step that actually installs the CLI.
pub async fn install_dependencies(
    plan: Vec<InstallStep>,
    report: impl Fn(InstallStep) + Send + 'static,
) -> CliJobResult {
    if plan.is_empty() {
        eprintln!("Neither winget nor npm is available; cannot install the OpenCode CLI");
        return Err(NO_INSTALLER_FOUND.to_string());
    }
    let chain: Vec<String> = plan.iter().map(|step| command_line(*step)).collect();
    println!("Dependency install chain: {}", chain.join(" -> "));

    let mut last_error: Option<String> = None;
    for step in plan {
        report(step);
        match run_install_step(step).await {
            Ok(()) if step.installs_cli() => return Ok(()),
            Ok(()) => {}
            Err(reason) => last_error = Some(reason),
        }
    }
    Err(last_error.unwrap_or_else(|| NO_INSTALLER_FOUND.to_string()))
}

async fn run_install_step(step: InstallStep) -> CliJobResult {
    let program = match step {
        InstallStep::WingetOpenCode | InstallStep::WingetNodeJs => {
            crate::dependency_service::find_winget()
        }
        // Re-resolved on every attempt: a Node.js installed one step ago is
        // not on the running process's PATH, only in %ProgramFiles%\nodejs.
        InstallStep::NpmOpenCode => crate::dependency_service::find_npm(),
    };
    let Some(program) = program else {
        eprintln!("`{}` not found; skipping this step", step.program_name());
        return Err(format!("не найден {}", step.program_name()));
    };
    run_cli_job(&command_line(step), &program, step.args()).await
}

/// Opens a page in the user's browser without flashing a console window.
/// Used only for the two hardcoded fallback links above.
pub fn open_url(url: &str) {
    println!("Opening {url} in the default browser");
    let mut command = std::process::Command::new("cmd");
    command.args(["/c", "start", "", url]);
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    if let Err(error) = command.spawn() {
        eprintln!("Failed to open {url}: {error}");
    }
}

/// `opencode upgrade` in the background: keeps the Zen alias list current, so
/// brand-new free models show up in the tab without user action.
pub async fn upgrade_opencode_cli(cli: PathBuf) -> CliJobResult {
    run_cli_job("opencode upgrade", &cli, &["upgrade"]).await
}

async fn run_cli_job(label: &str, program: &Path, args: &[&str]) -> CliJobResult {
    let mut command = tokio::process::Command::new(program);
    command
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    #[cfg(target_os = "windows")]
    command.creation_flags(CREATE_NO_WINDOW);

    let output = match tokio::time::timeout(CLI_JOB_TIMEOUT, command.output()).await {
        Ok(Ok(output)) => output,
        Ok(Err(error)) => {
            eprintln!("Failed to run `{label}`: {error}");
            return Err("не удалось запустить команду".to_string());
        }
        Err(_) => {
            eprintln!("`{label}` timed out after {}s", CLI_JOB_TIMEOUT.as_secs());
            return Err(format!(
                "превышено время ожидания ({} мин)",
                CLI_JOB_TIMEOUT.as_secs() / 60
            ));
        }
    };

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    if output.status.success() {
        println!("`{label}` finished successfully");
        Ok(())
    } else {
        eprintln!(
            "`{label}` exited with {}\n--- stdout ---\n{}\n--- stderr ---\n{}",
            output.status,
            stdout.trim(),
            stderr.trim()
        );
        Err(short_failure(&stdout, &stderr))
    }
}

/// Last meaningful output line, truncated — enough to tell «нет сети» from
/// «нет прав» without dumping an npm log into the GUI.
fn short_failure(stdout: &str, stderr: &str) -> String {
    let reason = [stderr, stdout]
        .iter()
        .find_map(|stream| {
            stream
                .lines()
                .map(str::trim)
                .filter(|l| !l.is_empty())
                .last()
        })
        .unwrap_or("нет вывода команды");
    truncate_chars(reason, 120)
}

fn truncate_chars(text: &str, max_chars: usize) -> String {
    if text.chars().count() <= max_chars {
        return text.to_string();
    }
    let truncated: String = text.chars().take(max_chars).collect();
    format!("{truncated}…")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    /// The live Zen lineup of OpenCode CLI v1.18.15 with the scores the
    /// PowerShell runtime wrote into `<RT>\opencode-zen-catalog.json`.
    const LIVE_ZEN: [(&str, i32); 8] = [
        ("opencode/nemotron-3-ultra-free", 93),
        ("opencode/big-pickle", 70),
        ("opencode/deepseek-v4-flash-free", 64),
        ("opencode/laguna-s-2.1-free", 52),
        ("opencode/longcat-2.0-free", 52),
        ("opencode/mimo-v2.5-free", 52),
        ("opencode/north-mini-code-free", 30),
        ("opencode/ling-3.0-tiny-free", 23),
    ];

    fn model(id: &str) -> ModelInfo {
        ModelInfo {
            id: id.to_string(),
            name: id.to_string(),
            is_free: true,
            provider: "test".into(),
        }
    }

    #[test]
    fn strength_matches_the_powershell_heuristic_for_the_live_lineup() {
        for (id, expected) in LIVE_ZEN {
            assert_eq!(zen_strength(id), expected, "{id}");
        }
    }

    #[test]
    fn strength_applies_only_the_strongest_qualifier_and_all_penalties() {
        // Only the strongest positive qualifier counts (ultra, not flash).
        assert_eq!(
            zen_strength("opencode/x-ultra-flash-free"),
            50 + 40 + 10 - 10
        );
        assert_eq!(zen_strength("opencode/x-pro-free"), 80);
        assert_eq!(zen_strength("opencode/x-max-free"), 80);
        assert_eq!(zen_strength("opencode/x-large-free"), 70);
        assert_eq!(zen_strength("opencode/x-standard-free"), 60);
        // Penalties are cumulative.
        assert_eq!(zen_strength("opencode/x-mini-lite-free"), 50 - 20 - 30);
        assert_eq!(zen_strength("opencode/x-nano-free"), 20);
        // Qualifiers must be whole name parts, not substrings.
        assert_eq!(zen_strength("opencode/ultramarine-free"), 50);
        assert_eq!(zen_strength("opencode/administrator-free"), 50);
        // Version bump: single leading digit only, `v` optional.
        assert_eq!(zen_strength("opencode/x-v9-free"), 59);
        assert_eq!(zen_strength("opencode/x-70b-free"), 50);
        assert_eq!(zen_strength("opencode/x-v10-free"), 50);
        // The prefix is optional and matched case-insensitively.
        assert_eq!(zen_strength("big-pickle"), 70);
        assert_eq!(zen_strength("OpenCode/big-pickle"), 70);
    }

    #[test]
    fn ordering_sorts_zen_by_strength_and_keeps_openrouter_after_it() {
        // Deliberately scrambled input, incl. two entries that tie at 52.
        let models: Vec<ModelInfo> = [
            "opencode/ling-3.0-tiny-free",
            "openrouter/qwen/qwen-2.5:free",
            "opencode/mimo-v2.5-free",
            "opencode/nemotron-3-ultra-free",
            "openrouter/z-ai/glm-5",
            "opencode/longcat-2.0-free",
            "opencode/big-pickle",
            "opencode/laguna-s-2.1-free",
            "opencode/deepseek-v4-flash-free",
            "opencode/north-mini-code-free",
        ]
        .into_iter()
        .map(model)
        .collect();

        // No catalog file → the heuristic alone must reproduce the live order.
        let ordered = order_opencode_models(models.clone(), &HashMap::new());
        let ids: Vec<&str> = ordered.iter().map(|m| m.id.as_str()).collect();
        assert_eq!(
            ids,
            vec![
                "opencode/nemotron-3-ultra-free",
                "opencode/big-pickle",
                "opencode/deepseek-v4-flash-free",
                // 52-way tie broken by id.
                "opencode/laguna-s-2.1-free",
                "opencode/longcat-2.0-free",
                "opencode/mimo-v2.5-free",
                "opencode/north-mini-code-free",
                "opencode/ling-3.0-tiny-free",
                // openrouter/* keeps its own relative order, after the block.
                "openrouter/qwen/qwen-2.5:free",
                "openrouter/z-ai/glm-5",
            ]
        );

        // A catalog file overrides the heuristic for the ids it lists.
        let catalog: HashMap<String, i32> =
            HashMap::from([("opencode/ling-3.0-tiny-free".to_string(), 999)]);
        let ordered = order_opencode_models(models, &catalog);
        assert_eq!(ordered[0].id, "opencode/ling-3.0-tiny-free");
        assert_eq!(ordered[1].id, "opencode/nemotron-3-ultra-free");
    }

    #[test]
    fn catalog_file_is_read_and_bad_input_degrades_to_the_heuristic() {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock before unix epoch")
            .as_nanos();
        let dir = std::env::temp_dir().join(format!(
            "delegator-zen-catalog-test-{}-{nanos}",
            std::process::id()
        ));
        fs::create_dir_all(&dir).expect("create temp runtime home");

        // Missing file → empty map (callers then use the heuristic).
        assert!(load_zen_strengths_from(&dir).is_empty());

        let real_shape = r#"{"version":1,"updatedAt":"2026-08-10T16:45:38Z","models":[
            {"id":"opencode/nemotron-3-ultra-free","strength":93},
            {"id":"opencode/big-pickle","strength":70},
            {"id":"opencode/no-score-here"}]}"#;
        fs::write(dir.join(ZEN_CATALOG_FILE), real_shape).expect("write catalog");
        let strengths = load_zen_strengths_from(&dir);
        assert_eq!(strengths.len(), 2);
        assert_eq!(strengths["opencode/nemotron-3-ultra-free"], 93);
        // An entry without a score falls back to the heuristic.
        assert_eq!(strength_of("opencode/no-score-here", &strengths), 50);
        assert_eq!(strength_of("opencode/big-pickle", &strengths), 70);

        fs::write(dir.join(ZEN_CATALOG_FILE), "{ not json").expect("write corrupt catalog");
        assert!(load_zen_strengths_from(&dir).is_empty());

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn install_chain_covers_every_combination_of_winget_and_npm() {
        use InstallStep::*;
        // winget alone already installs the CLI without Node.js; npm stays as
        // the fallback for the case winget refuses the package.
        assert_eq!(install_plan(true, true), vec![WingetOpenCode, NpmOpenCode]);
        // No npm: winget must first bring Node.js LTS in, then npm can run.
        assert_eq!(
            install_plan(true, false),
            vec![WingetOpenCode, WingetNodeJs, NpmOpenCode]
        );
        // No winget: only the classic npm route is left.
        assert_eq!(install_plan(false, true), vec![NpmOpenCode]);
        // Nothing to run — the GUI shows the manual download links instead.
        assert_eq!(install_plan(false, false), Vec::new());
    }

    #[test]
    fn install_commands_are_spelled_exactly_as_verified_by_hand() {
        assert_eq!(
            command_line(InstallStep::WingetOpenCode),
            "winget install --id SST.opencode -e --silent \
             --accept-package-agreements --accept-source-agreements"
        );
        assert_eq!(
            command_line(InstallStep::WingetNodeJs),
            "winget install --id OpenJS.NodeJS.LTS -e --silent \
             --accept-package-agreements --accept-source-agreements"
        );
        assert_eq!(
            command_line(InstallStep::NpmOpenCode),
            "npm install -g opencode-ai"
        );
        // Only Node.js is a prerequisite; the other two end the chain.
        assert!(InstallStep::WingetOpenCode.installs_cli());
        assert!(InstallStep::NpmOpenCode.installs_cli());
        assert!(!InstallStep::WingetNodeJs.installs_cli());
        // One short Russian line per step, and only two distinct ones.
        assert_eq!(
            InstallStep::WingetOpenCode.status_line(),
            InstallStep::NpmOpenCode.status_line()
        );
        assert_eq!(
            InstallStep::WingetNodeJs.status_line(),
            "Устанавливаю Node.js…"
        );
    }

    #[test]
    fn manual_fallback_links_point_at_the_official_pages() {
        assert_eq!(NODEJS_DOWNLOAD_URL, "https://nodejs.org/en/download");
        assert_eq!(OPENCODE_SITE_URL, "https://opencode.ai");
    }

    /// An empty plan must fail immediately instead of spawning anything.
    #[tokio::test]
    async fn an_empty_plan_fails_without_spawning_a_process() {
        let result = install_dependencies(Vec::new(), |_| unreachable!("no step may run")).await;
        assert_eq!(result, Err(NO_INSTALLER_FOUND.to_string()));
    }

    #[test]
    fn failure_text_prefers_the_last_stderr_line_and_is_truncated() {
        assert_eq!(
            short_failure(
                "npm WARN deprecated\n",
                "npm ERR! code EACCES\nnpm ERR! syscall mkdir\n"
            ),
            "npm ERR! syscall mkdir"
        );
        // Empty stderr → fall back to stdout.
        assert_eq!(
            short_failure("only stdout here\n", "   \n"),
            "only stdout here"
        );
        assert_eq!(short_failure("", ""), "нет вывода команды");
        let long = "e".repeat(300);
        assert_eq!(short_failure("", &long).chars().count(), 121);
    }
}
