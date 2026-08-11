use serde::Deserialize;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{channel, Receiver, TryRecvError};
use std::time::{Duration, Instant};

#[cfg(target_os = "windows")]
use std::os::windows::process::CommandExt;

const CREATE_NO_WINDOW: u32 = 0x0800_0000;
const CORE_URL: &str = "http://127.0.0.1:1380/health";
/// PyInstaller onefile re-extracts the whole Python runtime on every launch;
/// on cold or AV-scanned machines this alone can take tens of seconds
/// (scripts/test-installed.ps1 budgets 20s), so wait generously.
const HEALTH_WAIT_BUDGET: Duration = Duration::from_secs(45);
const HEALTH_POLL_INTERVAL: Duration = Duration::from_millis(200);
/// How often the GUI-driven supervisor tick actually does work.
const SUPERVISOR_INTERVAL: Duration = Duration::from_millis(2500);
const INITIAL_BACKOFF_SECS: u64 = 1;
const MAX_BACKOFF_SECS: u64 = 30;
/// Consecutive failed health probes (one per supervisor tick) tolerated while
/// the process is still alive before the core is considered hung.
const MAX_CONSECUTIVE_HEALTH_FAILURES: u32 = 8;

#[derive(Deserialize)]
struct HealthResponse {
    ok: bool,
    #[serde(default)]
    service: String,
    #[serde(default)]
    delegate_cmd: String,
}

/// Everything needed to (re)spawn delegator-core.exe.
struct SpawnContext {
    core_exe: PathBuf,
    install_root: PathBuf,
    runtime_dir: PathBuf,
    runtime_home: PathBuf,
    core_home: PathBuf,
    delegate_cmd: PathBuf,
}

impl SpawnContext {
    fn new() -> Result<Self, String> {
        let install_root = install_root()?;
        let core_exe = install_root.join("delegator-core.exe");
        let runtime_dir = install_root.join("runtime");
        let delegate_cmd = runtime_dir.join("ai-delegate.cmd");

        let local_appdata = std::env::var_os("LOCALAPPDATA")
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("APPDATA").map(PathBuf::from))
            .ok_or_else(|| "LOCALAPPDATA/APPDATA is not available".to_string())?;
        let data_root = local_appdata.join("DelegatorWin");
        let runtime_home = data_root.join("runtime");
        let core_home = data_root.join("core");
        std::fs::create_dir_all(&runtime_home).map_err(|e| e.to_string())?;
        std::fs::create_dir_all(&core_home).map_err(|e| e.to_string())?;

        Ok(Self {
            core_exe,
            install_root,
            runtime_dir,
            runtime_home,
            core_home,
            delegate_cmd,
        })
    }

    fn spawn(&self) -> Result<Child, String> {
        let mut command = Command::new(&self.core_exe);
        command
            .current_dir(&self.install_root)
            .env("DELEGATOR_RUNTIME_DIR", &self.runtime_dir)
            .env("DELEGATOR_RUNTIME_HOME", &self.runtime_home)
            .env("DELEGATOR_CORE_HOME", &self.core_home)
            .env("DELEGATOR_CORE_DELEGATE_CMD", &self.delegate_cmd)
            // Contract §7: under DELEGATOR_SUPERVISED=1 the core exits cleanly
            // on POST /api/restart and relies on this supervisor to respawn it.
            .env("DELEGATOR_SUPERVISED", "1")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        #[cfg(target_os = "windows")]
        command.creation_flags(CREATE_NO_WINDOW);
        command
            .spawn()
            .map_err(|e| format!("Failed to start Delegator Core: {e}"))
    }
}

enum SupervisorState {
    /// The core answered its health check (spawned by us, or adopted).
    Healthy,
    /// A child was spawned; waiting for it to become healthy.
    Starting { deadline: Instant },
    /// The core is down; waiting out the exponential backoff before respawn.
    BackingOff { until: Instant },
}

pub struct RuntimeService {
    child: Option<Child>,
    ctx: SpawnContext,
    state: SupervisorState,
    last_tick: Instant,
    probe_rx: Option<Receiver<bool>>,
    health_failures: u32,
    backoff_secs: u64,
}

