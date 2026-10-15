use crate::config::{self, is_supported_proxy_url, unix_now, AppConfig};
use crate::dependency_service::DependencyStatus;
use crate::gui::background;
use crate::gui::benchmark::{
    cancel_run, export_last, fetch_last, fetch_status, format_points, level_label, pulse_alpha,
    BenchmarkReport, RunStatus, PULSE_PERIOD_SEC,
};
use crate::gui::opencode_setup::{
    install_dependencies, install_plan, load_zen_strengths, open_url, order_opencode_models,
    upgrade_opencode_cli, CliJob, CliJobResult, InstallStep, NODEJS_DOWNLOAD_URL,
    NO_INSTALLER_FOUND, OPENCODE_SITE_URL,
};
use crate::gui::proxy::{run_proxy_test, GoogleProbe, ProxyTestResult};
use crate::gui::quota::{limit_line, read_limits, ProviderLimit};
use crate::gui::updater::{progress_label, run_update, update_button_label};
use crate::gui::usage::{fetch_usage, format_count, UsageReport};
use crate::ide_detector::IdeDetector;
use crate::models_service::{
    fetch_gemini_models, fetch_opencode_models, ModelInfo, OpenCodeCatalog,
};
use crate::provider_verdicts::VerdictStore;
use crate::runtime_service::RuntimeService;
use crate::update_check::{self, UpdateStatus};
use eframe::egui;
use std::collections::HashMap;
use std::sync::mpsc::{channel, Receiver, Sender};
use std::time::{Duration, Instant};

use crate::theme::ThemeConfig;
use crate::tray_service::{
    attach_ui_context, attach_window_handle, mark_quit_handled, set_toggle_label, TrayAction,
};

/// Header title, derived from the crate version at compile time. It must be
/// the FULL version: the window title and the tray tooltip use the same
/// `CARGO_PKG_VERSION`, and a shortened header read as a second, older version.
const APP_TITLE: &str = concat!("Delegator v", env!("CARGO_PKG_VERSION"));

/// Test hook: with `DELEGATOR_SELFTEST_UPDATE=1` the app presses its own
/// «Обновить до …» button as soon as a newer release is known, so the whole
/// download → install → restart chain can be exercised end to end (usually
/// together with `DELEGATOR_UPDATE_API_URL`, see `crate::update_check`).
const SELFTEST_UPDATE_ENV: &str = "DELEGATOR_SELFTEST_UPDATE";

/// What one provider's refresh found. `discovered` is empty when the listing
/// itself failed — which changes nothing on purpose: the configured models stay
/// authoritative, so an outage cannot empty a provider.
pub struct ProviderRefreshOutcome {
    pub id: String,
    pub discovered: Vec<String>,
    pub error: Option<String>,
    pub probed: usize,
    pub verdicts: usize,
}

pub enum AppMessage {
    /// New status line from the core supervisor thread.
    CoreStatus(String),
    GeminiModelsFetched(Result<Vec<ModelInfo>, String>),
    OpenCodeModelsFetched(Result<OpenCodeCatalog, String>),
    UsageFetched(Result<UsageReport, String>),
    ProxyTested(ProxyTestResult),
    /// A background dependency install / `opencode upgrade` finished.
    OpenCodeCliJob(CliJob, CliJobResult),
    /// The install chain moved on to the next command (one status line).
    OpenCodeInstallStep(InstallStep),
    /// The 8-hourly GitHub release check finished.
    UpdateChecked(UpdateStatus),
    /// One daily provider catalog + probe round finished (§12a).
    ProviderCatalogRefreshed(Vec<ProviderRefreshOutcome>),
    /// Last stored benchmark report (or the reason it could not be read).
    BenchmarkFetched(Result<Option<BenchmarkReport>, String>),
    /// Report written to the Desktop: the paths, or why it failed.
    BenchmarkExported(Result<Vec<String>, String>),
    /// Live state of a run in flight (None = nothing is running).
    BenchmarkStatus(Option<RunStatus>),
    /// A stalled run was dropped by the core (or the drop failed).
    BenchmarkCancelled(Result<(), String>),
    /// Whole percent of the installer download.
    UpdateProgress(u8),
    /// The updater script is running (Ok) or nothing was started (Err).
    UpdateFinished(Result<(), String>),
}

/// State of the «Обновить до …» button in the header.
enum UpdateJobState {
    Downloading(u8),
    /// The detached updater is armed; the app quits on the next frames.
    Handoff,
    /// Short Russian label plus the full reason for the tooltip.
    Failed(String),
}

#[derive(Clone, Copy, PartialEq)]
enum SelectedTab {
    Ides,
    Api,
    Stats,
    Thinking,
    Benchmark,
    Proxies,
}

/// Which provider's panel the «API» tab is showing. A `String` for the
/// user-added ones because they have no compile-time identity; the two built-ins
/// get variants of their own because they have storage of their own and cannot
/// be removed.
#[derive(Clone, Debug, PartialEq, Eq)]
enum ApiProvider {
    Google,
    OpenCode,
    Custom(String),
    Add,
}

/// Keys or models. Every provider has both, so the switch is shared rather than
/// repeated per panel.
#[derive(Clone, Copy, PartialEq, Eq)]
enum ApiSection {
    Keys,
    Models,
}

#[derive(Clone)]
struct ApiAccountDraft {
    id: String,
    label: String,
    new_key: String,
    enabled: bool,
}

/// State of the «Проверить» button for one proxy entry.
enum ProxyTestState {
    Running,
    Done(ProxyTestResult),
}

/// State of the background `opencode upgrade` job.
enum CliJobState {
    Running,
    Done(CliJobResult),
}

/// State of the «Установить» chain: which command runs right now, or how it
/// ended. Exactly one short Russian line is derived from this.
enum InstallState {
    Running(InstallStep),
    Done(CliJobResult),
}

pub struct DelegatorApp {
    config: AppConfig,
    active_tab: SelectedTab,
    // One-shot startup fit of the window width to the tab row (see update()).
    window_width_fitted: bool,

    // Temp UI Inputs
    google_account_drafts: Vec<ApiAccountDraft>,
    new_google_label: String,
    new_google_key: String,
    opencode_account_drafts: Vec<ApiAccountDraft>,
    new_opencode_label: String,
    new_opencode_key: String,
    api_provider: ApiProvider,
    api_section: ApiSection,
    /// Edit drafts per user-added provider, keyed by provider id. Rebuilt by
    /// `sync_provider_drafts` whenever they stop matching the stored accounts.
    provider_account_drafts: HashMap<String, Vec<ApiAccountDraft>>,
    new_provider_account_label: String,
    new_provider_account_key: String,
    new_provider_id: String,
    new_provider_label: String,
    new_provider_base_url: String,
    new_provider_model: String,
    status_message: String,

    // Models Lists
    gemini_models: Vec<ModelInfo>,
    opencode_models: Vec<ModelInfo>,
    /// The last listing came from the built-in catalog, not from the CLI. The
    /// tab has to SAY so: seven rows where the user enabled twenty-four reads
    /// as "this is all there is" and there is nothing else to tell them apart.
    opencode_catalog_is_fallback: bool,
    gemini_search: String,
    opencode_search: String,
    /// Zen strength scores from `<RT>\opencode-zen-catalog.json`; drives the
    /// "strongest first" order of the `opencode/*` block in the tab.
    zen_strengths: HashMap<String, i32>,

    /// «Мышление»: reads the runtime's own event logs and animates the
    /// pipeline. Holds no state of its own beyond how far it has read.
    thinking: crate::gui::thinking::ThinkingView,

    // Background OpenCode CLI jobs («Установить» / «Обновить CLI»).
    opencode_install: Option<InstallState>,
    opencode_upgrade: Option<CliJobState>,

    // Usage statistics («Статистика» tab)
    usage_report: Option<UsageReport>,
    usage_error: Option<String>,
    is_loading_usage: bool,
    stats_tab_was_active: bool,

    // «Прокси» tab: per-proxy connectivity test state, keyed by proxy id.
    proxy_tests: HashMap<String, ProxyTestState>,

    // «Бенчмарк» tab: the last stored report plus the export status line.
    benchmark_report: Option<BenchmarkReport>,
    benchmark_error: Option<String>,
    benchmark_loading: bool,
    benchmark_tab_was_active: bool,
    benchmark_export: Option<Result<Vec<String>, String>>,
    benchmark_exporting: bool,
    /// Progress of a run in flight, polled while the tab is open.
    benchmark_status: Option<RunStatus>,
    benchmark_status_polled_at: Option<Instant>,
    /// True while the previous poll saw a run, so its end can trigger a reload.
    benchmark_was_running: bool,

    // Provider limits, read from <RT>\cooldowns.json. A free tier running out
    // used to be invisible here — the owner found out because a benchmark run
    // started answering badly.
    gemini_limit: Option<ProviderLimit>,
    opencode_limit: Option<ProviderLimit>,
    limits_read_at: Option<Instant>,

    /// Deadline for dropping the temporary always-on-top state used to
    /// raise the window from the tray.
    unpin_window_at: Option<Instant>,

    /// Frames left to re-hide the window after an autostart. eframe forces
    /// `set_visible(true)` once the first frame is painted (epi_integration
    /// `post_rendering`), so `with_visible(false)` alone cannot keep a
    /// `--background` launch in the tray.
    hide_frames_left: u8,

    /// Newest GitHub release seen by the 8-hourly check (button source).
    update_status: Option<UpdateStatus>,
    /// Progress / outcome of the one-click update, `None` before the first click.
    update_job: Option<UpdateJobState>,
    /// `DELEGATOR_SELFTEST_UPDATE=1`, read once at startup.
    selftest_update: bool,

    // Async Channel
    tx: Sender<AppMessage>,
    rx: Receiver<AppMessage>,
    /// Clone of the egui context so background jobs can wake the UI as soon
    /// as they finish instead of waiting for the next timed repaint.
    egui_ctx: egui::Context,
    is_loading_gemini: bool,
    is_loading_opencode: bool,
    /// Verdicts as of the last read; re-read after every round so the models
    /// list shows what the provider actually said.
    provider_verdicts: VerdictStore,
    tray_rx: Receiver<TrayAction>,
    quitting: bool,
    /// «Выйти» was accepted: paint the farewell screen instead of the tabs.
    shutting_down: bool,
    /// The farewell screen reached the screen at least once, so the close
    /// command may go out now (see the shutdown block in `update`).
    shutdown_frame_painted: bool,
    window_theme_applied: bool,
    dependencies: DependencyStatus,
    theme: ThemeConfig,
    /// Last `background::config_generation()` this app state was built from.
    /// A change means the tray rewrote config.json while the window was hidden.
    config_generation: u64,
}

impl DelegatorApp {
    pub fn new(
        cc: &eframe::CreationContext<'_>,
        tray_rx: Receiver<TrayAction>,
        runtime: Option<RuntimeService>,
        runtime_status: String,
        theme: ThemeConfig,
        start_in_background: bool,
    ) -> Self {
        let config = AppConfig::load();
        let google_account_drafts = config
            .google_accounts
            .iter()
            .map(|account| ApiAccountDraft {
                id: account.id.clone(),
                label: account.label.clone(),
                new_key: String::new(),
                enabled: account.enabled,
            })
            .collect();
        let opencode_account_drafts = config
            .opencode_accounts
            .iter()
            .map(|account| ApiAccountDraft {
                id: account.id.clone(),
                label: account.label.clone(),
                new_key: String::new(),
                enabled: account.enabled,
            })
            .collect();

        let (tx, rx) = channel();

        let mut app = Self {
            config,
            active_tab: SelectedTab::Ides,
            google_account_drafts,
            new_google_label: String::new(),
            new_google_key: String::new(),
            opencode_account_drafts,
            new_opencode_label: String::new(),
            new_opencode_key: String::new(),
            provider_verdicts: VerdictStore::load(&crate::config::runtime_home_dir()),
            api_provider: ApiProvider::Google,
            api_section: ApiSection::Keys,
            provider_account_drafts: HashMap::new(),
            new_provider_account_label: String::new(),
            new_provider_account_key: String::new(),
            new_provider_id: String::new(),
            new_provider_label: String::new(),
            new_provider_base_url: String::new(),
            new_provider_model: String::new(),
            status_message: runtime_status,
            gemini_models: Vec::new(),
            opencode_models: Vec::new(),
            opencode_catalog_is_fallback: false,
            gemini_search: String::new(),
            opencode_search: String::new(),
            zen_strengths: load_zen_strengths(),
            thinking: crate::gui::thinking::ThinkingView::default(),
            opencode_install: None,
            opencode_upgrade: None,
            usage_report: None,
            usage_error: None,
            is_loading_usage: false,
            stats_tab_was_active: false,
            window_width_fitted: false,
            proxy_tests: HashMap::new(),
            benchmark_report: None,
            benchmark_error: None,
            benchmark_loading: false,
            benchmark_tab_was_active: false,
            benchmark_export: None,
            benchmark_exporting: false,
            benchmark_status: None,
            benchmark_status_polled_at: None,
            benchmark_was_running: false,
            gemini_limit: None,
            opencode_limit: None,
            limits_read_at: None,
            unpin_window_at: None,
            hide_frames_left: if start_in_background { 3 } else { 0 },
            update_status: update_check::cached_status(),
            update_job: None,
            selftest_update: std::env::var(SELFTEST_UPDATE_ENV)
                .map(|value| value.trim() == "1")
                .unwrap_or(false),
            tx,
            rx,
            egui_ctx: cc.egui_ctx.clone(),
            is_loading_gemini: false,
            is_loading_opencode: false,
            tray_rx,
            quitting: false,
            shutting_down: false,
            shutdown_frame_painted: false,
            window_theme_applied: false,
            dependencies: DependencyStatus::detect(),
            theme,
            config_generation: background::config_generation(),
        };

        set_toggle_label(app.config.delegator_enabled);

        // Hand the raw window handle to the tray: while the window is hidden the
        // egui loop is not running, so «Открыть» has to show it via Win32.
        #[cfg(target_os = "windows")]
        {
            use raw_window_handle::{HasWindowHandle, RawWindowHandle};
            if let Ok(handle) = cc.window_handle() {
                if let RawWindowHandle::Win32(win32) = handle.as_raw() {
                    attach_window_handle(isize::from(win32.hwnd));
                }
            }
        }

        // Let tray callbacks wake this context; otherwise their messages sit
        // unread while the window is hidden in the tray.
        attach_ui_context(cc.egui_ctx.clone());

        // Sync initial IDE hooks on startup
        app.sync_all_ide_hooks();
        // Trigger initial background model fetch
        app.refresh_models();
        // Keep the CLI (and therefore the free-model lineup) current.
        app.maybe_start_background_upgrade();

        // Both of these used to be driven from `update()` and were therefore
        // dead while the window sat in the tray (see gui::background): a
        // crashed core stayed down and the release check never fired.
        if let Some(runtime) = runtime {
            background::spawn_core_supervisor(runtime, app.tx.clone(), cc.egui_ctx.clone());
        }
        background::spawn_update_poller(app.tx.clone(), cc.egui_ctx.clone());
        background::spawn_provider_catalog_poller(app.tx.clone(), cc.egui_ctx.clone());

        app
    }

