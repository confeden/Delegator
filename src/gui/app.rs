use crate::config::{is_supported_proxy_url, unix_now, AppConfig};
use crate::dependency_service::DependencyStatus;
use crate::gui::opencode_setup::{
    install_dependencies, install_plan, load_zen_strengths, open_url, order_opencode_models,
    upgrade_opencode_cli, CliJob, CliJobResult, InstallStep, NODEJS_DOWNLOAD_URL,
    NO_INSTALLER_FOUND, OPENCODE_SITE_URL,
};
use crate::gui::proxy::{run_proxy_test, GoogleProbe, ProxyTestResult};
use crate::gui::updater::{progress_label, run_update, update_button_label};
use crate::gui::usage::{fetch_usage, format_count, UsageReport};
use crate::ide_detector::IdeDetector;
use crate::models_service::{
    fetch_gemini_models, fetch_opencode_models, ModelInfo, OpenCodeCatalog,
};
use crate::runtime_service::RuntimeService;
use crate::update_check::{self, UpdateStatus};
use eframe::egui;
use std::collections::HashMap;
use std::sync::mpsc::{channel, Receiver, Sender};
use std::time::Duration;

use crate::theme::ThemeConfig;
use crate::tray_service::{attach_ui_context, mark_quit_handled, TrayAction};

/// Header title, derived from the crate version at compile time. It must be
/// the FULL version: the window title and the tray tooltip use the same
/// `CARGO_PKG_VERSION`, and a shortened header read as a second, older version.
const APP_TITLE: &str = concat!("Delegator v", env!("CARGO_PKG_VERSION"));

/// Test hook: with `DELEGATOR_SELFTEST_UPDATE=1` the app presses its own
/// «Обновить до …» button as soon as a newer release is known, so the whole
/// download → install → restart chain can be exercised end to end (usually
/// together with `DELEGATOR_UPDATE_API_URL`, see `crate::update_check`).
const SELFTEST_UPDATE_ENV: &str = "DELEGATOR_SELFTEST_UPDATE";

pub enum AppMessage {
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
    ApiKeys,
    GeminiModels,
    OpenCodeModels,
    Stats,
    Proxies,
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
    status_message: String,

    // Models Lists
    gemini_models: Vec<ModelInfo>,
    opencode_models: Vec<ModelInfo>,
    gemini_search: String,
    opencode_search: String,
    /// Zen strength scores from `<RT>\opencode-zen-catalog.json`; drives the
    /// "strongest first" order of the `opencode/*` block in the tab.
    zen_strengths: HashMap<String, i32>,

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

    /// Newest GitHub release seen by the 8-hourly check (button source).
    update_status: Option<UpdateStatus>,
    update_check_running: bool,
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
    runtime: Option<RuntimeService>,
}

impl DelegatorApp {
    pub fn new(
        cc: &eframe::CreationContext<'_>,
        tray_rx: Receiver<TrayAction>,
        runtime: Option<RuntimeService>,
        runtime_status: String,
        theme: ThemeConfig,
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
            status_message: runtime_status,
            gemini_models: Vec::new(),
            opencode_models: Vec::new(),
            gemini_search: String::new(),
            opencode_search: String::new(),
            zen_strengths: load_zen_strengths(),
            opencode_install: None,
            opencode_upgrade: None,
            usage_report: None,
            usage_error: None,
            is_loading_usage: false,
            stats_tab_was_active: false,
            window_width_fitted: false,
            proxy_tests: HashMap::new(),
            update_status: update_check::cached_status(),
            update_check_running: false,
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
            runtime,
        };

        // Let tray callbacks wake this context; otherwise their messages sit
        // unread while the window is hidden in the tray.
        attach_ui_context(cc.egui_ctx.clone());

        // Sync initial IDE hooks on startup
        app.sync_all_ide_hooks();
        // Trigger initial background model fetch
        app.refresh_models();
        // Keep the CLI (and therefore the free-model lineup) current.
        app.maybe_start_background_upgrade();
        // Ask GitHub whether a newer release exists (throttled to 8h).
        app.maybe_check_for_updates();

