//! Everything that must keep working while Delegator sits in the tray.
//!
//! Windows delivers no paint messages to an invisible window, so eframe never
//! calls `update()` while the main window is hidden. Measured on the installed
//! 0.5.0 build (2026-08-12): the GUI process spent **0.000 s of CPU in 10 s**, a
//! killed `delegator-core.exe` was still gone 45 s later, and that very core was
//! respawned 12 s after the window was made visible again. So "hidden window"
//! literally means "frozen app", and nothing that has to work in the tray may
//! be driven from the egui update loop.
//!
//! Three owners exist instead:
//!
//! * the core supervisor — its own OS thread (it blocks on process operations),
//! * the release check — a self-scheduling tokio task (pure async, no thread),
//! * the tray «Включить/Отключить» item — handled inline on the tray thread
//!   (see [`toggle_delegator_enabled`]), because that thread *is* running.
//!
//! Workers never touch GUI state: they send an [`AppMessage`] and request a
//! repaint, which the GUI consumes whenever it runs again.

use crate::config::AppConfig;
use crate::gui::app::AppMessage;
use crate::ide_detector::IdeDetector;
use crate::runtime_service::RuntimeService;
use crate::update_check;
use eframe::egui;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// How often the supervisor thread wakes up. The real work is throttled inside
/// `RuntimeService::ensure_running`; this interval only decides how fast the
/// thread notices a stop request.
const SUPERVISOR_TICK: Duration = Duration::from_millis(500);
/// How often the release check re-evaluates its own 8-hour throttle.
const UPDATE_POLL_INTERVAL: Duration = Duration::from_secs(60);

/// Set once the app is shutting down: no worker may spawn a core, write files
/// or send messages after this.
static STOP: AtomicBool = AtomicBool::new(false);
/// True while the supervisor thread still owns the core's child handle.
static SUPERVISOR_RUNNING: AtomicBool = AtomicBool::new(false);
/// Bumped whenever a worker changed config.json behind the GUI's back, so the
/// GUI can reload it instead of overwriting it with its stale in-memory copy.
static CONFIG_GENERATION: AtomicU64 = AtomicU64::new(0);

/// Shutting down — every worker stops at its next check.
pub fn request_stop() {
    STOP.store(true, Ordering::SeqCst);
}

pub fn stop_requested() -> bool {
    STOP.load(Ordering::SeqCst)
}

/// Counter the GUI compares against its own copy; a change means "config.json
/// was rewritten by a worker, reload before you save anything".
pub fn config_generation() -> u64 {
    CONFIG_GENERATION.load(Ordering::SeqCst)
}