    fn sync_all_ide_hooks(&mut self) {
        background::apply_ide_hooks(&self.config);
    }

    fn refresh_models(&mut self) {
        self.is_loading_gemini = true;
        self.is_loading_opencode = true;

        let google_key = self.config.first_enabled_google_api_key();
        let opencode_key = self.config.first_enabled_opencode_api_key();

        let tx1 = self.tx.clone();
        tokio::spawn(async move {
            let res = fetch_gemini_models(&google_key).await;
            let _ = tx1.send(AppMessage::GeminiModelsFetched(res));
        });

        let tx2 = self.tx.clone();
        tokio::spawn(async move {
            let res = fetch_opencode_models(&opencode_key).await;
            let _ = tx2.send(AppMessage::OpenCodeModelsFetched(res));
        });
    }

    /// «Обновить до vX.Y»: download the release installer, arm the detached
    /// updater script, then quit exactly like «Выйти» does so the script finds
    /// the process gone. Everything runs in the background; a failure only
    /// changes the button text.
    fn start_update(&mut self) {
        if matches!(
            self.update_job,
            Some(UpdateJobState::Downloading(_)) | Some(UpdateJobState::Handoff)
        ) {
            return;
        }
        let Some(UpdateStatus::Available { tag, url, asset }) = self.update_status.clone() else {
            return;
        };
        println!("Update requested: {tag} ({url})");
        self.update_job = Some(UpdateJobState::Downloading(0));
        let tx = self.tx.clone();
        let ctx = self.egui_ctx.clone();
        let progress_tx = tx.clone();
        let progress_ctx = ctx.clone();
        tokio::spawn(async move {
            let result = run_update(tag, asset, move |percent| {
                let _ = progress_tx.send(AppMessage::UpdateProgress(percent));
                progress_ctx.request_repaint();
            })
            .await;
            let _ = tx.send(AppMessage::UpdateFinished(result));
            ctx.request_repaint();
        });
    }

    /// The update control in the header, drawn immediately to the left of the
    /// «АКТИВЕН/ПАУЗА» toggle. One widget, four states, one short line each.
    /// Returns true when the user asked to update (or to retry).
    fn update_button(&self, ui: &mut egui::Ui, tag: &str) -> bool {
        match &self.update_job {
            None => ui
                .add(egui::Button::new(
                    egui::RichText::new(update_button_label(tag)).color(self.theme.accent_color()),
                ))
                .on_hover_text("Скачает установщик, обновит и запустит Delegator заново")
                .clicked(),
            Some(UpdateJobState::Downloading(percent)) => {
                ui.add_enabled(false, egui::Button::new(progress_label(*percent)));
                false
            }
            Some(UpdateJobState::Handoff) => {
                ui.add_enabled(false, egui::Button::new("Установка…"));
                false
            }
            Some(UpdateJobState::Failed(reason)) => ui
                .add(egui::Button::new(
                    egui::RichText::new("Не удалось обновить").color(self.theme.warning_color()),
                ))
                .on_hover_text(format!("{reason}\nНажмите, чтобы повторить"))
                .clicked(),
        }
    }

    /// The one shutdown path: the tray «Выйти» item and the updater handoff
    /// both go through here, so the core is killed and the tray icon removed
    /// in the same orderly way (see the 0.4.1 notes).
    fn begin_shutdown(&mut self) {
        // The watchdog in tray_service must be disarmed at once; the actual
        // close happens one frame later (see the shutdown block in `update`).
        mark_quit_handled();
        // Stop the supervisor before anything else, or it happily respawns the
        // core we are about to kill.
        background::request_stop();
        self.quitting = true;
        self.shutting_down = true;
    }

    /// «Установить»: the whole dependency chain (winget → npm, with a Node.js
    /// install in between when npm is missing) in the background. The plan is
    /// built here so the first status line is correct from the very first
    /// frame; every command is then re-resolved inside the job.
    fn start_opencode_install(&mut self) {
        if matches!(self.opencode_install, Some(InstallState::Running(_))) {
            return;
        }
        let plan = install_plan(
            self.dependencies.winget_available(),
            self.dependencies.npm_available(),
        );
        let Some(first) = plan.first().copied() else {
            self.opencode_install = Some(InstallState::Done(Err(NO_INSTALLER_FOUND.to_string())));
            return;
        };
        self.opencode_install = Some(InstallState::Running(first));
        let tx = self.tx.clone();
        let ctx = self.egui_ctx.clone();
        let step_tx = tx.clone();
        let step_ctx = ctx.clone();
        tokio::spawn(async move {
            let result = install_dependencies(plan, move |step| {
                let _ = step_tx.send(AppMessage::OpenCodeInstallStep(step));
                step_ctx.request_repaint();
            })
            .await;
            let _ = tx.send(AppMessage::OpenCodeCliJob(CliJob::Install, result));
            ctx.request_repaint();
        });
    }

    /// «Обновить CLI» and the once-a-day startup update: `opencode upgrade`
    /// in the background. The attempt is stamped before the job starts, so a
    /// CLI that always fails cannot re-spawn a 10-minute job on every start.
    fn start_opencode_upgrade(&mut self) {
        let Some(cli) = self.dependencies.opencode_cli_path.clone() else {
            return;
        };
        if matches!(self.opencode_upgrade, Some(CliJobState::Running)) {
            return;
        }
        self.opencode_upgrade = Some(CliJobState::Running);
        self.config.mark_opencode_upgrade_attempt(unix_now());
        let tx = self.tx.clone();
        let ctx = self.egui_ctx.clone();
        tokio::spawn(async move {
            let result = upgrade_opencode_cli(cli).await;
            let _ = tx.send(AppMessage::OpenCodeCliJob(CliJob::Upgrade, result));
            ctx.request_repaint();
        });
    }

    /// «Проверить модели». The round itself lives in `gui::background`,
    /// alongside the daily poller that also starts it — a hidden window is a
    /// frozen app, so nothing that has to happen on a schedule may live here.
    fn start_provider_catalog_refresh(&mut self) {
        if background::provider_round_running() {
            return;
        }
        let tx = self.tx.clone();
        let ctx = self.egui_ctx.clone();
        tokio::spawn(async move {
            background::run_provider_catalog_round(&tx, &ctx).await;
        });
    }

    /// Startup auto-update: only when the CLI is installed and the last
    /// attempt is at least 24 h old. Silent by design — the tab shows a small
    /// status line, everything else goes to the log.
    fn maybe_start_background_upgrade(&mut self) {
        if !self.dependencies.opencode_cli_available() {
            return;
        }
        if !self.config.opencode_upgrade_due(unix_now()) {
            return;
        }
        self.start_opencode_upgrade();
    }

    /// Reads the last benchmark result from the core. The benchmark itself is
    /// run from the IDE chat («-benchmark»), because only the IDE can make the
    /// user's own model answer the tasks.
    fn refresh_benchmark(&mut self) {
        if self.benchmark_loading {
            return;
        }
        self.benchmark_loading = true;
        self.benchmark_error = None;
        let tx = self.tx.clone();
        let ctx = self.egui_ctx.clone();
        tokio::spawn(async move {
            let result = fetch_last().await.map(|envelope| envelope.report);
            let _ = tx.send(AppMessage::BenchmarkFetched(result));
            ctx.request_repaint();
        });
    }

    /// Polls the live state of a run. One local GET; fast while the «Бенчмарк»
    /// tab is open (a frozen screen looks like a hang), slow from any other tab
    /// — enough to keep the tab pulsing without turning idle into work.
    ///
    /// It is NOT gated on the tab being open any more: the run is driven from
    /// the IDE chat, so the user is normally looking at something else, and a
    /// highlight nobody polls for can never appear. The tray stays at 0 % CPU
    /// regardless, because a hidden window never runs `update()` at all.
    fn poll_benchmark_status(&mut self, foreground: bool) {
        const POLL_ACTIVE: Duration = Duration::from_millis(1500);
        const POLL_BACKGROUND: Duration = Duration::from_millis(4000);
        let interval = if foreground {
            POLL_ACTIVE
        } else {
            POLL_BACKGROUND
        };
        if self
            .benchmark_status_polled_at
            .is_some_and(|at| at.elapsed() < interval)
        {
            return;
        }
        self.benchmark_status_polled_at = Some(Instant::now());
        let tx = self.tx.clone();
        let ctx = self.egui_ctx.clone();
        tokio::spawn(async move {
            if let Ok(status) = fetch_status().await {
                let _ = tx.send(AppMessage::BenchmarkStatus(status));
                ctx.request_repaint();
            }
        });
    }

    fn start_benchmark_export(&mut self, formats: Vec<&'static str>) {
        if self.benchmark_exporting {
            return;
        }
        self.benchmark_exporting = true;
        self.benchmark_export = None;
        let tx = self.tx.clone();
        let ctx = self.egui_ctx.clone();
        tokio::spawn(async move {
            let result = export_last(formats).await;
            let _ = tx.send(AppMessage::BenchmarkExported(result));
            ctx.request_repaint();
        });
    }

    fn refresh_usage(&mut self) {
        if self.is_loading_usage {
            return;
        }
        self.is_loading_usage = true;
        self.usage_error = None;

        let tx = self.tx.clone();
        tokio::spawn(async move {
            let res = fetch_usage(7).await;
            let _ = tx.send(AppMessage::UsageFetched(res));
        });
    }

    fn start_proxy_test(&mut self, id: String, url: String, test_google: bool) {
        let google_api_key = if test_google {
            self.config.first_enabled_google_api_key()
        } else {
            String::new()
        };
        self.proxy_tests.insert(id.clone(), ProxyTestState::Running);
        let tx = self.tx.clone();
        tokio::spawn(async move {
            let result = run_proxy_test(id, url, test_google, google_api_key).await;
            let _ = tx.send(AppMessage::ProxyTested(result));
        });
    }

    /// «Gemini: напрямую» / «Gemini: через «Прокси 1» (url)»; a url that
    /// matches no entry can only come from the DELEGATOR_PROXY env override.
    fn proxy_status_line(&self, provider: &str, provider_label: &str) -> String {
        let Some(url) = self.config.effective_proxy_for(provider) else {
            return format!("{provider_label}: напрямую");
        };
        let entry_label = self
            .config
            .proxies
            .iter()
            .find(|proxy| proxy.enabled && proxy.url.trim() == url)
            .map(|proxy| proxy.label.clone());
        match entry_label {
            Some(label) => format!("{provider_label}: через «{label}» ({url})"),
            None => format!("{provider_label}: через {url} (переменная окружения DELEGATOR_PROXY)"),
        }
    }

    fn api_keys_need_attention(&self) -> bool {
        let google_missing = !self.config.enabled_gemini_models.is_empty()
            && !self
                .config
                .google_accounts
                .iter()
                .any(|account| account.enabled);
        let openrouter_selected = self
            .config
            .enabled_opencode_models
            .iter()
            .any(|model| model.starts_with("openrouter/"));
        let openrouter_key_missing = openrouter_selected
            && !self
                .config
                .opencode_accounts
                .iter()
                .any(|account| account.enabled);
        google_missing || openrouter_key_missing
    }

    /// Re-reads the cooldown ledger at most every REFRESH. One small local file
    /// and no provider call, so it stays honest while the window is open and
    /// costs nothing while it is not (the tray runs no `update()` at all).
    fn refresh_limits(&mut self) {
        const REFRESH: Duration = Duration::from_secs(20);
        if self.limits_read_at.is_some_and(|at| at.elapsed() < REFRESH) {
            return;
        }
        self.limits_read_at = Some(Instant::now());
        let (gemini, opencode) = read_limits(&crate::config::runtime_home_dir());
        self.gemini_limit = gemini;
        self.opencode_limit = opencode;
    }

    /// Forgets a run the IDE chat abandoned. Nothing is lost that was not lost
    /// already: the answers live in the core's memory and no `finish` is coming.
    fn cancel_benchmark(&mut self, run_id: String) {
        let tx = self.tx.clone();
        let ctx = self.egui_ctx.clone();
        self.benchmark_status = None;
        self.benchmark_was_running = false;
        tokio::spawn(async move {
            let result = cancel_run(run_id).await;
            let _ = tx.send(AppMessage::BenchmarkCancelled(result));
            ctx.request_repaint();
        });
    }

    fn opencode_models_need_attention(&self) -> bool {
        self.config.enabled_opencode_models.is_empty()
            || (self
                .config
                .enabled_opencode_models
                .iter()
                .any(|model| model.starts_with("opencode/"))
                && !self.dependencies.opencode_cli_available())
    }

