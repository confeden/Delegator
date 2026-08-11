#![cfg_attr(target_os = "windows", windows_subsystem = "windows")]

mod config;
mod crypto;
mod dependency_service;
mod gui;
mod ide_detector;
mod models_service;
mod runtime_service;
mod theme;
mod tray_service;
mod update_check;

use eframe::egui;
use gui::DelegatorApp;
use runtime_service::RuntimeService;
use tray_service::TrayManager;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    if std::env::args().any(|arg| arg.eq_ignore_ascii_case("--remove-hooks")) {
        ide_detector::IdeDetector::remove_all_hooks();
        ide_detector::IdeDetector::remove_legacy_shims();
        return Ok(());
    }
    let start_in_background = std::env::args().any(|arg| {
        arg.eq_ignore_ascii_case("--background") || arg.eq_ignore_ascii_case("--minimized")
    });
    let runtime_result = RuntimeService::start().await;
    let runtime_status = match &runtime_result {
        Ok(_) => "Delegator Core is ready".to_string(),
        Err(error) => format!("Core error: {error}"),
    };
    // Handed to the GUI so its update loop can supervise (and respawn) the core.
    let runtime = runtime_result.ok();
    let (tray, tray_rx) = TrayManager::setup()?;
    let _tray = tray;
    let window_icon =
        eframe::icon_data::from_png_bytes(include_bytes!("../assets/delegator-logo.png"))?;

    let native_options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title(concat!("Delegator v", env!("CARGO_PKG_VERSION")))
            .with_icon(window_icon)
            .with_inner_size([810.0, 555.0])
            .with_min_inner_size([650.0, 420.0])
            .with_visible(!start_in_background),
        ..Default::default()
    };

    eframe::run_native(
        concat!("Delegator v", env!("CARGO_PKG_VERSION")),
        native_options,
        Box::new(move |cc| {
            let theme = theme::apply(&cc.egui_ctx);
            Ok(Box::new(DelegatorApp::new(
                cc,
                tray_rx,
                runtime,
                runtime_status,
                theme,
            )))
        }),
    )
    .map_err(|e| format!("Eframe runtime error: {}", e))?;

    Ok(())
}