/// Waits for the supervisor thread to drop `RuntimeService` (which kills the
/// core tree). Returns false on timeout. Called during shutdown so the final
/// `taskkill` cannot race a respawn that is already in flight.
pub fn wait_until_core_released(max: Duration) -> bool {
    let deadline = Instant::now() + max;
    while SUPERVISOR_RUNNING.load(Ordering::SeqCst) {
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    true
}

/// Supervises `delegator-core.exe` on a dedicated thread: respawn after a crash
/// or a `POST /api/restart` (contract §7), health checks, exponential backoff.
///
/// A thread rather than a tokio task because the tick blocks on process work
/// (`taskkill /T /F`, `Command::spawn`); the tokio handle is entered so the
/// health probes inside `ensure_running` can still be spawned as tasks.
pub fn spawn_core_supervisor(runtime: RuntimeService, tx: Sender<AppMessage>, ctx: egui::Context) {
    let handle = tokio::runtime::Handle::current();
    SUPERVISOR_RUNNING.store(true, Ordering::SeqCst);
    // The service travels in a slot instead of straight into the closure: a
    // failed `spawn` drops the closure on the spot, and `RuntimeService::drop`
    // kills the core tree — the app would silently execute the healthy core it
    // had just started, then never respawn it.
    let slot = Arc::new(Mutex::new(Some(runtime)));
    let thread_slot = Arc::clone(&slot);
    let status_tx = tx.clone();
    let spawned = std::thread::Builder::new()
        .name("delegator-core-supervisor".to_string())
        .spawn(move || {
            let _guard = handle.enter();
            let Some(mut runtime) = thread_slot.lock().ok().and_then(|mut slot| slot.take()) else {
                return;
            };
            while !stop_requested() {
                if let Some(status) = runtime.ensure_running() {
                    if tx.send(AppMessage::CoreStatus(status)).is_err() {
                        break;
                    }
                    ctx.request_repaint();
                }
                std::thread::sleep(SUPERVISOR_TICK);
            }
            // Dropping the service kills the core tree; do it before the flag
            // clears so `wait_until_core_released` really means "released".
            drop(runtime);
            SUPERVISOR_RUNNING.store(false, Ordering::SeqCst);
        });
    if spawned.is_err() {
        SUPERVISOR_RUNNING.store(false, Ordering::SeqCst);
        // Leak the handle deliberately: an unsupervised core still serves every
        // delegation, a killed one serves none.
        if let Ok(mut guard) = slot.lock() {
            std::mem::forget(guard.take());
        }
        eprintln!("Failed to start the core supervisor thread; the core is unsupervised");
        let _ = status_tx.send(AppMessage::CoreStatus(
            "Core error: не удалось запустить надзор за ядром (ядро работает без присмотра)"
                .to_string(),
        ));
    }
}

/// Asks GitHub for the latest release, at most once every 8 hours (the throttle
/// lives in `update_check`, backed by a state file, so it also survives
/// restarts). A self-scheduling tokio task: the runtime keeps driving it no
/// matter what the window does.
pub fn spawn_update_poller(tx: Sender<AppMessage>, ctx: egui::Context) {
    tokio::spawn(async move {
        loop {
            if stop_requested() {
                return;
            }
            if update_check::is_check_due() {
                let status = update_check::fetch_latest_release().await;
                if stop_requested() || tx.send(AppMessage::UpdateChecked(status)).is_err() {
                    return;
                }
                ctx.request_repaint();
            }
            tokio::time::sleep(UPDATE_POLL_INTERVAL).await;
        }
    });
}

/// Writes (or strips) the `DELEGATOR_HOOK_START/END` block of every configured
/// IDE. Shared by the GUI and the tray so both produce the same result.
pub fn apply_ide_hooks(config: &AppConfig) {
    for (name, enabled) in &config.ide_states {
        let _ = IdeDetector::apply_hook(name, *enabled && config.delegator_enabled);
    }
    IdeDetector::migrate_legacy_installation(config.delegator_enabled);
}

/// The tray «Включить/Отключить» item, executed where it is clicked.
///
/// The menu callback runs on the thread that owns the tray icon — the same
/// thread as the egui loop, which is asleep while the window is hidden. Pushing
/// the action into the UI channel therefore did nothing until the user opened
/// the window. Config is re-read from disk (never taken from the GUI's copy,
/// which this thread cannot see), flipped, saved, and the generation counter
/// tells the GUI to reload. Returns the new state for the menu label.
pub fn toggle_delegator_enabled() -> bool {
    let mut config = AppConfig::load();
    config.delegator_enabled = !config.delegator_enabled;
    config.save();
    apply_ide_hooks(&config);
    CONFIG_GENERATION.fetch_add(1, Ordering::SeqCst);
    config.delegator_enabled
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stop_request_is_visible_to_every_worker() {
        // The flag is process-global (one app instance), so restore it.
        let was_stopped = stop_requested();
        request_stop();
        assert!(stop_requested());
        if !was_stopped {
            STOP.store(false, Ordering::SeqCst);
        }
    }

    #[test]
    fn config_generation_only_moves_forward() {
        let before = config_generation();
        CONFIG_GENERATION.fetch_add(1, Ordering::SeqCst);
        assert_eq!(config_generation(), before + 1);
    }

    #[test]
    fn waiting_for_a_released_core_times_out_instead_of_hanging() {
        SUPERVISOR_RUNNING.store(true, Ordering::SeqCst);
        let started = Instant::now();
        assert!(!wait_until_core_released(Duration::from_millis(100)));
        assert!(started.elapsed() >= Duration::from_millis(100));
        SUPERVISOR_RUNNING.store(false, Ordering::SeqCst);
        assert!(wait_until_core_released(Duration::from_millis(10)));
    }
}