    /// Google AI Studio keys. Body unchanged from the old «API-ключи» tab, which
    /// held Google and OpenCode side by side; each provider now owns its panel.
    fn draw_google_keys(&mut self, ui: &mut egui::Ui) {
        egui::ScrollArea::vertical().show(ui, |ui| {
            ui.heading("Google AI Studio");
            ui.label(
                "Ключи нескольких аккаунтов переключаются автоматически при исчерпании квоты.",
            );
            if !self
                .config
                .google_accounts
                .iter()
                .any(|account| account.enabled)
            {
                ui.colored_label(self.theme.warning_color(), "Нет включённого Google-ключа.");
            }

            let mut save_account: Option<(String, String, String, bool)> = None;
            let mut remove_account: Option<String> = None;
            for draft in &mut self.google_account_drafts {
                ui.group(|ui| {
                    ui.horizontal(|ui| {
                        ui.checkbox(&mut draft.enabled, "Включён");
                        ui.strong("Сохранённый Google-аккаунт");
                    });
                    ui.label("Название аккаунта:");
                    ui.add(
                        egui::TextEdit::singleline(&mut draft.label)
                            .desired_width(ui.available_width()),
                    );
                    ui.label("Новый ключ (пусто — оставить текущий):");
                    ui.add(
                        egui::TextEdit::singleline(&mut draft.new_key)
                            .password(true)
                            .desired_width(ui.available_width()),
                    );
                    ui.horizontal(|ui| {
                        if ui.button("Сохранить изменения").clicked() {
                            save_account = Some((
                                draft.id.clone(),
                                draft.label.clone(),
                                draft.new_key.clone(),
                                draft.enabled,
                            ));
                        }
                        if ui
                            .button(
                                egui::RichText::new("Удалить ключ").color(self.theme.error_color()),
                            )
                            .clicked()
                        {
                            remove_account = Some(draft.id.clone());
                        }
                    });
                });
                ui.add_space(4.0);
            }
            if let Some((id, label, new_key, enabled)) = save_account {
                let new_key = if new_key.trim().is_empty() {
                    None
                } else {
                    Some(new_key.as_str())
                };
                match self
                    .config
                    .update_google_account(&id, &label, new_key, enabled)
                {
                    Ok(()) => {
                        if let Some(draft) = self
                            .google_account_drafts
                            .iter_mut()
                            .find(|draft| draft.id == id)
                        {
                            draft.new_key.clear();
                        }
                        self.status_message = "Google-аккаунт сохранён".to_string();
                    }
                    Err(err) => self.status_message = err,
                }
            }
            if let Some(id) = remove_account {
                self.config.remove_google_account(&id);
                self.google_account_drafts.retain(|draft| draft.id != id);
                self.status_message = "Google-ключ удалён".to_string();
            }

            ui.group(|ui| {
                ui.strong("Добавить Google-ключ");
                ui.label("Название аккаунта:");
                ui.add(
                    egui::TextEdit::singleline(&mut self.new_google_label)
                        .hint_text("Например: Рабочий Google")
                        .desired_width(ui.available_width()),
                );
                ui.label("API-ключ Google AI Studio:");
                ui.add(
                    egui::TextEdit::singleline(&mut self.new_google_key)
                        .password(true)
                        .desired_width(ui.available_width()),
                );
                if ui.button("Добавить Google-ключ").clicked() {
                    match self
                        .config
                        .add_google_account(&self.new_google_label, &self.new_google_key)
                    {
                        Ok(()) => {
                            if let Some(account) = self.config.google_accounts.last() {
                                self.google_account_drafts.push(ApiAccountDraft {
                                    id: account.id.clone(),
                                    label: account.label.clone(),
                                    new_key: String::new(),
                                    enabled: account.enabled,
                                });
                            }
                            self.new_google_label.clear();
                            self.new_google_key.clear();
                            self.status_message = "Google-ключ добавлен".to_string();
                        }
                        Err(err) => self.status_message = err,
                    }
                }
            });
        });
    }

    /// OpenCode / OpenRouter keys. One key authorises both the CLI and the direct
    /// OpenRouter path, which is why it never moved into `custom_providers`.
    fn draw_opencode_keys(&mut self, ui: &mut egui::Ui) {
        egui::ScrollArea::vertical().show(ui, |ui| {
            ui.add_space(16.0);
            ui.separator();
            ui.add_space(8.0);
            ui.heading("OpenCode / OpenRouter");
            ui.label("Ключи нужны для моделей openrouter/*; модели opencode/* авторизует сам OpenCode CLI.");

            let mut save_opencode: Option<(String, String, String, bool)> = None;
            let mut remove_opencode: Option<String> = None;
            for draft in &mut self.opencode_account_drafts {
                ui.group(|ui| {
                    ui.horizontal(|ui| {
                        ui.checkbox(&mut draft.enabled, "Включён");
                        ui.strong("Сохранённый OpenCode/OpenRouter-аккаунт");
                    });
                    ui.label("Название аккаунта:");
                    ui.add(
                        egui::TextEdit::singleline(&mut draft.label)
                            .desired_width(ui.available_width()),
                    );
                    ui.label("Новый ключ (пусто — оставить текущий):");
                    ui.add(
                        egui::TextEdit::singleline(&mut draft.new_key)
                            .password(true)
                            .desired_width(ui.available_width()),
                    );
                    ui.horizontal(|ui| {
                        if ui.button("Сохранить изменения").clicked() {
                            save_opencode = Some((
                                draft.id.clone(),
                                draft.label.clone(),
                                draft.new_key.clone(),
                                draft.enabled,
                            ));
                        }
                        if ui
                            .button(egui::RichText::new("Удалить ключ").color(self.theme.error_color()))
                            .clicked()
                        {
                            remove_opencode = Some(draft.id.clone());
                        }
                    });
                });
                ui.add_space(6.0);
            }

            if let Some((id, label, new_key, enabled)) = save_opencode {
                let new_key = if new_key.trim().is_empty() {
                    None
                } else {
                    Some(new_key.as_str())
                };
                match self.config.update_opencode_account(
                    &id,
                    &label,
                    new_key,
                    enabled,
                ) {
                    Ok(()) => {
                        if let Some(draft) = self
                            .opencode_account_drafts
                            .iter_mut()
                            .find(|draft| draft.id == id)
                        {
                            draft.new_key.clear();
                        }
                        self.status_message =
                            "OpenCode/OpenRouter-аккаунт сохранён".to_string();
                    }
                    Err(err) => self.status_message = err,
                }
            }
            if let Some(id) = remove_opencode {
                self.config.remove_opencode_account(&id);
                self.opencode_account_drafts
                    .retain(|draft| draft.id != id);
                self.status_message =
                    "OpenCode/OpenRouter-ключ удалён".to_string();
            }

            ui.group(|ui| {
                ui.strong("Добавить OpenCode/OpenRouter-ключ");
                ui.label("Название аккаунта:");
                ui.add(
                    egui::TextEdit::singleline(&mut self.new_opencode_label)
                        .hint_text("Например: Основной OpenRouter")
                        .desired_width(ui.available_width()),
                );
                ui.label("API-ключ:");
                ui.add(
                    egui::TextEdit::singleline(&mut self.new_opencode_key)
                        .password(true)
                        .desired_width(ui.available_width()),
                );
                if ui.button("Добавить OpenCode/OpenRouter-ключ").clicked() {
                    match self.config.add_opencode_account(
                        &self.new_opencode_label,
                        &self.new_opencode_key,
                    ) {
                        Ok(()) => {
                            if let Some(account) = self.config.opencode_accounts.last()
                            {
                                self.opencode_account_drafts.push(ApiAccountDraft {
                                    id: account.id.clone(),
                                    label: account.label.clone(),
                                    new_key: String::new(),
                                    enabled: account.enabled,
                                });
                            }
                            self.new_opencode_label.clear();
                            self.new_opencode_key.clear();
                            self.status_message =
                                "OpenCode/OpenRouter-ключ добавлен".to_string();
                        }
                        Err(err) => self.status_message = err,
                    }
                }
            });
        });
    }

    /// The Gemini model allowlist — the old «Модели Gemini» tab.
    fn draw_gemini_models(&mut self, ui: &mut egui::Ui) {
        ui.label("Delegator использует только отмеченные модели Google.");
        if let Some(limit) = self.gemini_limit.clone() {
            limit_banner(ui, &self.theme, "Google AI Studio", &limit);
        }
        ui.horizontal(|ui| {
            ui.label("Поиск:");
            ui.text_edit_singleline(&mut self.gemini_search);
            if self.is_loading_gemini {
                ui.spinner();
            }
        });

        ui.separator();

        // `auto_shrink` off horizontally: without it the area is only
        // as wide as its widest row, so widening the window leaves
        // the scrollbar stranded in the middle instead of at the
        // right edge where it belongs.
        egui::ScrollArea::vertical()
            .auto_shrink([false, false])
            .show(ui, |ui| {
                for model in &self.gemini_models {
                    if !self.gemini_search.is_empty()
                        && !model
                            .id
                            .to_lowercase()
                            .contains(&self.gemini_search.to_lowercase())
                    {
                        continue;
                    }

                    let mut checked = self.config.enabled_gemini_models.contains(&model.id);
                    ui.horizontal(|ui| {
                        if ui.checkbox(&mut checked, &model.name).changed() {
                            if checked {
                                self.config.enabled_gemini_models.push(model.id.clone());
                            } else {
                                self.config
                                    .enabled_gemini_models
                                    .retain(|id| id != &model.id);
                            }
                            self.config.save();
                        }
                        ui.colored_label(self.theme.weak_text_color(), format!("({})", model.id));
                    });
                }
            });
    }

    /// The OpenCode model allowlist — the old «Модели OpenCode» tab.
    fn draw_opencode_models(&mut self, ui: &mut egui::Ui) {
        ui.label("Список берётся из OpenCode CLI: новые бесплатные модели включаются сами, сильные — сверху.");
        if let Some(limit) = self.opencode_limit.clone() {
            limit_banner(ui, &self.theme, "OpenCode", &limit);
        }
        let warning = self.theme.warning_color();
        let success = self.theme.success_color();
        let weak = self.theme.weak_text_color();
        let cli_required = self
            .config
            .enabled_opencode_models
            .iter()
            .any(|model| model.starts_with("opencode/"));
        // Deferred so the button handlers can take &mut self after
        // the layout closures have released their borrows.
        let mut install_request = false;
        let mut upgrade_request = false;
        let mut redetect_request = false;
        let mut open_link: Option<&'static str> = None;
        if cli_required && !self.dependencies.opencode_cli_available() {
            let fill =
                egui::Color32::from_rgba_unmultiplied(warning.r(), warning.g(), warning.b(), 28);
            let installing = matches!(self.opencode_install, Some(InstallState::Running(_)));
            // Without either installer nothing can be automated —
            // the manual links are then the only way forward.
            let can_install =
                self.dependencies.winget_available() || self.dependencies.npm_available();
            let failed = matches!(self.opencode_install, Some(InstallState::Done(Err(_))));
            egui::Frame::none()
                .fill(fill)
                .stroke(egui::Stroke::new(1.5, warning))
                .rounding(6.0)
                .inner_margin(10.0)
                .show(ui, |ui| {
                    ui.colored_label(warning, "Нужен OpenCode CLI для моделей opencode/*.");
                    ui.horizontal(|ui| {
                        let install = ui
                            .add_enabled(
                                can_install && !installing,
                                egui::Button::new("Установить"),
                            )
                            .on_hover_text(
                                "winget install --id SST.opencode\nnpm install -g opencode-ai",
                            )
                            .on_disabled_hover_text(
                                "Не найдены ни winget, ни npm — установите вручную",
                            );
                        if install.clicked() {
                            install_request = true;
                        }
                        if ui
                            .add_enabled(!installing, egui::Button::new("Проверить снова"))
                            .clicked()
                        {
                            redetect_request = true;
                        }
                        match &self.opencode_install {
                            Some(InstallState::Running(step)) => {
                                ui.spinner();
                                ui.label(step.status_line());
                            }
                            Some(InstallState::Done(Ok(()))) => {
                                ui.colored_label(success, "Готово");
                            }
                            Some(InstallState::Done(Err(reason))) => {
                                ui.colored_label(warning, "Не удалось установить")
                                    .on_hover_text(reason.as_str());
                            }
                            None => {}
                        }
                    });
                    ui.colored_label(weak, "Windows может запросить подтверждение (UAC).");
                    if failed || !can_install {
                        ui.horizontal(|ui| {
                            if ui.link("Скачать Node.js").clicked() {
                                open_link = Some(NODEJS_DOWNLOAD_URL);
                            }
                            if ui.link("Сайт OpenCode").clicked() {
                                open_link = Some(OPENCODE_SITE_URL);
                            }
                        });
                    }
                });
            ui.add_space(8.0);
        } else if let Some(path) = &self.dependencies.opencode_cli_path {
            ui.colored_label(success, "OpenCode CLI установлен")
                .on_hover_text(path.display().to_string());
        }
        if self.dependencies.opencode_cli_available() {
            let upgrading = matches!(self.opencode_upgrade, Some(CliJobState::Running));
            ui.horizontal(|ui| {
                if ui
                    .add_enabled(!upgrading, egui::Button::new("Обновить CLI"))
                    .clicked()
                {
                    upgrade_request = true;
                }
                match &self.opencode_upgrade {
                    Some(CliJobState::Running) => {
                        ui.spinner();
                        ui.label("Обновляю…");
                    }
                    Some(CliJobState::Done(Ok(()))) => {
                        ui.colored_label(success, "Обновлено");
                    }
                    Some(CliJobState::Done(Err(reason))) => {
                        ui.colored_label(warning, "Не удалось обновить")
                            .on_hover_text(reason.as_str());
                    }
                    None => {}
                }
            });
        }
        if redetect_request {
            self.dependencies = DependencyStatus::detect();
        }
        if install_request {
            self.start_opencode_install();
        }
        if upgrade_request {
            self.start_opencode_upgrade();
        }
        if let Some(url) = open_link {
            open_url(url);
        }
        if self.config.enabled_opencode_models.is_empty() {
            ui.colored_label(self.theme.warning_color(), "Не выбрана ни одна модель.");
        }
        if self.opencode_catalog_is_fallback {
            ui.colored_label(
                self.theme.warning_color(),
                "Список не получен от OpenCode CLI — показан встроенный минимум.",
            )
            .on_hover_text(
                "Запрос списка к CLI не успел или не удался, поэтому здесь только \
                 встроенные модели OpenCode Zen плюс те, что вы уже включили. \
                 Ваш выбор не потерян и делегирование работает как обычно. \
                 Нажмите «Обновить CLI» или откройте вкладку заново.",
            );
        }
        ui.horizontal(|ui| {
            ui.label("Поиск:");
            ui.text_edit_singleline(&mut self.opencode_search);
            if self.is_loading_opencode {
                ui.spinner();
            }
        });

        ui.separator();

        // `auto_shrink` off horizontally: without it the area is only
        // as wide as its widest row, so widening the window leaves
        // the scrollbar stranded in the middle instead of at the
        // right edge where it belongs.
        egui::ScrollArea::vertical()
            .auto_shrink([false, false])
            .show(ui, |ui| {
                for model in &self.opencode_models {
                    if !self.opencode_search.is_empty()
                        && !model
                            .id
                            .to_lowercase()
                            .contains(&self.opencode_search.to_lowercase())
                    {
                        continue;
                    }

                    let mut checked = self.config.enabled_opencode_models.contains(&model.id);
                    ui.horizontal(|ui| {
                        let row = ui
                            .checkbox(&mut checked, &model.name)
                            .on_hover_text(crate::gui::opencode_setup::dpr_hint(&model.id));
                        if row.changed() {
                            if checked {
                                self.config.enabled_opencode_models.push(model.id.clone());
                            } else {
                                self.config
                                    .enabled_opencode_models
                                    .retain(|id| id != &model.id);
                            }
                            self.config.save();
                        }

                        if crate::models_service::is_custom_provider_model(&model.id) {
                            ui.colored_label(self.theme.accent_color(), "[СВОЙ]")
                                .on_hover_text(format!(
                                    "Провайдер из вашей конфигурации OpenCode: {}. \
                                 Работает и в обычном делегировании, и в бенчмарке.",
                                    model.provider
                                ));
                        } else if model.is_free {
                            ui.colored_label(self.theme.success_color(), "[FREE]");
                        }
                        ui.colored_label(self.theme.weak_text_color(), format!("({})", model.id));
                    });
                }
            });
    }

