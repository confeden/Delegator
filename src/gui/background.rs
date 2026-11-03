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
use crate::gui::app::{AppMessage, ProviderRefreshOutcome};
use crate::ide_detector::IdeDetector;
use crate::models_service::{fetch_provider_models, probe_provider_model};
use crate::provider_verdicts::{classify_probe, VerdictStore};
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

/// How often the provider round checks whether it is due. The round itself is
/// daily (`PROVIDER_CATALOG_INTERVAL_SECS`); this is only the granularity at
/// which a due one is noticed, which also decides how fast «Проверить модели»
/// would fire if it ever fell back to the poller.
const PROVIDER_POLL_INTERVAL: Duration = Duration::from_secs(120);

/// True while a provider round is in flight. Process-global rather than GUI
/// state because two owners can start one — the poller and the button — and a
/// probe spends the provider's quota, so a race would spend it twice.
static PROVIDER_ROUND_RUNNING: AtomicBool = AtomicBool::new(false);

/// Asks every configured provider what it serves, at most once a day
/// (DEV_CONTRACTS §12a).
///
/// A self-scheduling tokio task, and that is the whole point of this rewrite:
/// the first version was called once from `DelegatorApp::new`, which for a tray
/// app means "on restart", not "daily". This module's opening paragraph says it
/// outright — a hidden window is a frozen app — and the round walked straight
/// into it. The release check next door is the shape that works.
pub fn spawn_provider_catalog_poller(tx: Sender<AppMessage>, ctx: egui::Context) {
    tokio::spawn(async move {
        loop {
            if stop_requested() {
                return;
            }
            // Config is re-read from disk every tick, never cached: the user can
            // add a provider or paste a key at any moment, and this task cannot
            // see the GUI's copy.
            // `load_readonly`, not `load`: the latter migrates and SAVES, and a
            // timer that rewrites config.json every two minutes would race the
            // GUI's own saves for nothing.
            if AppConfig::load_readonly().provider_catalog_refresh_due(crate::config::unix_now()) {
                run_provider_catalog_round(&tx, &ctx).await;
            }
            tokio::time::sleep(PROVIDER_POLL_INTERVAL).await;
        }
    });
}

/// One round: list what each provider offers, probe what has no live verdict,
/// write both back. Shared by the daily poller and the «Проверить модели»
/// button so there is exactly one implementation of what a round IS.
///
/// Writes config itself and bumps the generation counter, the same contract
/// `toggle_delegator_enabled` uses: a worker that mutated config.json behind
/// the GUI's back must say so, or the next checkbox click saves a stale copy
/// over it.
pub async fn run_provider_catalog_round(tx: &Sender<AppMessage>, ctx: &egui::Context) {
    if PROVIDER_ROUND_RUNNING.swap(true, Ordering::SeqCst) {
        return;
    }
    let outcomes = provider_catalog_round().await;
    PROVIDER_ROUND_RUNNING.store(false, Ordering::SeqCst);
    if stop_requested() {
        return;
    }
    if tx
        .send(AppMessage::ProviderCatalogRefreshed(outcomes))
        .is_ok()
    {
        ctx.request_repaint();
    }
}

/// True while a round is in flight, for the spinner and the disabled button.
pub fn provider_round_running() -> bool {
    PROVIDER_ROUND_RUNNING.load(Ordering::SeqCst)
}

