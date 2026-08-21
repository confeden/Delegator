#![cfg_attr(target_os = "windows", windows_subsystem = "windows")]

mod config;
mod crypto;
mod dependency_service;
mod gui;
mod ide_detector;
mod models_service;
mod runtime_service;
mod single_instance;
mod theme;
mod tray_service;
mod update_check;

use eframe::egui;
use gui::DelegatorApp;
use runtime_service::RuntimeService;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tray_service::TrayManager;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    if std::env::args().any(|arg| arg.eq_ignore_ascii_case("--remove-hooks")) {
        ide_detector::IdeDetector::remove_all_hooks();
        ide_detector::IdeDetector::remove_legacy_shims();
        return Ok(());
    }
    // BEFORE the core is touched. Two supervisors on :1380 spend their time
    // respawning what the other one tree-kills, and both would rewrite
    // config.json behind each other's back. Autostart plus a manual launch is
    // the ordinary way this happens, so the second copy just surfaces the first
    // one's window and leaves.
    if single_instance::acquire() == single_instance::InstanceLock::AlreadyRunning {
        single_instance::raise_running_instance();
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
    // Test hook: verify the tray «Открыть» path without clicking the menu.
    if let Ok(delay) = std::env::var("DELEGATOR_SELFTEST_OPEN_SECS") {
        if let Ok(secs) = delay.trim().parse::<u64>() {
            std::thread::spawn(move || {
                std::thread::sleep(std::time::Duration::from_secs(secs));
                tray_service::request_open_for_test();
            });
        }
    }
    // Test hook: measure shutdown latency without driving the tray menu.
    if let Ok(delay) = std::env::var("DELEGATOR_SELFTEST_QUIT_SECS") {
        if let Ok(secs) = delay.trim().parse::<u64>() {
            std::thread::spawn(move || {
                std::thread::sleep(std::time::Duration::from_secs(secs));
                tray_service::request_quit_for_test();
            });
        }
    }
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
                start_in_background,
            )))
        }),
    )
    .map_err(|e| format!("Eframe runtime error: {}", e))?;

    // The window is gone but shutdown still takes a moment (killing the core
    // tree). Pulse the tray icon meanwhile so quitting never looks like a hang,
    // and run the actual teardown on a worker thread — the tray icon may only
    // be touched from the thread that created it.
    let cleanup_done = Arc::new(AtomicBool::new(false));
    let worker_flag = cleanup_done.clone();
    let cleanup = std::thread::spawn(move || {
        // The supervisor lives on its own thread now: tell it to stop and let
        // it release the core first, otherwise it can respawn one right after
        // the taskkill below.
        gui::background::request_stop();
        gui::background::wait_until_core_released(std::time::Duration::from_secs(3));
        kill_leftover_core();
        worker_flag.store(true, Ordering::SeqCst);
    });
    tray.run_shutdown_animation(
        &|| cleanup_done.load(Ordering::SeqCst),
        std::time::Duration::from_secs(10),
    );
    let _ = cleanup.join();

    // Remove the tray icon deterministically: std::process::exit skips
    // destructors, and a tray icon of a dead process lingers as a ghost until
    // the user hovers over it.
    drop(tray);

    // Dropping the tokio runtime here would wait for in-flight background work
    // (an `opencode upgrade` child can run for minutes, DNS lookups block the
    // blocking pool), which is exactly the invisible delay that made «Выйти»
    // look broken. Everything the user cares about is already done.
    std::process::exit(0);
}

/// Best-effort safety net: the core must never outlive the GUI, even if the
/// child handle was lost (e.g. the core restarted itself via /api/restart).
fn kill_leftover_core() {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let _ = std::process::Command::new("taskkill")
        .args(["/IM", "delegator-core.exe", "/T", "/F"])
        .creation_flags(CREATE_NO_WINDOW)
        .output();
}