    /// The «API» tab: one button per provider, then that provider's keys or its
    /// models. Before this the same three things lived in three top-level tabs
    /// («API-ключи», «Модели Gemini», «Модели OpenCode»), so adding a fourth
    /// provider meant adding two more tabs to a row that already had to wrap.
    fn draw_api_tab(&mut self, ui: &mut egui::Ui) {
        let providers = self.api_provider_buttons();
        ui.horizontal_wrapped(|ui| {
            for (key, label, warn) in &providers {
                let selected = &self.api_provider == key;
                let mut text = egui::RichText::new(label);
                if *warn && !selected {
                    text = text.color(self.theme.warning_color());
                }
                if ui.selectable_label(selected, text).clicked() {
                    self.api_provider = key.clone();
                }
            }
            if ui
                .selectable_label(self.api_provider == ApiProvider::Add, "+ Добавить")
                .clicked()
            {
                self.api_provider = ApiProvider::Add;
            }
        });

        // A provider the user removed while looking at it would otherwise leave
        // the tab pointing at nothing.
        if !providers
            .iter()
            .any(|(key, _, _)| key == &self.api_provider)
            && self.api_provider != ApiProvider::Add
        {
            self.api_provider = ApiProvider::Google;
        }

        if self.api_provider != ApiProvider::Add {
            ui.add_space(4.0);
            ui.horizontal(|ui| {
                if ui
                    .selectable_label(self.api_section == ApiSection::Keys, "Ключи")
                    .clicked()
                {
                    self.api_section = ApiSection::Keys;
                }
                if ui
                    .selectable_label(self.api_section == ApiSection::Models, "Модели")
                    .clicked()
                {
                    self.api_section = ApiSection::Models;
                }
                ui.separator();
                if ui.button("Обновить списки моделей").clicked() {
                    self.refresh_models();
                }
                ui.colored_label(self.theme.weak_text_color(), self.status_message.as_str());
            });
        }
        ui.separator();

        match (self.api_provider.clone(), self.api_section) {
            (ApiProvider::Add, _) => self.draw_provider_picker(ui),
            (ApiProvider::Google, ApiSection::Keys) => self.draw_google_keys(ui),
            (ApiProvider::Google, ApiSection::Models) => self.draw_gemini_models(ui),
            (ApiProvider::OpenCode, ApiSection::Keys) => self.draw_opencode_keys(ui),
            (ApiProvider::OpenCode, ApiSection::Models) => self.draw_opencode_models(ui),
            (ApiProvider::Custom(id), ApiSection::Keys) => self.draw_custom_keys(ui, &id),
            (ApiProvider::Custom(id), ApiSection::Models) => self.draw_custom_models(ui, &id),
        }
    }

    /// One row per provider: its key, its button label, and whether it wants
    /// attention (no usable key). The two built-ins are always present — they
    /// own storage of their own and cannot be removed.
    fn api_provider_buttons(&self) -> Vec<(ApiProvider, String, bool)> {
        api_provider_rows(&self.config)
    }

    /// «+ Добавить»: the presets, then a hand-written provider. Adding one only
    /// creates the row — nothing is called until a key is pasted, so a preset
    /// whose free tier has changed costs a listing, not a failed delegation.
    fn draw_provider_picker(&mut self, ui: &mut egui::Ui) {
        egui::ScrollArea::vertical().show(ui, |ui| {
            ui.heading("Добавить провайдера");
            ui.label(
                "Любой сервис с OpenAI-совместимым /chat/completions. \
                 Ключ вставляется здесь — настраивать OpenCode CLI не нужно.",
            );
            ui.add_space(10.0);

            let mut add_request: Option<(String, String, String, Vec<String>)> = None;
            for preset in config::PROVIDER_PRESETS {
                let already = self.config.custom_provider(preset.id).is_some();
                ui.group(|ui| {
                    ui.horizontal(|ui| {
                        ui.strong(preset.label);
                        ui.colored_label(self.theme.weak_text_color(), preset.base_url);
                    });
                    ui.colored_label(
                        self.theme.weak_text_color(),
                        format!("Модели: {}", preset.models.join(", ")),
                    );
                    if already {
                        ui.colored_label(self.theme.success_color(), "Уже добавлен");
                    } else if ui.button(format!("Добавить {}", preset.label)).clicked() {
                        add_request = Some((
                            preset.id.to_string(),
                            preset.label.to_string(),
                            preset.base_url.to_string(),
                            preset.models.iter().map(|m| m.to_string()).collect(),
                        ));
                    }
                });
                ui.add_space(6.0);
            }

            ui.add_space(8.0);
            ui.separator();
            ui.add_space(8.0);
            ui.strong("Свой провайдер");
            ui.horizontal(|ui| {
                ui.label("Идентификатор:");
                ui.add(
                    egui::TextEdit::singleline(&mut self.new_provider_id)
                        .desired_width(140.0)
                        .hint_text("bai"),
                );
                ui.label("Название:");
                ui.add(
                    egui::TextEdit::singleline(&mut self.new_provider_label).desired_width(160.0),
                );
            });
            ui.horizontal(|ui| {
                ui.label("Адрес API:");
                ui.add(
                    egui::TextEdit::singleline(&mut self.new_provider_base_url)
                        .desired_width(320.0)
                        .hint_text("https://api.example.com/v1"),
                );
            });
            ui.colored_label(
                self.theme.weak_text_color(),
                "Идентификатор становится префиксом моделей: bai/hy3.",
            );
            if ui.button("Добавить провайдера").clicked() {
                add_request = Some((
                    self.new_provider_id.clone(),
                    self.new_provider_label.clone(),
                    self.new_provider_base_url.clone(),
                    Vec::new(),
                ));
            }

            if let Some((id, label, base_url, models)) = add_request {
                match self
                    .config
                    .add_custom_provider(&id, &label, &base_url, &models)
                {
                    Ok(()) => {
                        let id = id.trim().to_ascii_lowercase();
                        self.new_provider_id.clear();
                        self.new_provider_label.clear();
                        self.new_provider_base_url.clear();
                        self.status_message = format!("Провайдер «{id}» добавлен");
                        self.api_provider = ApiProvider::Custom(id);
                        self.api_section = ApiSection::Keys;
                    }
                    Err(err) => self.status_message = err,
                }
            }
            ui.add_space(8.0);
            ui.colored_label(self.theme.weak_text_color(), self.status_message.as_str());
        });
    }

    /// Keys of one user-added provider. Same shape as the two built-in key
    /// panels on purpose: one place to learn, three providers.
    fn draw_custom_keys(&mut self, ui: &mut egui::Ui, provider_id: &str) {
        let Some(provider) = self.config.custom_provider(provider_id) else {
            return;
        };
        let title = if provider.label.is_empty() {
            provider.id.clone()
        } else {
            provider.label.clone()
        };
        let base_url = provider.base_url.clone();
        let has_enabled_key = provider.accounts.iter().any(|account| account.enabled);
        let mut provider_enabled = provider.enabled;
        self.sync_provider_drafts(provider_id);

        egui::ScrollArea::vertical().show(ui, |ui| {
            ui.heading(&title);
            ui.colored_label(self.theme.weak_text_color(), &base_url);
            ui.label("Ключи хранятся только здесь и шифруются Windows DPAPI.");
            if ui
                .checkbox(&mut provider_enabled, "Провайдер включён")
                .changed()
            {
                self.config
                    .set_custom_provider_enabled(provider_id, provider_enabled);
            }
            if !has_enabled_key {
                ui.colored_label(
                    self.theme.warning_color(),
                    "Нет включённого ключа — модели этого провайдера не участвуют в делегировании.",
                );
            }
            ui.add_space(8.0);

            let mut save_account: Option<(String, String, String, bool)> = None;
            let mut remove_account: Option<String> = None;
            let drafts = self
                .provider_account_drafts
                .entry(provider_id.to_string())
                .or_default();
            for draft in drafts.iter_mut() {
                ui.group(|ui| {
                    ui.horizontal(|ui| {
                        ui.checkbox(&mut draft.enabled, "Включён");
                        ui.label("Название:");
                        ui.add(egui::TextEdit::singleline(&mut draft.label).desired_width(180.0));
                    });
                    ui.label("Новый ключ (пусто — оставить текущий):");
                    ui.add(
                        egui::TextEdit::singleline(&mut draft.new_key)
                            .password(true)
                            .desired_width(320.0),
                    );
                    ui.horizontal(|ui| {
                        if ui.button("Сохранить").clicked() {
                            save_account = Some((
                                draft.id.clone(),
                                draft.label.clone(),
                                draft.new_key.clone(),
                                draft.enabled,
                            ));
                        }
                        if ui
                            .button(
                                egui::RichText::new("Удалить ключ").color(self.theme.error_color()),
                            )
                            .clicked()
                        {
                            remove_account = Some(draft.id.clone());
                        }
                    });
                });
                ui.add_space(6.0);
            }

            if let Some((id, label, new_key, enabled)) = save_account {
                let key = if new_key.trim().is_empty() {
                    None
                } else {
                    Some(new_key.as_str())
                };
                match self
                    .config
                    .update_provider_account(provider_id, &id, &label, key, enabled)
                {
                    Ok(()) => {
                        if let Some(drafts) = self.provider_account_drafts.get_mut(provider_id) {
                            if let Some(draft) = drafts.iter_mut().find(|draft| draft.id == id) {
                                draft.new_key.clear();
                            }
                        }
                        self.status_message = "Ключ сохранён".to_string();
                    }
                    Err(err) => self.status_message = err,
                }
            }
            if let Some(id) = remove_account {
                self.config.remove_provider_account(provider_id, &id);
                if let Some(drafts) = self.provider_account_drafts.get_mut(provider_id) {
                    drafts.retain(|draft| draft.id != id);
                }
                self.status_message = "Ключ удалён".to_string();
            }

            ui.add_space(8.0);
            ui.strong("Добавить ключ");
            ui.horizontal(|ui| {
                ui.label("Название:");
                ui.add(
                    egui::TextEdit::singleline(&mut self.new_provider_account_label)
                        .desired_width(180.0),
                );
            });
            ui.label("API-ключ:");
            ui.add(
                egui::TextEdit::singleline(&mut self.new_provider_account_key)
                    .password(true)
                    .desired_width(320.0),
            );
            if ui.button("Добавить ключ").clicked() {
                let label = if self.new_provider_account_label.trim().is_empty() {
                    format!("{title} 1")
                } else {
                    self.new_provider_account_label.clone()
                };
                match self.config.add_provider_account(
                    provider_id,
                    &label,
                    &self.new_provider_account_key.clone(),
                ) {
                    Ok(()) => {
                        self.new_provider_account_label.clear();
                        self.new_provider_account_key.clear();
                        self.provider_account_drafts.remove(provider_id);
                        self.status_message = "Ключ добавлен".to_string();
                    }
                    Err(err) => self.status_message = err,
                }
            }

            ui.add_space(14.0);
            ui.separator();
            if ui
                .button(egui::RichText::new("Удалить провайдера").color(self.theme.error_color()))
                .clicked()
            {
                self.config.remove_custom_provider(provider_id);
                self.provider_account_drafts.remove(provider_id);
                self.api_provider = ApiProvider::Google;
                self.status_message = format!("Провайдер «{provider_id}» удалён");
            }
        });
    }