        app
    }

    fn sync_all_ide_hooks(&mut self) {
        let states = self.config.ide_states.clone();
        for (name, enabled) in states {
            let _ = IdeDetector::apply_hook(&name, enabled && self.config.delegator_enabled);
        }
        IdeDetector::migrate_legacy_installation(self.config.delegator_enabled);
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

    /// Ask GitHub for the latest release tag, at most once per 8 hours.
    /// Failures stay silent: a missing network must not nag the user.
    fn maybe_check_for_updates(&mut self) {
        if self.update_check_running || !update_check::is_check_due() {
            return;
        }
        self.update_check_running = true;
        let tx = self.tx.clone();
        let ctx = self.egui_ctx.clone();
        tokio::spawn(async move {
            let status = update_check::fetch_latest_release().await;
            let _ = tx.send(AppMessage::UpdateChecked(status));
            ctx.request_repaint();
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

    fn opencode_models_need_attention(&self) -> bool {
        self.config.enabled_opencode_models.is_empty()
            || (self
                .config
                .enabled_opencode_models
                .iter()
                .any(|model| model.starts_with("opencode/"))
                && !self.dependencies.opencode_cli_available())
    }
}

fn tab_button(
    ui: &mut egui::Ui,
    selected: &mut SelectedTab,
    value: SelectedTab,
    label: &str,
    warning: bool,
    theme: &ThemeConfig,
) {
    if warning {
        let color = theme.warning_color();
        let fill = egui::Color32::from_rgba_unmultiplied(color.r(), color.g(), color.b(), 35);
        egui::Frame::none()
            .fill(fill)
            .stroke(egui::Stroke::new(1.5, color))
            .rounding(5.0)
            .inner_margin(egui::Margin::symmetric(4.0, 2.0))
            .show(ui, |ui| {
                ui.selectable_value(selected, value, egui::RichText::new(label).color(color));
            });
    } else {
        ui.selectable_value(selected, value, label);
    }
}

impl eframe::App for DelegatorApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        if !self.window_theme_applied {
            ctx.send_viewport_cmd(egui::ViewportCommand::SetTheme(egui::SystemTheme::Dark));
            self.window_theme_applied = true;
        }

        while let Ok(action) = self.tray_rx.try_recv() {
            match action {
                TrayAction::Open => {
                    ctx.send_viewport_cmd(egui::ViewportCommand::Visible(true));
                    ctx.send_viewport_cmd(egui::ViewportCommand::Focus);
                }
                TrayAction::Toggle => {
                    self.config.delegator_enabled = !self.config.delegator_enabled;
                    self.config.save();
                    self.sync_all_ide_hooks();
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

        if ctx.input(|input| input.viewport().close_requested()) && !self.quitting {
            ctx.send_viewport_cmd(egui::ViewportCommand::CancelClose);
            ctx.send_viewport_cmd(egui::ViewportCommand::Visible(false));
        }
        ctx.request_repaint_after(Duration::from_millis(250));

        // Supervise the core: respawn it if it exited (e.g. POST /api/restart
        // under DELEGATOR_SUPERVISED=1) or stopped answering health checks.
        // Skipped while quitting so shutdown cannot resurrect the core.
        if let Some(runtime) = self.runtime.as_mut().filter(|_| !self.quitting) {
            if let Some(status) = runtime.ensure_running() {
                self.status_message = status;
            }
        }

        // Auto-fetch usage aggregates whenever the «Статистика» tab is opened.
        let stats_tab_active = self.active_tab == SelectedTab::Stats;
        if stats_tab_active && !self.stats_tab_was_active {
            self.refresh_usage();
        }
        self.stats_tab_was_active = stats_tab_active;

        // Handle async responses
        while let Ok(msg) = self.rx.try_recv() {
            match msg {
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
                            self.opencode_models =
                                order_opencode_models(catalog.models, &self.zen_strengths);
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
                AppMessage::UpdateChecked(status) => {
                    self.update_check_running = false;
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

        // The 8-hour window can elapse while the app stays open.
        self.maybe_check_for_updates();

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
                ui.heading(APP_TITLE);
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    let mut active = self.config.delegator_enabled;
                    let label = if active { "АКТИВЕН" } else { "ПАУЗА" };
                    if ui.toggle_value(&mut active, label).changed() {
                        self.config.delegator_enabled = active;
                        self.config.save();
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
            let gemini_warning = self.config.enabled_gemini_models.is_empty();
            let opencode_warning = self.opencode_models_need_attention();
            let tabs_row = ui.horizontal(|ui| {
                tab_button(
                    ui,
                    &mut self.active_tab,
                    SelectedTab::Ides,
                    "IDE и интеграции",
                    false,
                    &self.theme,
                );
                tab_button(
                    ui,
                    &mut self.active_tab,
                    SelectedTab::ApiKeys,
                    "API-ключи",
                    api_warning,
                    &self.theme,
                );
                tab_button(
                    ui,
                    &mut self.active_tab,
                    SelectedTab::GeminiModels,
                    "Модели Gemini",
                    gemini_warning,
                    &self.theme,
                );
                tab_button(
                    ui,
                    &mut self.active_tab,
                    SelectedTab::OpenCodeModels,
                    "Модели OpenCode",
                    opencode_warning,
                    &self.theme,
                );
                tab_button(
                    ui,
                    &mut self.active_tab,
                    SelectedTab::Stats,
                    "Статистика",
                    false,
                    &self.theme,
                );
                tab_button(
                    ui,
                    &mut self.active_tab,
                    SelectedTab::Proxies,
                    "Прокси",
                    false,
                    &self.theme,
                );
            });

            // Fit the window width to the tab row once at startup so no tab is ever
            // clipped; later resizes stay under the user's control.
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
                    ui.add_space(5.0);

                    let detected = IdeDetector::detect_all(&self.config.ide_states);

                    egui::ScrollArea::vertical().show(ui, |ui| {
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
                                let checkbox = ui.add_enabled(
                                    ide.is_detected,
                                    egui::Checkbox::new(&mut is_enabled, &ide.name),
                                );
                                if !ide.is_detected {
                                    checkbox.on_hover_text("IDE не найдена на этом компьютере");
                                } else if checkbox.changed() {
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
                SelectedTab::ApiKeys => {
                    egui::ScrollArea::vertical()
                        .show(ui, |ui| {
                            ui.heading("API-ключи Delegator");
                            ui.label("Ключи хранятся только здесь и шифруются Windows DPAPI.")
                                .on_hover_text(
                                    "Системные GEMINI_API_KEY и GOOGLE_API_KEY не читаются.",
                                );
                            ui.add_space(12.0);

                            ui.heading("Google AI Studio");
                            ui.label("Ключи нескольких аккаунтов переключаются автоматически при исчерпании квоты.");
                            if !self.config.google_accounts.iter().any(|account| account.enabled) {
                                ui.colored_label(
                                    self.theme.warning_color(),
                                    "Нет включённого Google-ключа.",
                                );
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
                                            .button(egui::RichText::new("Удалить ключ").color(self.theme.error_color()))
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
                                match self.config.update_google_account(
                                    &id,
                                    &label,
                                    new_key,
                                    enabled,
                                ) {
                                    Ok(()) => {
                                        if let Some(draft) = self
                                            .google_account_drafts
                                            .iter_mut()
                                            .find(|draft| draft.id == id)
                                        {
                                            draft.new_key.clear();
                                        }
                                        self.status_message =
                                            "Google-аккаунт сохранён".to_string();
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
                                    match self.config.add_google_account(
                                        &self.new_google_label,
                                        &self.new_google_key,
                                    ) {
                                        Ok(()) => {
                                            if let Some(account) = self.config.google_accounts.last()
                                            {
                                                self.google_account_drafts.push(ApiAccountDraft {
                                                    id: account.id.clone(),
                                                    label: account.label.clone(),
                                                    new_key: String::new(),
                                                    enabled: account.enabled,
                                                });
                                            }
                                            self.new_google_label.clear();
                                            self.new_google_key.clear();
                                            self.status_message =
                                                "Google-ключ добавлен".to_string();
                                        }
                                        Err(err) => self.status_message = err,
                                    }
                                }
                            });

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

                            ui.add_space(14.0);
                            if ui.button("Обновить списки моделей").clicked() {
                                self.refresh_models();
                            }
                            ui.colored_label(
                                self.theme.weak_text_color(),
                                self.status_message.as_str(),
                            );
                        });
                }
                SelectedTab::GeminiModels => {
                    ui.label("Delegator использует только отмеченные модели Google.");
                    ui.horizontal(|ui| {
                        ui.label("Поиск:");
                        ui.text_edit_singleline(&mut self.gemini_search);
                        if self.is_loading_gemini {
                            ui.spinner();
                        }
                    });

                    ui.separator();

                    egui::ScrollArea::vertical().show(ui, |ui| {
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
                                ui.colored_label(
                                    self.theme.weak_text_color(),
                                    format!("({})", model.id),
                                );
                            });
                        }
                    });
                }
                SelectedTab::OpenCodeModels => {
                    ui.label("Список берётся из OpenCode CLI: новые бесплатные модели включаются сами, сильные — сверху.");
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
                        let fill = egui::Color32::from_rgba_unmultiplied(
                            warning.r(),
                            warning.g(),
                            warning.b(),
                            28,
                        );
                        let installing =
                            matches!(self.opencode_install, Some(InstallState::Running(_)));
                        // Without either installer nothing can be automated —
                        // the manual links are then the only way forward.
                        let can_install = self.dependencies.winget_available()
                            || self.dependencies.npm_available();
                        let failed =
                            matches!(self.opencode_install, Some(InstallState::Done(Err(_))));
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
                                        .add_enabled(
                                            !installing,
                                            egui::Button::new("Проверить снова"),
                                        )
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
                        let upgrading =
                            matches!(self.opencode_upgrade, Some(CliJobState::Running));
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
                        ui.colored_label(
                            self.theme.warning_color(),
                            "Не выбрана ни одна модель.",
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

                    egui::ScrollArea::vertical().show(ui, |ui| {
                        for model in &self.opencode_models {
                            if !self.opencode_search.is_empty()
                                && !model
                                    .id
                                    .to_lowercase()
                                    .contains(&self.opencode_search.to_lowercase())
                            {
                                continue;
                            }

                            let mut checked =
                                self.config.enabled_opencode_models.contains(&model.id);
                            ui.horizontal(|ui| {
                                if ui.checkbox(&mut checked, &model.name).changed() {
                                    if checked {
                                        self.config.enabled_opencode_models.push(model.id.clone());
                                    } else {
                                        self.config
                                            .enabled_opencode_models
                                            .retain(|id| id != &model.id);
                                    }
                                    self.config.save();
                                }

                                if model.is_free {
                                    ui.colored_label(self.theme.success_color(), "[FREE]");
                                }
                                ui.colored_label(
                                    self.theme.weak_text_color(),
                                    format!("({})", model.id),
                                );
                            });
                        }
                    });
                }
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
                                    "Сэкономлено токенов (делегировано): {}",
                                    format_count(report.saved_tokens_total)
                                ))
                                .color(self.theme.success_color()),
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