impl RuntimeService {
    pub async fn start() -> Result<Self, String> {
        let ctx = SpawnContext::new()?;

        if let Some(health) = read_health().await {
            if health.ok
                && health.service == "delegator-core"
                && same_path(&health.delegate_cmd, &ctx.delegate_cmd)
            {
                return Ok(Self::with_child(ctx, None));
            }
            return Err(
                "Port 1380 is occupied by an older or foreign Delegator Core. Close it and restart Delegator."
                    .to_string(),
            );
        }

        if !ctx.core_exe.is_file() {
            return Err(format!(
                "Delegator Core executable was not found: {}",
                ctx.core_exe.display()
            ));
        }
        if !ctx.delegate_cmd.is_file() {
            return Err(format!(
                "Delegator runtime entry point was not found: {}",
                ctx.delegate_cmd.display()
            ));
        }

        let mut child = ctx.spawn()?;

        let deadline = Instant::now() + HEALTH_WAIT_BUDGET;
        while Instant::now() < deadline {
            tokio::time::sleep(HEALTH_POLL_INTERVAL).await;
            if let Some(health) = read_health().await {
                if health.ok && same_path(&health.delegate_cmd, &ctx.delegate_cmd) {
                    return Ok(Self::with_child(ctx, Some(child)));
                }
            }
            if let Ok(Some(code)) = child.try_wait() {
                return Err(format!("Delegator Core exited during startup: {code}"));
            }
        }

        kill_process_tree(&mut child);
        Err(format!(
            "Delegator Core did not become healthy within {} seconds",
            HEALTH_WAIT_BUDGET.as_secs()
        ))
    }

    fn with_child(ctx: SpawnContext, child: Option<Child>) -> Self {
        Self {
            child,
            ctx,
            state: SupervisorState::Healthy,
            last_tick: Instant::now(),
            probe_rx: None,
            health_failures: 0,
            backoff_secs: INITIAL_BACKOFF_SECS,
        }
    }

    /// Supervisor tick driven by the GUI update loop. Cheap: does real work at
    /// most once per SUPERVISOR_INTERVAL. Detects a dead or hung core, respawns
    /// it with exponential backoff (contract §7 — this is what makes
    /// POST /api/restart work under DELEGATOR_SUPERVISED=1), and returns a new
    /// status line whenever the visible core state changes.
    pub fn ensure_running(&mut self) -> Option<String> {
        if self.last_tick.elapsed() < SUPERVISOR_INTERVAL {
            return None;
        }
        self.last_tick = Instant::now();

        if let Some(exit) = self.child_exit_status() {
            eprintln!("Delegator Core process exited ({exit}); scheduling restart");
            self.child = None;
            self.probe_rx = None;
            self.health_failures = 0;
            return Some(self.schedule_respawn());
        }

        let probe = self.take_probe_result();

        match self.state {
            SupervisorState::BackingOff { until } => {
                if Instant::now() >= until {
                    return Some(self.respawn());
                }
                None
            }
            SupervisorState::Starting { deadline } => {
                if probe == Some(true) {
                    self.state = SupervisorState::Healthy;
                    self.health_failures = 0;
                    self.backoff_secs = INITIAL_BACKOFF_SECS;
                    return Some("Delegator Core is ready".to_string());
                }
                if Instant::now() >= deadline {
                    eprintln!("Delegator Core did not become healthy after respawn; backing off");
                    self.kill_child_tree();
                    return Some(self.schedule_respawn());
                }
                self.start_probe();
                None
            }
            SupervisorState::Healthy => {
                match probe {
                    Some(true) => {
                        self.health_failures = 0;
                        self.backoff_secs = INITIAL_BACKOFF_SECS;
                    }
                    Some(false) => {
                        self.health_failures += 1;
                        if self.health_failures >= MAX_CONSECUTIVE_HEALTH_FAILURES {
                            eprintln!(
                                "Delegator Core health checks keep failing; restarting the core"
                            );
                            self.kill_child_tree();
                            self.health_failures = 0;
                            return Some(self.schedule_respawn());
                        }
                    }
                    None => {}
                }
                self.start_probe();
                None
            }
        }
    }

    fn child_exit_status(&mut self) -> Option<std::process::ExitStatus> {
        match self.child.as_mut()?.try_wait() {
            Ok(Some(status)) => Some(status),
            _ => None,
        }
    }