    /// Models of one user-added provider. The list is `known_models` and the
    /// ticks are `enabled_models`: I8 says the GUI selection is the mandatory
    /// allowlist, so discovery may extend the list but never tick a box.
    fn draw_custom_models(&mut self, ui: &mut egui::Ui, provider_id: &str) {
        let Some(provider) = self.config.custom_provider(provider_id) else {
            return;
        };
        let known: Vec<String> = provider.known_models.clone();
        let enabled: Vec<String> = provider.enabled_models.clone();
        let base_url = provider.base_url.clone();

        ui.label(
            "Отмеченные модели участвуют в делегировании. \
             Идентификатор в пуле — «провайдер/модель».",
        );
        ui.colored_label(self.theme.weak_text_color(), &base_url);
        // Counted the way the RUNTIME counts: ticked, reachable (the provider
        // has a key), and not refused by the provider itself. A number that
        // ignored the verdicts would claim models that never get a turn.
        let counted_now = unix_now();
        let in_pool = self
            .config
            .enabled_custom_provider_models()
            .iter()
            .filter(|id| id.starts_with(&format!("{provider_id}/")))
            .filter(|id| {
                id.split_once('/').is_some_and(|(_, model)| {
                    self.provider_verdicts
                        .get(provider_id, model, counted_now)
                        .is_none_or(|verdict| verdict.verdict.usable())
                })
            })
            .count();
        ui.colored_label(
            self.theme.weak_text_color(),
            format!("Сейчас участвуют в делегировании: {in_pool}"),
        );
        let mut recheck = false;
        ui.horizontal(|ui| {
            if ui
                .add_enabled(
                    !background::provider_round_running(),
                    egui::Button::new("Проверить модели"),
                )
                .on_hover_text(
                    "Спрашивает провайдера, что он отдаёт по этому ключу. \
                     Проверка сама раз в сутки; ответ кэшируется, \
                     отрицательный — на 48 часов.",
                )
                .clicked()
            {
                recheck = true;
            }
            if background::provider_round_running() {
                ui.spinner();
            }
        });
        ui.separator();
        let now = unix_now();

        let mut toggle: Option<(String, bool)> = None;
        let mut add_model = false;
        egui::ScrollArea::vertical()
            .auto_shrink([false, false])
            .show(ui, |ui| {
                if known.is_empty() {
                    ui.colored_label(
                        self.theme.weak_text_color(),
                        "Список пуст — добавьте модель вручную.",
                    );
                }
                for model in &known {
                    let mut checked = enabled.iter().any(|id| id == model);
                    let verdict = self.provider_verdicts.get(provider_id, model, now);
                    ui.horizontal(|ui| {
                        if ui.checkbox(&mut checked, model).changed() {
                            toggle = Some((model.clone(), checked));
                        }
                        ui.colored_label(
                            self.theme.weak_text_color(),
                            format!("({provider_id}/{model})"),
                        );
                        // The provider's own answer, quoted. A ticked model
                        // that will only ever reply 403 looks identical to a
                        // working one until something says so.
                        if let Some(verdict) = verdict {
                            let color = if verdict.verdict.usable() {
                                self.theme.success_color()
                            } else {
                                self.theme.warning_color()
                            };
                            let label = ui.colored_label(color, verdict.verdict.label());
                            if !verdict.reason.is_empty() {
                                label.on_hover_text(&verdict.reason);
                            }
                        }
                    });
                }
                ui.add_space(10.0);
                ui.separator();
                ui.strong("Добавить модель");
                ui.horizontal(|ui| {
                    ui.add(
                        egui::TextEdit::singleline(&mut self.new_provider_model)
                            .desired_width(240.0)
                            .hint_text("hy3"),
                    );
                    if ui.button("Добавить").clicked() {
                        add_model = true;
                    }
                });
            });

        if let Some((model, checked)) = toggle {
            self.config
                .set_provider_model_enabled(provider_id, &model, checked);
        }
        if add_model {
            let model = self.new_provider_model.trim().to_string();
            if !model.is_empty() {
                self.config
                    .set_provider_model_enabled(provider_id, &model, true);
                self.new_provider_model.clear();
                self.status_message = format!("Модель «{model}» добавлена");
            }
        }
        if recheck {
            self.start_provider_catalog_refresh();
        }
    }

    /// Rebuilds the edit drafts for one provider when they do not match the
    /// stored accounts. Without it, a key added on another panel — or a
    /// provider removed and re-added — would edit rows that no longer exist.
    fn sync_provider_drafts(&mut self, provider_id: &str) {
        let Some(provider) = self.config.custom_provider(provider_id) else {
            self.provider_account_drafts.remove(provider_id);
            return;
        };
        let stored: Vec<String> = provider
            .accounts
            .iter()
            .map(|account| account.id.clone())
            .collect();
        let drafts = self
            .provider_account_drafts
            .entry(provider_id.to_string())
            .or_default();
        let current: Vec<String> = drafts.iter().map(|draft| draft.id.clone()).collect();
        if current == stored {
            return;
        }
        let accounts = self
            .config
            .custom_provider(provider_id)
            .map(|provider| provider.accounts.clone())
            .unwrap_or_default();
        self.provider_account_drafts.insert(
            provider_id.to_string(),
            accounts
                .iter()
                .map(|account| ApiAccountDraft {
                    id: account.id.clone(),
                    label: account.label.clone(),
                    new_key: String::new(),
                    enabled: account.enabled,
                })
                .collect(),
        );
    }
}

/// One-word verdict chip: a filled, outlined label so the winning side of a row
/// is visible at a glance without reading numbers.
fn highlight_label(ui: &mut egui::Ui, text: &str, color: egui::Color32) {
    let fill = egui::Color32::from_rgba_unmultiplied(color.r(), color.g(), color.b(), 40);
    egui::Frame::none()
        .fill(fill)
        .stroke(egui::Stroke::new(1.0, color))
        .rounding(4.0)
        .inner_margin(egui::Margin::symmetric(5.0, 1.0))
        .show(ui, |ui| {
            ui.colored_label(color, text);
        });
}

/// Extra line for an IDE row whose scope is easy to misread.
///
/// VSCodium has no chat model of its own: the instruction file goes to the
/// editor's built-in chat, while an agent that arrives as an EXTENSION (Claude
/// Code, Gemini) reads its own profile — the row named after that agent. Without
/// this, ticking «VSCodium» and seeing the Claude extension still know nothing
/// looks like a broken integration.
fn ide_row_hint(name: &str) -> Option<&'static str> {
    match name {
        "VSCodium" => Some(
            "Инструкция пишется для встроенного чата VSCodium (%APPDATA%\\VSCodium\\User\\prompts).\n\
             Расширения со своим агентом читают свои профили: для них включите «Claude» или «Antigravity».",
        ),
        _ => None,
    }
}

/// What a tab is trying to tell the user before they click it.
#[derive(Debug, Clone, Copy, PartialEq)]
enum TabAccent {
    None,
    /// Something needs attention (no keys, no models).
    Warning,
    /// Work is happening on that tab right now; the value is the pulse phase.
    Busy(f32),
}

impl TabAccent {
    fn warn(active: bool) -> Self {
        if active {
            Self::Warning
        } else {
            Self::None
        }
    }
}

/// «OpenCode сообщает о достижении лимита… Примерно до сброса: 3д 5ч 23м.»
///
/// Deliberately not an error colour: nothing is broken and the user cannot fix
/// it — they need to know when it comes back, and that delegation moves to the
/// other provider meanwhile.
fn limit_banner(ui: &mut egui::Ui, theme: &ThemeConfig, provider: &str, limit: &ProviderLimit) {
    let colour = theme.warning_color();
    let fill = egui::Color32::from_rgba_unmultiplied(colour.r(), colour.g(), colour.b(), 28);
    egui::Frame::none()
        .fill(fill)
        .stroke(egui::Stroke::new(1.0, colour))
        .rounding(5.0)
        .inner_margin(8.0)
        .show(ui, |ui| {
            ui.colored_label(colour, limit_line(provider, limit))
                .on_hover_text(format!(
                    "Причина по данным провайдера: {}. Пока лимит держится, Delegator \
                     обращается к другому провайдеру, если там остались модели.",
                    limit.reason
                ));
        });
    ui.add_space(4.0);
}

/// The two tabs that can light up; the rest are always plain. «API» carries
/// one accent for every provider under it — which one wants attention is shown
/// on its own button inside the tab, where the fix also lives.
#[derive(Debug, Clone, Copy)]
struct TabAccents {
    api: TabAccent,
    benchmark: TabAccent,
}

/// One row per provider for the «API» tab: its key, its button label, and
/// whether it wants attention (no enabled account). The two built-ins are always
/// present — they own storage of their own and cannot be removed.
///
/// A free function over `AppConfig` rather than a method, because screen access
/// is denied on the machine this ships from (D7): what the tab offers has to be
/// assertable without anyone looking at it.
fn api_provider_rows(config: &AppConfig) -> Vec<(ApiProvider, String, bool)> {
    let mut rows = vec![
        (
            ApiProvider::Google,
            "Google AI Studio".to_string(),
            !config.google_accounts.iter().any(|account| account.enabled),
        ),
        (
            ApiProvider::OpenCode,
            "OpenCode / OpenRouter".to_string(),
            !config
                .opencode_accounts
                .iter()
                .any(|account| account.enabled),
        ),
    ];
    for provider in &config.custom_providers {
        let label = if provider.label.is_empty() {
            provider.id.clone()
        } else {
            provider.label.clone()
        };
        rows.push((
            ApiProvider::Custom(provider.id.clone()),
            label,
            !provider.accounts.iter().any(|account| account.enabled),
        ));
    }
    rows
}

/// The navigation row. One function because it is drawn in two layouts — see
/// the call site: unwrapped once, to measure how wide it wants to be, and
/// wrapped from then on so narrowing the window folds it onto a second line
/// instead of pushing tabs out of reach.
fn navigation_tabs(
    ui: &mut egui::Ui,
    active: &mut SelectedTab,
    theme: &ThemeConfig,
    accents: TabAccents,
) {
    let tabs = [
        (SelectedTab::Ides, "Интеграция", TabAccent::None),
        (SelectedTab::Api, "API", accents.api),
        (SelectedTab::Stats, "Статистика", TabAccent::None),
        (SelectedTab::Thinking, "Мышление", TabAccent::None),
        (SelectedTab::Benchmark, "Бенчмарк", accents.benchmark),
        (SelectedTab::Proxies, "Прокси", TabAccent::None),
    ];
    for (value, label, accent) in tabs {
        tab_button(ui, active, value, label, accent, theme);
    }
}

fn tab_button(
    ui: &mut egui::Ui,
    selected: &mut SelectedTab,
    value: SelectedTab,
    label: &str,
    accent: TabAccent,
    theme: &ThemeConfig,
) {
    // A benchmark takes ten minutes and is driven from the IDE chat, so the
    // window usually sits on some other tab while it runs. The pulse is the
    // only thing that says the work is still going.
    let (color, fill_alpha, stroke_alpha, hint) = match accent {
        TabAccent::None => {
            ui.selectable_value(selected, value, label);
            return;
        }
        TabAccent::Warning => (theme.warning_color(), 35u8, 255u8, ""),
        TabAccent::Busy(phase) => {
            let phase = phase.clamp(0.0, 1.0);
            (
                theme.accent_color(),
                // Never fades to nothing: it must read as "running", not as a
                // highlight that keeps disappearing.
                (18.0 + 46.0 * phase) as u8,
                (90.0 + 165.0 * phase) as u8,
                "Бенчмарк идёт — нажмите, чтобы посмотреть",
            )
        }
    };
    let fill = egui::Color32::from_rgba_unmultiplied(color.r(), color.g(), color.b(), fill_alpha);
    let stroke =
        egui::Color32::from_rgba_unmultiplied(color.r(), color.g(), color.b(), stroke_alpha);
    let response = egui::Frame::none()
        .fill(fill)
        .stroke(egui::Stroke::new(1.5, stroke))
        .rounding(5.0)
        .inner_margin(egui::Margin::symmetric(4.0, 2.0))
        .show(ui, |ui| {
            ui.selectable_value(selected, value, egui::RichText::new(label).color(color));
        });
    if !hint.is_empty() {
        response.response.on_hover_text(hint);
    }
}