async fn provider_catalog_round() -> Vec<ProviderRefreshOutcome> {
    let mut config = AppConfig::load();
    let jobs: Vec<(String, String, String)> = config
        .custom_providers
        .iter()
        .filter(|provider| provider.enabled)
        .map(|provider| {
            (
                provider.id.clone(),
                provider.base_url.clone(),
                config.first_enabled_provider_api_key(&provider.id),
            )
        })
        .filter(|(_, base_url, key)| !base_url.is_empty() && !key.is_empty())
        .collect();
    if jobs.is_empty() {
        return Vec::new();
    }

    // Stamp the ATTEMPT before any request, exactly as the `opencode upgrade`
    // round does: a provider that is permanently unreachable must not make
    // every tick fire another probe round.
    config.mark_provider_catalog_refresh(crate::config::unix_now());
    // Say so at once, not at the end: the round takes seconds, and a checkbox
    // saved meanwhile from the GUI's older copy would put the old stamp back —
    // and the next tick would run the whole round again.
    CONFIG_GENERATION.fetch_add(1, Ordering::SeqCst);

    // Custom providers go DIRECT, the same egress as `Invoke-CustomProviderModel`
    // in the runtime. They used to ride the `opencode` proxy row (Opera, 127.0.0.1:1371),
    // which is down whenever Opera is closed: that is the «error sending request»
    // on api.b.ai/v1/models. A catalog must be probed from the egress delegation uses.
    let proxy: Option<String> = None;
    let runtime_home = crate::config::runtime_home_dir();
    let live_ids: Vec<String> = config
        .custom_providers
        .iter()
        .map(|provider| provider.id.clone())
        .collect();

    let mut store = VerdictStore::load(&runtime_home);
    store.retain_providers(&live_ids);
    let mut outcomes = Vec::new();
    for (id, base_url, api_key) in jobs {
        if stop_requested() {
            break;
        }
        let (discovered, error) =
            match fetch_provider_models(&base_url, &api_key, proxy.as_deref()).await {
                Ok(ids) => (ids, None),
                // A listing that failed to load changes nothing: the configured
                // models stay authoritative. An outage must not empty a provider.
                Err(error) => (Vec::new(), Some(error)),
            };
        let now = crate::config::unix_now();
        // ENABLED models first, and that ordering is the whole value of the
        // probe: an enabled model with no verdict is the one that costs a real
        // rung of a delegation ladder to discover. The listing's own order put
        // unknown premium models first and the per-round cap ate all eight of
        // them, leaving the four the user actually ticked unasked — measured on
        // the first live round. A model that is enabled but ABSENT from the
        // listing is still asked: "withdrawn" is a verdict worth having.
        let enabled: Vec<String> = config
            .custom_provider(&id)
            .map(|provider| provider.enabled_models.clone())
            .unwrap_or_default();
        let mut candidates: Vec<String> = enabled.clone();
        candidates.extend(
            discovered
                .iter()
                .filter(|model| !enabled.iter().any(|id| &id == model))
                .cloned(),
        );
        let candidates = store.models_needing_probe(&id, &candidates, now);
        let mut probed = 0usize;
        let mut verdicts = 0usize;
        for model in candidates {
            if stop_requested() {
                break;
            }
            let (status, body) =
                probe_provider_model(&base_url, &api_key, &model, proxy.as_deref()).await;
            probed += 1;
            if let Some((verdict, reason)) = classify_probe(status, &body) {
                store.record(
                    &id,
                    &model,
                    verdict,
                    status,
                    reason,
                    crate::config::unix_now(),
                );
                verdicts += 1;
            }
        }
        outcomes.push(ProviderRefreshOutcome {
            id,
            discovered,
            error,
            probed,
            verdicts,
        });
    }
    store.save(&runtime_home);
    // Discovery may only WIDEN the list the user chooses from (I8). It is
    // written into config as it is NOW, never into `config` above: that copy
    // was read before the network round, and saving it would undo whatever the
    // user saved meanwhile — and the first round after a key is added runs
    // exactly while they are ticking that provider's models.
    let mut config = AppConfig::load();
    for outcome in &outcomes {
        config.add_known_provider_models(&outcome.id, &outcome.discovered);
    }
    CONFIG_GENERATION.fetch_add(1, Ordering::SeqCst);
    outcomes
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
    fn only_one_provider_round_runs_at_a_time() {
        // Two owners can start a round — the daily poller and «Проверить
        // модели» — and a probe spends the provider's quota, so a race would
        // spend it twice. The guard is process-global for exactly that reason.
        assert!(!provider_round_running());
        assert!(!PROVIDER_ROUND_RUNNING.swap(true, Ordering::SeqCst));
        assert!(provider_round_running());
        // A second starter sees the flag already set and gives up.
        assert!(PROVIDER_ROUND_RUNNING.swap(true, Ordering::SeqCst));
        PROVIDER_ROUND_RUNNING.store(false, Ordering::SeqCst);
        assert!(!provider_round_running());
    }

    #[test]
    fn the_poller_reads_config_without_writing_it() {
        // `load` migrates and SAVES; a two-minute timer doing that would
        // rewrite config.json all day and race the GUI's saves. This asserts
        // the read-only path exists and answers the question a poller asks.
        let config = AppConfig::load_readonly();
        // No providers on a default/empty config means nothing is ever due, so
        // a user who never added one pays nothing for this task existing.
        if config.custom_providers.is_empty() {
            assert!(!config.provider_catalog_refresh_due(crate::config::unix_now()));
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