    fn take_probe_result(&mut self) -> Option<bool> {
        let rx = self.probe_rx.as_ref()?;
        match rx.try_recv() {
            Ok(healthy) => {
                self.probe_rx = None;
                Some(healthy)
            }
            Err(TryRecvError::Empty) => None,
            Err(TryRecvError::Disconnected) => {
                self.probe_rx = None;
                Some(false)
            }
        }
    }

    fn start_probe(&mut self) {
        if self.probe_rx.is_some() {
            return;
        }
        let (tx, rx) = channel();
        let delegate_cmd = self.ctx.delegate_cmd.clone();
        tokio::spawn(async move {
            let healthy = matches!(
                read_health().await,
                Some(health) if health.ok && same_path(&health.delegate_cmd, &delegate_cmd)
            );
            let _ = tx.send(healthy);
        });
        self.probe_rx = Some(rx);
    }

    fn respawn(&mut self) -> String {
        self.probe_rx = None;
        self.health_failures = 0;
        match self.ctx.spawn() {
            Ok(child) => {
                self.child = Some(child);
                self.state = SupervisorState::Starting {
                    deadline: Instant::now() + HEALTH_WAIT_BUDGET,
                };
                eprintln!("Delegator Core respawned; waiting for health");
                "Delegator Core is restarting...".to_string()
            }
            Err(error) => {
                eprintln!("Failed to respawn Delegator Core: {error}");
                self.schedule_respawn();
                format!("Core error: {error}")
            }
        }
    }

    fn schedule_respawn(&mut self) -> String {
        let wait = self.backoff_secs;
        self.state = SupervisorState::BackingOff {
            until: Instant::now() + Duration::from_secs(wait),
        };
        self.backoff_secs = next_backoff(self.backoff_secs);
        format!("Core error: Delegator Core stopped, restarting in {wait}s")
    }

    fn kill_child_tree(&mut self) {
        if let Some(mut child) = self.child.take() {
            kill_process_tree(&mut child);
        }
        self.probe_rx = None;
    }
}

impl Drop for RuntimeService {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            kill_process_tree(&mut child);
        }
    }
}

/// Kills the whole process tree. `Child::kill` only terminates the PyInstaller
/// bootloader; the extracted python child (and any powershell grandchildren)
/// survive it, so use `taskkill /T /F` and fall back to kill() if that fails.
fn kill_process_tree(child: &mut Child) {
    let pid = child.id();
    let mut command = Command::new("taskkill");
    command
        .args(["/PID", &pid.to_string(), "/T", "/F"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    #[cfg(target_os = "windows")]
    command.creation_flags(CREATE_NO_WINDOW);
    match command.status() {
        Ok(status) if status.success() => {}
        Ok(status) => {
            eprintln!("taskkill for Delegator Core tree (pid {pid}) exited with {status}");
            let _ = child.kill();
        }
        Err(error) => {
            eprintln!("Failed to run taskkill for pid {pid}: {error}");
            let _ = child.kill();
        }
    }
    let _ = child.wait();
}

fn next_backoff(current_secs: u64) -> u64 {
    (current_secs * 2).min(MAX_BACKOFF_SECS)
}

async fn read_health() -> Option<HealthResponse> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_millis(500))
        .build()
        .ok()?;
    client.get(CORE_URL).send().await.ok()?.json().await.ok()
}

fn install_root() -> Result<PathBuf, String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    exe.parent()
        .map(Path::to_path_buf)
        .ok_or_else(|| "Delegator executable has no parent directory".to_string())
}

fn same_path(left: &str, right: &Path) -> bool {
    if left.trim().is_empty() {
        return false;
    }
    let left = PathBuf::from(left);
    let normalized_left = left
        .canonicalize()
        .unwrap_or(left)
        .to_string_lossy()
        .replace('/', "\\")
        .to_lowercase();
    let normalized_right = right
        .canonicalize()
        .unwrap_or_else(|_| right.to_path_buf())
        .to_string_lossy()
        .replace('/', "\\")
        .to_lowercase();
    normalized_left == normalized_right
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backoff_doubles_and_caps_at_30_seconds() {
        assert_eq!(next_backoff(INITIAL_BACKOFF_SECS), 2);
        assert_eq!(next_backoff(8), 16);
        assert_eq!(next_backoff(16), 30);
        assert_eq!(next_backoff(MAX_BACKOFF_SECS), MAX_BACKOFF_SECS);
    }
}