impl eframe::App for DelegatorApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        if !self.window_theme_applied {
            ctx.send_viewport_cmd(egui::ViewportCommand::SetTheme(egui::SystemTheme::Dark));
            self.window_theme_applied = true;
        }

        // The tray may have rewritten config.json while this loop was frozen
        // («Включить/Отключить» is handled there, see gui::background). Reload
        // before drawing, otherwise the next `config.save()` from any checkbox
        // would silently undo it.
        let generation = background::config_generation();
        if generation != self.config_generation {
            self.config_generation = generation;
            self.config = AppConfig::load();
            set_toggle_label(self.config.delegator_enabled);
        }

        while let Ok(action) = self.tray_rx.try_recv() {
            match action {
                TrayAction::Open => {
                    self.hide_frames_left = 0;
                    ctx.send_viewport_cmd(egui::ViewportCommand::Visible(true));
                    // A hidden window can also be minimised; without this the
                    // window stays on the taskbar and never comes forward.
                    ctx.send_viewport_cmd(egui::ViewportCommand::Minimized(false));
                    ctx.send_viewport_cmd(egui::ViewportCommand::Focus);
                    // Windows refuses to let a background process take the
                    // foreground, so Focus alone is unreliable. A brief
                    // always-on-top flip raises the window; it is reset a few
                    // frames later so the window does not stay pinned.
                    ctx.send_viewport_cmd(egui::ViewportCommand::WindowLevel(
                        egui::WindowLevel::AlwaysOnTop,
                    ));
                    self.unpin_window_at = Some(Instant::now() + Duration::from_millis(400));
                }
                TrayAction::Quit => self.begin_shutdown(),
            }
        }

        // Shutdown takes a few seconds (core teardown), so say so on screen.
        // The close command must wait for the NEXT frame: a viewport command
        // sent in the same frame closes the window before this text is ever
        // presented. Exactly one extra frame, no sleeping.
        if self.shutting_down {
            egui::CentralPanel::default().show(ctx, |ui| {
                ui.vertical_centered(|ui| {
                    ui.add_space((ui.available_height() * 0.4).max(0.0));
                    ui.spinner();
                    ui.add_space(10.0);
                    ui.heading("Завершение работы Delegator…");
                });
            });
            if std::mem::replace(&mut self.shutdown_frame_painted, true) {
                ctx.send_viewport_cmd(egui::ViewportCommand::Close);
            }
            ctx.request_repaint();
            return;
        }

        // Autostart must stay in the tray. eframe shows the window after the
        // first painted frame no matter what, so the request has to be repeated
        // for a few frames before it sticks.
        if self.hide_frames_left > 0 {
            ctx.send_viewport_cmd(egui::ViewportCommand::Visible(false));
            self.hide_frames_left -= 1;
            ctx.request_repaint();
        }

        if let Some(deadline) = self.unpin_window_at {
            if Instant::now() >= deadline {
                ctx.send_viewport_cmd(egui::ViewportCommand::WindowLevel(
                    egui::WindowLevel::Normal,
                ));
                self.unpin_window_at = None;
            } else {
                ctx.request_repaint_after(Duration::from_millis(100));
            }
        }

        if ctx.input(|input| input.viewport().close_requested()) && !self.quitting {
            ctx.send_viewport_cmd(egui::ViewportCommand::CancelClose);
            ctx.send_viewport_cmd(egui::ViewportCommand::Visible(false));
        }
        ctx.request_repaint_after(Duration::from_millis(250));

        // Auto-fetch usage aggregates whenever the «Статистика» tab is opened.
        let stats_tab_active = self.active_tab == SelectedTab::Stats;
        if stats_tab_active && !self.stats_tab_was_active {
            self.refresh_usage();
        }
        self.stats_tab_was_active = stats_tab_active;

        let benchmark_tab_active = self.active_tab == SelectedTab::Benchmark;
        if benchmark_tab_active && !self.benchmark_tab_was_active {
            self.refresh_benchmark();
        }
        self.poll_benchmark_status(benchmark_tab_active);
        self.refresh_limits();
        // Between polls nothing would wake the loop, and the slow heartbeat
        // would stall on whatever frame the user last caused.
        if !benchmark_tab_active && self.benchmark_status.is_none() {
            ctx.request_repaint_after(Duration::from_millis(4000));
        }
        self.benchmark_tab_was_active = benchmark_tab_active;

        // Handle async responses
        while let Ok(msg) = self.rx.try_recv() {
            match msg {
                AppMessage::CoreStatus(status) => self.status_message = status,
                AppMessage::GeminiModelsFetched(res) => {
                    self.is_loading_gemini = false;
                    match res {
                        Ok(list) => self.gemini_models = list,
                        Err(err) => self.status_message = format!("Gemini error: {}", err),
                    }
                }
                AppMessage::OpenCodeModelsFetched(res) => {
                    self.is_loading_opencode = false;
                    match res {
                        Ok(catalog) => {
                            // Only a live `opencode models` run may adopt new
                            // Zen models / prune retired ones; the fallback
                            // catalog yields no ids for sync by design.
                            if let Some(discovered) = catalog.zen_ids_for_sync() {
                                if self.config.sync_opencode_catalog(&discovered) {
                                    self.config.save();
                                }
                                // The CLI just answered, so refresh the cached
                                // availability that drives the tab warnings.
                                if !self.dependencies.opencode_cli_available() {
                                    self.dependencies = DependencyStatus::detect();
                                }
                            }
                            // The runtime rewrites the strength catalog when it
                            // ages out, so re-read it with every listing.
                            self.zen_strengths = load_zen_strengths();
                            self.opencode_catalog_is_fallback = catalog.source
                                == crate::models_service::OpenCodeCatalogSource::Fallback;
                            // I8: the tab is an authoritative allowlist, so an
                            // enabled model always gets a row — a CLI hiccup must
                            // not hide a choice the user already made.
                            self.opencode_models = crate::gui::opencode_setup::with_enabled_models(
                                order_opencode_models(catalog.models, &self.zen_strengths),
                                &self.config.enabled_opencode_models,
                            );
                        }
                        Err(err) => self.status_message = format!("OpenCode error: {}", err),
                    }
                }
                AppMessage::UsageFetched(res) => {
                    self.is_loading_usage = false;
                    match res {
                        Ok(report) => {
                            self.usage_report = Some(report);
                            self.usage_error = None;
                        }
                        Err(err) => self.usage_error = Some(err),
                    }
                }
                AppMessage::OpenCodeInstallStep(step) => {
                    if matches!(self.opencode_install, Some(InstallState::Running(_))) {
                        self.opencode_install = Some(InstallState::Running(step));
                    }
                }
                AppMessage::OpenCodeCliJob(job, result) => {
                    let succeeded = result.is_ok();
                    match job {
                        CliJob::Install => self.opencode_install = Some(InstallState::Done(result)),
                        CliJob::Upgrade => self.opencode_upgrade = Some(CliJobState::Done(result)),
                    }
                    if succeeded {
                        // A newly installed or upgraded CLI can list new free
                        // models: re-detect it and re-read the catalog, which
                        // syncs them into the config as enabled by default.
                        self.dependencies = DependencyStatus::detect();
                        self.refresh_models();
                    }
                }
                AppMessage::ProxyTested(result) => {
                    // Drop results for proxies deleted while the test ran.
                    if self.config.proxies.iter().any(|p| p.id == result.id) {
                        self.proxy_tests
                            .insert(result.id.clone(), ProxyTestState::Done(result));
                    } else {
                        self.proxy_tests.remove(&result.id);
                    }
                }
                AppMessage::BenchmarkFetched(result) => {
                    self.benchmark_loading = false;
                    match result {
                        Ok(report) => {
                            self.benchmark_report = report;
                            self.benchmark_error = None;
                        }
                        Err(error) => self.benchmark_error = Some(error),
                    }
                }
                AppMessage::BenchmarkExported(result) => {
                    self.benchmark_exporting = false;
                    self.benchmark_export = Some(result);
                }
                AppMessage::BenchmarkCancelled(result) => {
                    if let Err(error) = result {
                        self.benchmark_error = Some(error);
                    }
                    self.refresh_benchmark();
                }
                AppMessage::BenchmarkStatus(status) => {
                    let running = status.is_some();
                    // A run that just ended has written its report: pick it up
                    // without making the user press «Обновить».
                    if self.benchmark_was_running && !running {
                        self.refresh_benchmark();
                    }
                    self.benchmark_was_running = running;
                    self.benchmark_status = status;
                }
                AppMessage::ProviderCatalogRefreshed(outcomes) => {
                    // `config` was written by the worker and the generation
                    // counter already told the loop above to reload it, so
                    // nothing here touches config — doing it twice is how a
                    // discovered model would be added on top of itself.
                    self.provider_verdicts = VerdictStore::load(&crate::config::runtime_home_dir());
                    let mut probed = 0usize;
                    let mut answered = 0usize;
                    let mut discovered = 0usize;
                    let mut failures = Vec::new();
                    for outcome in outcomes {
                        probed += outcome.probed;
                        answered += outcome.verdicts;
                        discovered += outcome.discovered.len();
                        if let Some(error) = outcome.error {
                            // Naming the provider matters: the usual cause is
                            // the proxy, and that is one setting away.
                            failures.push(format!("{}: {error}", outcome.id));
                        }
                    }
                    self.status_message = if !failures.is_empty() {
                        format!("Провайдеры обновлены частично — {}", failures.join("; "))
                    } else if answered == probed {
                        format!("Провайдеры обновлены: {discovered} моделей, проверено {probed}")
                    } else {
                        // Probed and answered differ exactly when a probe came
                        // back saying nothing (429, a timeout, a bad key), and
                        // that is the case worth seeing: nothing was learned and
                        // the models will be asked again next round.
                        format!(
                            "Провайдеры обновлены: {discovered} моделей, проверено {probed}, \
                             ответили {answered} — остальные спросим ещё раз"
                        )
                    };
                }
                AppMessage::UpdateChecked(status) => {
                    // A failed check keeps the previous button (if any) instead
                    // of replacing it with an error the user cannot act on.
                    if !matches!(status, UpdateStatus::Failed(_)) {
                        self.update_status = Some(status);
                    }
                }
                AppMessage::UpdateProgress(percent) => {
                    if matches!(self.update_job, Some(UpdateJobState::Downloading(_))) {
                        self.update_job = Some(UpdateJobState::Downloading(percent));
                    }
                }
                AppMessage::UpdateFinished(result) => match result {
                    Ok(()) => {
                        // The updater waits for this process to disappear, so
                        // quit through the normal path right away.
                        println!("Updater armed; shutting down for the install");
                        self.update_job = Some(UpdateJobState::Handoff);
                        self.begin_shutdown();
                    }
                    Err(reason) => {
                        eprintln!("Update failed: {reason}");
                        self.update_job = Some(UpdateJobState::Failed(reason));
                    }
                },
            }
        }

        // Test hook: press the update button as soon as a release is known.
        if self.selftest_update
            && self.update_job.is_none()
            && matches!(self.update_status, Some(UpdateStatus::Available { .. }))
        {
            println!("{SELFTEST_UPDATE_ENV}=1: starting the update automatically");
            self.start_update();
        }

        egui::CentralPanel::default().show(ctx, |ui| {
            // Header Bar
            let mut update_request = false;
            ui.horizontal(|ui| {
                // No title text here: the window caption already says
                // «Delegator vX.Y.Z» and the tray tooltip repeats it. A third
                // copy only cost vertical space and drifted out of date once.
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    let mut active = self.config.delegator_enabled;
                    let label = if active { "АКТИВЕН" } else { "ПАУЗА" };
                    if ui.toggle_value(&mut active, label).changed() {
                        self.config.delegator_enabled = active;
                        self.config.save();
                        set_toggle_label(active);
                        self.sync_all_ide_hooks();
                    }
                    // Right-to-left layout: added after the toggle, so it sits
                    // immediately to its LEFT. Only visible with a newer release.
                    if let Some(UpdateStatus::Available { tag, .. }) = &self.update_status {
                        update_request = self.update_button(ui, tag);
                    }
                });
            });
            if update_request {
                self.start_update();
            }

            ui.separator();

            // Navigation Tabs
            let api_warning = self.api_keys_need_attention();
            // A provider that reports a limit is exactly the state the tab
            // highlight exists for: nothing is broken, but delegation to that
            // side will not work until the quota resets.
            let gemini_warning =
                self.config.enabled_gemini_models.is_empty() || self.gemini_limit.is_some();
            let opencode_warning =
                self.opencode_models_need_attention() || self.opencode_limit.is_some();
            // A run is driven from the IDE chat and takes minutes; the pulse is
            // what tells the user it is still going while they are on any other
            // tab. Animated only while a window is actually on screen — in the
            // tray `update()` never runs at all (see gui::background).
            // A stalled run must not keep breathing: the pulse means "work is
            // happening", and nothing is happening any more.
            let benchmark_accent = if self
                .benchmark_status
                .as_ref()
                .is_some_and(|status| !status.stalled)
            {
                ctx.request_repaint_after(Duration::from_millis(40));
                TabAccent::Busy(pulse_alpha(ctx.input(|i| i.time), PULSE_PERIOD_SEC))
            } else {
                TabAccent::None
            };
            let accents = TabAccents {
                api: TabAccent::warn(api_warning || gemini_warning || opencode_warning),
                benchmark: benchmark_accent,
            };
            // Narrowing the window used to push the last tabs past the right
            // edge, where they were drawn but could not be clicked: eight tabs,
            // no scrollbar, no wrap, and no way back to «Прокси» except making
            // the window wider again. Wrapped, the row folds onto a second line
            // and every tab stays reachable at the 650 px minimum width.
            //
            // Except on the very first frame: a wrapped row reports the width it
            // was GIVEN, so the one-shot fit below would read "810" and grow the
            // window by the padding at every single launch. An unwrapped row
            // reports the width it WANTS, which is the number that fit needs.
            let tabs_row = if self.window_width_fitted {
                ui.horizontal_wrapped(|ui| {
                    navigation_tabs(ui, &mut self.active_tab, &self.theme, accents)
                })
            } else {
                ui.horizontal(|ui| {
                    navigation_tabs(ui, &mut self.active_tab, &self.theme, accents)
                })
            };

            // Fit the window width to the tab row once at startup so the row
            // starts on one line; later resizes stay under the user's control.
            if !self.window_width_fitted {
                let tabs_width = tabs_row.response.rect.width();
                if tabs_width > 0.0 {
                    self.window_width_fitted = true;
                    let required = tabs_width + 28.0;
                    let (current_width, current_height) =
                        ctx.input(|i| (i.screen_rect().width(), i.screen_rect().height()));
                    if required > current_width {
                        ctx.send_viewport_cmd(egui::ViewportCommand::InnerSize(egui::vec2(
                            required,
                            current_height,
                        )));
                    }
                }
            }

            ui.separator();

            // Tab Content
            match self.active_tab {
                SelectedTab::Ides => {
                    ui.label("Отметьте IDE, которые будут делегировать задачи Delegator.");
                    // On pause the hooks are removed, so an agent legitimately
                    // reports that it knows nothing about Delegator. Say so here
                    // instead of leaving the user to guess.
                    if !self.config.delegator_enabled {
                        ui.colored_label(
                            self.theme.warning_color(),
                            "Delegator на паузе — инструкции из IDE убраны. Включите «АКТИВЕН».",
                        );
                    }
                    ui.add_space(5.0);

                    let detected = IdeDetector::detect_all(&self.config.ide_states);

                    egui::ScrollArea::vertical().show(ui, |ui| {
                        if ui
                            .checkbox(
                                &mut self.config.gemini_web_enabled,
                                "Gemini Web (через Chrome)",
                            )
                            .on_hover_text(
                                "Запросы gemini-web/* идут через вашу сессию Gemini в Chrome. \
                                 Нужно расширение из папки extensions\\gemini-web-bridge \
                                 (один раз: chrome://extensions → Загрузить распакованное). \
                                 Окно Gemini расширение открывает и закрывает само.",
                            )
                            .changed()
                        {
                            self.config.save();
                        }
                        ui.add_space(5.0);
                        for ide in detected {
                            let mut is_enabled = self
                                .config
                                .ide_states
                                .get(&ide.name)
                                .copied()
                                .unwrap_or(false);

                            ui.horizontal(|ui| {
                                // Hooks are only written for installed IDEs, so a
                                // checkbox for an undetected one would do nothing.
                                let mut checkbox = ui.add_enabled(
                                    ide.is_detected,
                                    egui::Checkbox::new(
                                        &mut is_enabled,
                                        IdeDetector::display_name(&ide.name),
                                    ),
                                );
                                if !ide.is_detected {
                                    checkbox =
                                        checkbox.on_hover_text("IDE не найдена на этом компьютере");
                                } else if let Some(hint) = ide_row_hint(&ide.name) {
                                    checkbox = checkbox.on_hover_text(hint);
                                }
                                if ide.is_detected && checkbox.changed() {
                                    self.config.ide_states.insert(ide.name.clone(), is_enabled);
                                    self.config.save();
                                    let _ = IdeDetector::apply_hook(
                                        &ide.name,
                                        is_enabled && self.config.delegator_enabled,
                                    );
                                }

                                if ide.is_detected {
                                    ui.colored_label(self.theme.success_color(), "✔ Обнаружена");
                                } else {
                                    ui.colored_label(
                                        self.theme.weak_text_color(),
                                        "Не обнаружена",
                                    );
                                }

                                if ide.is_hooked && self.config.delegator_enabled {
                                    ui.colored_label(self.theme.accent_color(), "[Подключено]");
                                }
                            });
                        }
                    });
                }
                SelectedTab::Api => self.draw_api_tab(ui),
                SelectedTab::Stats => {
                    ui.horizontal(|ui| {
                        ui.label("Использование за последние 7 дней.");
                        if ui.button("Обновить").clicked() {
                            self.refresh_usage();
                        }
                        if self.is_loading_usage {
                            ui.spinner();
                        }
                    });

                    ui.separator();

                    if let Some(error) = &self.usage_error {
                        ui.colored_label(
                            self.theme.warning_color(),
                            "Нет связи с ядром Delegator — нажмите «Обновить».",
                        )
                        .on_hover_text(error.as_str());
                    }

                    egui::ScrollArea::vertical().show(ui, |ui| {
                        if let Some(report) = &self.usage_report {
                            ui.group(|ui| {
                                ui.strong("Сегодня");
                                ui.label(format!(
                                    "Запросов: {} | Токенов: {}",
                                    format_count(report.today.requests),
                                    format_count(report.today.total_tokens)
                                ));
                            });
                            ui.add_space(8.0);

                            ui.heading(
                                egui::RichText::new(format!(
                                    "Сэкономлено основной модели: {}",
                                    format_count(report.saved())
                                ))
                                .color(self.theme.success_color()),
                            )
                            .on_hover_text(
                                "Оценка: выходные токены, которые дорогой модели IDE \
                                 не пришлось генерировать — Делегатор отдал готовый \
                                 ответ. Бенчмарки в расчёт не входят.",
                            );
                            ui.label(format!(
                                "Делегирований: {} | обработано вместо неё: {} | потрачено Делегатором: {}",
                                format_count(report.delegations),
                                format_count(report.handled_tokens),
                                format_count(report.spent_tokens_total)
                            ))
                            .on_hover_text(
                                "«Потрачено Делегатором» — токены бесплатных моделей, \
                                 включая внутренние стадии и неудачные попытки.",
                            );
                            ui.add_space(12.0);

                            ui.strong("По моделям");
                            if report.by_model.is_empty() {
                                ui.colored_label(
                                    self.theme.weak_text_color(),
                                    "Пока нет данных по моделям.",
                                );
                            } else {
                                egui::Grid::new("usage_by_model_grid")
                                    .striped(true)
                                    .min_col_width(90.0)
                                    .show(ui, |ui| {
                                        ui.strong("Модель");
                                        ui.strong("Провайдер");
                                        ui.strong("Запросы");
                                        ui.strong("Токены");
                                        ui.end_row();
                                        for row in &report.by_model {
                                            ui.label(&row.model);
                                            ui.label(&row.provider);
                                            ui.label(format_count(row.requests));
                                            ui.label(format_count(row.total_tokens));
                                            ui.end_row();
                                        }
                                    });
                            }
                            ui.add_space(12.0);

                            ui.strong("По дням");
                            if report.daily.is_empty() {
                                ui.colored_label(
                                    self.theme.weak_text_color(),
                                    "Пока нет данных по дням.",
                                );
                            } else {
                                egui::Grid::new("usage_daily_grid")
                                    .striped(true)
                                    .min_col_width(90.0)
                                    .show(ui, |ui| {
                                        ui.strong("Дата");
                                        ui.strong("Запросы");
                                        ui.strong("Токены");
                                        ui.end_row();
                                        for day in &report.daily {
                                            ui.label(&day.date);
                                            ui.label(format_count(day.requests));
                                            ui.label(format_count(day.total_tokens));
                                            ui.end_row();
                                        }
                                    });
                            }
                        } else if self.is_loading_usage {
                            ui.label("Загрузка…");
                        } else if self.usage_error.is_none() {
                            ui.label("Нет данных. Нажмите «Обновить».");
                        }
                    });
                }
                SelectedTab::Thinking => {
                    ui.horizontal(|ui| {
                        ui.label("Живая карта работы Delegator: кто просит, что решил роутер, куда ушла задача.");
                    });
                    ui.colored_label(
                        self.theme.weak_text_color(),
                        "Прототип. Показываются только процессы — содержимого задач и ответов здесь нет и быть не может.",
                    );
                    ui.separator();
                    self.thinking.ui(ui, &self.theme);
                }
                SelectedTab::Benchmark => {
                    ui.horizontal(|ui| {
                        ui.label("Замер качества: ваша модель против неё же с Delegator.");
                        if ui.button("Обновить").clicked() {
                            self.refresh_benchmark();
                        }
                        if self.benchmark_loading {
                            ui.spinner();
                        }
                    });
                    ui.colored_label(
                        self.theme.weak_text_color(),
                        "Запуск — командой «-benchmark» в чате вашей IDE: только она может заставить отвечать вашу модель.",
                    )
                    .on_hover_text(
                        "12 случайных задач трёх уровней. Оценка механическая: код запускается, \
                         SQL сравнивается построчно. Ответы не оценивает ни одна модель.",
                    );
                    ui.separator();

                    // A run is in flight: show what it is doing right now. The
                    // last report stays visible underneath for comparison.
                    // The IDE chat died mid-run: say so instead of showing a
                    // progress bar that will never move again.
                    let mut cancel_request: Option<String> = None;
                    if let Some(status) = self.benchmark_status.clone().filter(|s| s.stalled) {
                        let warning = self.theme.warning_color();
                        let fill = egui::Color32::from_rgba_unmultiplied(
                            warning.r(),
                            warning.g(),
                            warning.b(),
                            28,
                        );
                        egui::Frame::none()
                            .fill(fill)
                            .stroke(egui::Stroke::new(1.5, warning))
                            .rounding(6.0)
                            .inner_margin(10.0)
                            .show(ui, |ui| {
                                ui.horizontal(|ui| {
                                    ui.strong("Прогон прерван");
                                    ui.colored_label(
                                        self.theme.weak_text_color(),
                                        format!(
                                            "решено задач: {} из {}",
                                            status.answered_model, status.tasks_total
                                        ),
                                    );
                                });
                                ui.colored_label(warning, status.stalled_line());
                                if ui.button("Прекратить прогон").clicked() {
                                    cancel_request = Some(status.run_id.clone());
                                }
                            });
                        ui.add_space(8.0);
                    }

                    if let Some(status) = self.benchmark_status.clone().filter(|s| !s.stalled) {
                        let status = &status;
                        let accent = self.theme.accent_color();
                        let fill = egui::Color32::from_rgba_unmultiplied(
                            accent.r(),
                            accent.g(),
                            accent.b(),
                            28,
                        );
                        egui::Frame::none()
                            .fill(fill)
                            .stroke(egui::Stroke::new(1.5, accent))
                            .rounding(6.0)
                            .inner_margin(10.0)
                            .show(ui, |ui| {
                                ui.horizontal(|ui| {
                                    ui.spinner();
                                    ui.strong("Бенчмарк идёт");
                                    ui.colored_label(
                                        self.theme.weak_text_color(),
                                        format!("модель: {}", status.model_label),
                                    );
                                });
                                ui.add(
                                    egui::ProgressBar::new(status.fraction())
                                        .desired_width(ui.available_width())
                                        .text(status.line()),
                                );
                                if !status.current_title.is_empty() {
                                    ui.colored_label(
                                        self.theme.weak_text_color(),
                                        format!("Сейчас: {}", status.current_title),
                                    );
                                }
                                // The chat can die without the core noticing for
                                // ten minutes (a rate limit, a closed session),
                                // and until then the tab kept saying «идёт» with
                                // no way out. Stopping it by hand is that way.
                                ui.horizontal(|ui| {
                                    ui.colored_label(
                                        self.theme.weak_text_color(),
                                        "Окно можно закрыть — прогон идёт в чате IDE.",
                                    );
                                    if ui
                                        .small_button("Прекратить")
                                        .on_hover_text(
                                            "Если чат IDE упал или вы остановили прогон вручную: \
                                             Delegator забудет его и перестанет ждать. Отчёта по \
                                             этому прогону не будет.",
                                        )
                                        .clicked()
                                    {
                                        cancel_request = Some(status.run_id.clone());
                                    }
                                });
                            });
                        ui.add_space(8.0);
                    }

                    if let Some(run_id) = cancel_request {
                        self.cancel_benchmark(run_id);
                    }

                    if let Some(error) = &self.benchmark_error {
                        ui.colored_label(
                            self.theme.warning_color(),
                            "Нет связи с ядром Delegator — нажмите «Обновить».",
                        )
                        .on_hover_text(error.as_str());
                    }

                    let mut export_request: Option<Vec<&'static str>> = None;
                    egui::ScrollArea::vertical().show(ui, |ui| {
                        let Some(report) = &self.benchmark_report else {
                            if !self.benchmark_loading
                                && self.benchmark_error.is_none()
                                && self.benchmark_status.is_none()
                            {
                                ui.label("Бенчмарк ещё не запускался.");
                            }
                            return;
                        };
                        let compare = report.is_compare();
                        ui.horizontal(|ui| {
                            ui.strong(format!("Модель: {}", report.model_label));
                            ui.colored_label(
                                self.theme.weak_text_color(),
                                format!(
                                    "Delegator v{} · набор задач v{} · seed {}",
                                    report.delegator_version, report.benchmark_version, report.seed
                                ),
                            );
                        });
                        ui.colored_label(self.theme.weak_text_color(), &report.finished_at);
                        ui.add_space(8.0);

                        let success = self.theme.success_color();
                        let error_color = self.theme.error_color();
                        let weak = self.theme.weak_text_color();
                        egui::Grid::new("benchmark_grid")
                            .striped(true)
                            .min_col_width(70.0)
                            .show(ui, |ui| {
                                ui.strong("#");
                                ui.strong("Задача");
                                ui.strong("Уровень");
                                ui.strong("Модель");
                                if compare {
                                    ui.strong("С Delegator");
                                    ui.strong("Кто лучше");
                                }
                                ui.end_row();

                                for task in &report.tasks {
                                    ui.label(task.index.to_string());
                                    ui.label(&task.title);
                                    ui.colored_label(weak, level_label(&task.level));

                                    let model_ok = task.model.as_ref().map(|arm| arm.passed).unwrap_or(false);
                                    let model_cell = ui.colored_label(
                                        if model_ok { success } else { error_color },
                                        task.model
                                            .as_ref()
                                            .map(|arm| arm.cell(task.points))
                                            .unwrap_or_else(|| format!("0/{}", task.points)),
                                    );
                                    // The tooltip names the constraints that failed:
                                    // «7 из 9» is only useful if you can see which two.
                                    if let Some(arm) = task.model.as_ref() {
                                        let hint = arm.failure_hint();
                                        if !hint.is_empty() {
                                            model_cell.on_hover_text(hint);
                                        }
                                    }

                                    if compare {
                                        let delegator_ok =
                                            task.delegator.as_ref().map(|arm| arm.passed).unwrap_or(false);
                                        let delegator_cell = ui.colored_label(
                                            if delegator_ok { success } else { error_color },
                                            task.delegator
                                                .as_ref()
                                                .map(|arm| arm.cell(task.points))
                                                .unwrap_or_else(|| format!("0/{}", task.points)),
                                        );
                                        if let Some(arm) = task.delegator.as_ref() {
                                            let hint = arm.failure_hint();
                                            if !hint.is_empty() {
                                                delegator_cell.on_hover_text(hint);
                                            }
                                        }
                                        // Highlight the winner of this task; a draw stays grey so
                                        // the eye lands only where the arms actually differ.
                                        match task.winner.as_str() {
                                            "delegator" => {
                                                highlight_label(ui, "Delegator", success);
                                            }
                                            "model" => {
                                                highlight_label(ui, "модель", error_color);
                                            }
                                            _ => {
                                                ui.colored_label(weak, "поровну");
                                            }
                                        }
                                    }
                                    ui.end_row();
                                }

                                ui.strong("");
                                ui.strong("Итого");
                                ui.label("");
                                let model_total = report.totals.model.unwrap_or(0.0);
                                let delegator_total = report.totals.delegator.unwrap_or(0.0);
                                let model_wins = !compare || model_total >= delegator_total;
                                ui.colored_label(
                                    if model_wins { success } else { weak },
                                    egui::RichText::new(format!(
                                        "{}/{}",
                                        format_points(model_total),
                                        report.max_points
                                    ))
                                    .strong(),
                                );
                                if compare {
                                    ui.colored_label(
                                        if delegator_total >= model_total { success } else { weak },
                                        egui::RichText::new(format!(
                                            "{}/{}",
                                            format_points(delegator_total),
                                            report.max_points
                                        ))
                                        .strong(),
                                    );
                                    if let Some(counts) = &report.counts {
                                        ui.colored_label(
                                            weak,
                                            format!(
                                                "+{} / −{}",
                                                counts.better, counts.worse
                                            ),
                                        );
                                    } else {
                                        ui.label("");
                                    }
                                }
                                ui.end_row();
                            });

                        // Two sentences that used to be invisible: what
                        // Delegator scores WITHOUT the model's answer to lean
                        // on, and how many of the twelve tasks were a real
                        // comparison at all.
                        if let Some(alone) = report.totals.alone {
                            ui.add_space(6.0);
                            ui.label(
                                egui::RichText::new(format!(
                                    "Delegator сам, без вашего ответа: {}/{}",
                                    format_points(alone),
                                    report.max_points
                                ))
                                .strong(),
                            )
                            .on_hover_text(
                                "Единственное плечо, которое проверяет саму идею: модели \
                                 Delegator решают ту же задачу с нуля. Проверка вашего ответа \
                                 не может поднять балл, если ответ уже верный.",
                            );
                        }
                        if let Some(comparability) = &report.comparability {
                            if comparability.pairs > 0 {
                                ui.colored_label(weak, comparability.line());
                            }
                        }

                        // Where the lead or the lag is. A single total answers
                        // «помог ли Delegator» and never answers «на чём».
                        if let Some(profile) = &report.profile {
                            let rows = profile.rows();
                            if !rows.is_empty() {
                                ui.add_space(10.0);
                                ui.strong("Где сильнее и где слабее");
                                egui::Grid::new("benchmark_profile")
                                    .striped(true)
                                    .min_col_width(70.0)
                                    .show(ui, |ui| {
                                        ui.strong("");
                                        ui.strong("Задач");
                                        ui.strong("Модель");
                                        if compare {
                                            ui.strong("С Delegator");
                                        }
                                        ui.end_row();
                                        for group in rows {
                                            ui.label(&group.label);
                                            ui.colored_label(weak, group.tasks.to_string());
                                            ui.label(format!(
                                                "{}/{}",
                                                format_points(group.model),
                                                group.max_points
                                            ));
                                            if compare {
                                                let delegator = group.delegator.unwrap_or(0.0);
                                                ui.colored_label(
                                                    if delegator > group.model {
                                                        success
                                                    } else if delegator < group.model {
                                                        error_color
                                                    } else {
                                                        weak
                                                    },
                                                    format!(
                                                        "{}/{}",
                                                        format_points(delegator),
                                                        group.max_points
                                                    ),
                                                );
                                            }
                                            ui.end_row();
                                        }
                                    });
                            }
                        }

                        ui.add_space(10.0);
                        ui.label(&report.verdict);
                        // «Не доказано» on its own reads as a failure of
                        // Delegator; usually it is a failure of the sample size,
                        // and the report has to say which.
                        if let Some(stats) = &report.stats {
                            if !stats.text.is_empty() {
                                ui.colored_label(weak, &stats.text).on_hover_text(
                                    "Точный тест Макнемара по задачам, где стороны разошлись \
                                     полностью. Статистики нет без расхождений — это про размер \
                                     выборки, а не про качество.",
                                );
                            }
                        }
                        ui.add_space(10.0);

                        ui.horizontal(|ui| {
                            if ui
                                .add_enabled(
                                    !self.benchmark_exporting,
                                    egui::Button::new("Сохранить текстом"),
                                )
                                .on_hover_text("Файл .txt на рабочий стол")
                                .clicked()
                            {
                                export_request = Some(vec!["txt"]);
                            }
                            if ui
                                .add_enabled(
                                    !self.benchmark_exporting,
                                    egui::Button::new("Сохранить картинкой"),
                                )
                                .on_hover_text(
                                    "Файл .png на рабочий стол — можно отправить в чат как обычную картинку",
                                )
                                .clicked()
                            {
                                export_request = Some(vec!["png"]);
                            }
                            if self.benchmark_exporting {
                                ui.spinner();
                            }
                        });
                        match &self.benchmark_export {
                            Some(Ok(paths)) => {
                                for path in paths {
                                    ui.colored_label(success, format!("Сохранено: {path}"));
                                }
                            }
                            Some(Err(error)) => {
                                ui.colored_label(
                                    self.theme.warning_color(),
                                    format!("Не удалось сохранить: {error}"),
                                );
                            }
                            None => {}
                        }
                    });

                    if let Some(formats) = export_request {
                        self.start_benchmark_export(formats);
                    }
                }
                SelectedTab::Proxies => {
                    ui.label("Прокси для запросов к моделям: http://, https://, socks5://.")
                        .on_hover_text(
                            "Отметьте, какие бэкенды используют прокси; при нескольких \
                             подходящих берётся первый включённый сверху. Переменная \
                             окружения DELEGATOR_PROXY имеет приоритет.",
                        );
                    ui.add_space(4.0);
                    ui.label(self.proxy_status_line("gemini", "Gemini"));
                    ui.label(self.proxy_status_line("opencode", "OpenCode"));
                    ui.separator();

                    let mut changed = false;
                    let mut remove_id: Option<String> = None;
                    let mut test_request: Option<(String, String, bool)> = None;

                    egui::ScrollArea::vertical().show(ui, |ui| {
                        for proxy in &mut self.config.proxies {
                            ui.group(|ui| {
                                if ui.checkbox(&mut proxy.enabled, "Включён").changed() {
                                    changed = true;
                                }
                                ui.label("Название:");
                                if ui
                                    .add(
                                        egui::TextEdit::singleline(&mut proxy.label)
                                            .desired_width(ui.available_width()),
                                    )
                                    .changed()
                                {
                                    changed = true;
                                }
                                ui.label("URL:");
                                if ui
                                    .add(
                                        egui::TextEdit::singleline(&mut proxy.url)
                                            .hint_text("http://host:port или socks5://host:port")
                                            .desired_width(ui.available_width()),
                                    )
                                    .changed()
                                {
                                    changed = true;
                                }
                                let url_ok = is_supported_proxy_url(&proxy.url);
                                if !proxy.url.trim().is_empty() && !url_ok {
                                    ui.colored_label(
                                        self.theme.warning_color(),
                                        "Нужен http://, https://, socks5:// или socks5h://",
                                    );
                                }
                                ui.horizontal(|ui| {
                                    ui.label("Использовать для:");
                                    if ui.checkbox(&mut proxy.use_for_gemini, "Gemini").changed() {
                                        changed = true;
                                    }
                                    if ui
                                        .checkbox(&mut proxy.use_for_opencode, "OpenCode")
                                        .changed()
                                    {
                                        changed = true;
                                    }
                                });
                                ui.horizontal(|ui| {
                                    let testing = matches!(
                                        self.proxy_tests.get(&proxy.id),
                                        Some(ProxyTestState::Running)
                                    );
                                    if ui
                                        .add_enabled(
                                            url_ok && !testing,
                                            egui::Button::new("Проверить"),
                                        )
                                        .clicked()
                                    {
                                        test_request = Some((
                                            proxy.id.clone(),
                                            proxy.url.trim().to_string(),
                                            proxy.use_for_gemini,
                                        ));
                                    }
                                    if testing {
                                        ui.spinner();
                                    }
                                    if ui
                                        .button(
                                            egui::RichText::new("Удалить")
                                                .color(self.theme.error_color()),
                                        )
                                        .clicked()
                                    {
                                        remove_id = Some(proxy.id.clone());
                                    }
                                });
                                if let Some(ProxyTestState::Done(result)) =
                                    self.proxy_tests.get(&proxy.id)
                                {
                                    match &result.general {
                                        Ok(code) => {
                                            ui.colored_label(
                                                self.theme.success_color(),
                                                format!("ОК (HTTP {code})"),
                                            );
                                        }
                                        Err(message) => {
                                            ui.colored_label(
                                                self.theme.warning_color(),
                                                format!("Ошибка: {message}"),
                                            );
                                        }
                                    }
                                    match &result.google {
                                        Some(GoogleProbe::HttpAnswer(code)) => {
                                            ui.colored_label(
                                                self.theme.success_color(),
                                                format!("Google: ОК (HTTP {code})"),
                                            );
                                        }
                                        Some(GoogleProbe::GeoBlocked(code)) => {
                                            ui.colored_label(
                                                self.theme.warning_color(),
                                                format!(
                                                    "Google: регион не поддерживается (HTTP {code})"
                                                ),
                                            );
                                        }
                                        Some(GoogleProbe::Failed(message)) => {
                                            ui.colored_label(
                                                self.theme.warning_color(),
                                                format!("Google: ошибка — {message}"),
                                            );
                                        }
                                        None => {}
                                    }
                                }
                            });
                            ui.add_space(6.0);
                        }

                        if self.config.proxies.is_empty() {
                            ui.colored_label(
                                self.theme.weak_text_color(),
                                "Прокси не настроены — все запросы идут напрямую.",
                            );
                            ui.add_space(6.0);
                        }

                        if ui.button("Добавить прокси").clicked() {
                            self.config.add_empty_proxy();
                        }
                    });

                    if changed {
                        self.config.save();
                    }
                    if let Some(id) = remove_id {
                        self.config.remove_proxy(&id);
                        self.proxy_tests.remove(&id);
                    }
                    if let Some((id, url, test_google)) = test_request {
                        self.start_proxy_test(id, url, test_google);
                    }
                }
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Lays the navigation row out in a window `width` px wide and returns the
    /// rect it occupied. No `theme::apply` — that installs a font from the
    /// user's machine; the default face is enough to compare two layouts.
    fn tabs_rect(width: f32, wrapped: bool) -> egui::Rect {
        let ctx = egui::Context::default();
        let input = egui::RawInput {
            screen_rect: Some(egui::Rect::from_min_size(
                egui::pos2(0.0, 0.0),
                egui::vec2(width, 420.0),
            )),
            ..Default::default()
        };
        let theme = ThemeConfig::load();
        let accents = TabAccents {
            api: TabAccent::None,
            benchmark: TabAccent::None,
        };
        let mut active = SelectedTab::Ides;
        let mut rect = egui::Rect::NOTHING;
        ctx.run(input, |ctx| {
            egui::CentralPanel::default().show(ctx, |ui| {
                let row = if wrapped {
                    ui.horizontal_wrapped(|ui| navigation_tabs(ui, &mut active, &theme, accents))
                } else {
                    ui.horizontal(|ui| navigation_tabs(ui, &mut active, &theme, accents))
                };
                rect = row.response.rect;
            });
        });
        rect
    }

    /// The «API» tab has never been on screen and cannot be (D7), so what it
    /// OFFERS is asserted here instead: which providers get a button, what each
    /// is called, and which of them is asking for attention.
    #[test]
    fn the_api_tab_offers_both_builtins_plus_every_added_provider() {
        use crate::config::tests_support::{account, provider};
        use crate::config::{GoogleApiAccount, OpenCodeApiAccount};

        let mut config = AppConfig::default();

        // Empty config: the two built-ins are still there — they own storage of
        // their own and cannot be removed — and both want attention, because
        // neither has a key.
        let rows = api_provider_rows(&config);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].0, ApiProvider::Google);
        assert_eq!(rows[0].1, "Google AI Studio");
        assert!(rows[0].2, "no Google key must show as needing attention");
        assert_eq!(rows[1].0, ApiProvider::OpenCode);
        assert!(rows[1].2);

        config.google_accounts.push(GoogleApiAccount {
            id: "g1".into(),
            label: "Main".into(),
            api_key_enc: "blob".into(),
            enabled: true,
        });
        // A key that exists but is switched OFF is not a key: the runtime skips
        // disabled accounts, so the row must keep asking.
        config.opencode_accounts.push(OpenCodeApiAccount {
            id: "o1".into(),
            label: "OR".into(),
            api_key_enc: "blob".into(),
            enabled: false,
        });
        let rows = api_provider_rows(&config);
        assert!(!rows[0].2, "an enabled Google key clears the warning");
        assert!(rows[1].2, "a disabled key must still warn");

        // Added providers follow, in config order, keyed by id.
        let mut with_key = provider("bai", "B.AI");
        with_key.accounts.push(account("a1", true));
        let unlabelled = provider("tokenrouter", "");
        config.custom_providers = vec![with_key, unlabelled];

        let rows = api_provider_rows(&config);
        assert_eq!(rows.len(), 4);
        assert_eq!(rows[2].0, ApiProvider::Custom("bai".to_string()));
        assert_eq!(rows[2].1, "B.AI");
        assert!(!rows[2].2);
        // No label falls back to the id, so a row can never be a blank button.
        assert_eq!(rows[3].1, "tokenrouter");
        assert!(rows[3].2, "a provider with no key must ask for one");
    }

    /// Tabs used to be drawn past the right edge — visible in no way, clickable
    /// in no way, and the only route back to «Прокси» was widening the window
    /// again (G96).
    ///
    /// The width that provoked it was `min_inner_size` itself, back when eight
    /// tabs had to fit there. Folding «API-ключи», «Модели Gemini» and «Модели
    /// OpenCode» into one «API» tab left six, and six fit — so the overflow now
    /// has to be provoked at a width the user cannot even drag to. The
    /// behaviour under test is unchanged; only the width that triggers it is.
    #[test]
    fn narrowing_the_window_wraps_the_tabs_instead_of_putting_them_out_of_reach() {
        // Narrower than `min_inner_size`, purely to force the wrap.
        const NARROW: f32 = 300.0;

        let flat = tabs_rect(NARROW, false);
        assert!(
            flat.width() > NARROW,
            "the row must genuinely overflow at this width, or the test proves nothing: {}",
            flat.width()
        );

        let wrapped = tabs_rect(NARROW, true);
        assert!(
            wrapped.width() <= NARROW,
            "a wrapped row must stay inside the window: {} > {NARROW}",
            wrapped.width()
        );
        assert!(
            wrapped.height() > flat.height(),
            "not fitting on one line has to cost a second line, not a tab"
        );
        // And this is why the one-shot window fit measures the UNWRAPPED row:
        // once wrapped, the row can no longer say how wide it wanted to be.
        assert!(
            flat.width() > wrapped.width(),
            "only the unwrapped row reports the width the fit needs: {} vs {}",
            flat.width(),
            wrapped.width()
        );
    }

    /// What the «API» tab bought: at the narrowest the user can actually make
    /// the window, the row fits on one line. This is the assertion that fails
    /// first if the row grows back to eight tabs.
    #[test]
    fn the_tab_row_fits_on_one_line_at_the_minimum_window_width() {
        const MIN_INNER_WIDTH: f32 = 650.0;

        let flat = tabs_rect(MIN_INNER_WIDTH, false);
        assert!(
            flat.width() <= MIN_INNER_WIDTH,
            "the tab row no longer fits at the minimum width ({} > {MIN_INNER_WIDTH}); \
             it still wraps rather than overflowing, but a second line is back",
            flat.width()
        );
    }
}
