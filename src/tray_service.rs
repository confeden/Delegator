use eframe::egui;
use std::os::windows::process::CommandExt;
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, Receiver};
use std::sync::OnceLock;
use std::time::Duration;
use tray_icon::menu::{Menu, MenuEvent, MenuItem};
use tray_icon::{Icon, TrayIcon, TrayIconBuilder, TrayIconEvent};

/// The GUI context, published once the eframe app exists. Tray callbacks run on
/// the menu event thread and only push into a channel; without waking the egui
/// loop the message sits unread while the window is hidden in the tray (the loop
/// sleeps until some unrelated OS event arrives), so "Выйти" appeared to do
/// nothing for up to a minute.
static UI_CONTEXT: OnceLock<egui::Context> = OnceLock::new();

pub fn attach_ui_context(ctx: egui::Context) {
    let _ = UI_CONTEXT.set(ctx);
}

fn wake_ui() {
    if let Some(ctx) = UI_CONTEXT.get() {
        ctx.request_repaint();
    }
}

const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// Sender clone kept for the env-gated self-test hook below.
static QUIT_TX: OnceLock<std::sync::mpsc::Sender<TrayAction>> = OnceLock::new();

/// Injects the same action the «Выйти» menu item produces. Used only by the
/// `DELEGATOR_SELFTEST_QUIT_SECS` hook so shutdown latency can be measured
/// without driving the tray menu by hand.
pub fn request_quit_for_test() {
    if let Some(tx) = QUIT_TX.get() {
        let _ = tx.send(TrayAction::Quit);
        start_quit_watchdog();
        wake_ui();
    }
}

/// Set by the GUI as soon as it acts on «Выйти».
static QUIT_HANDLED: AtomicBool = AtomicBool::new(false);
const QUIT_WATCHDOG: Duration = Duration::from_secs(5);

pub fn mark_quit_handled() {
    QUIT_HANDLED.store(true, Ordering::SeqCst);
}

/// Last-resort exit: "Выйти" must never look like it did nothing. If the GUI
/// has not acted within the watchdog window, terminate the core and this
/// process directly.
fn start_quit_watchdog() {
    std::thread::spawn(|| {
        std::thread::sleep(QUIT_WATCHDOG);
        if QUIT_HANDLED.load(Ordering::SeqCst) {
            return;
        }
        let _ = Command::new("taskkill")
            .args(["/IM", "delegator-core.exe", "/T", "/F"])
            .creation_flags(CREATE_NO_WINDOW)
            .output();
        std::process::exit(0);
    });
}

#[derive(Debug, Clone, Copy)]
pub enum TrayAction {
    Open,
    Toggle,
    Quit,
}

pub struct TrayManager {
    _tray_icon: TrayIcon,
    _open_item: MenuItem,
    _toggle_item: MenuItem,
    _quit_item: MenuItem,
}

impl TrayManager {
    pub fn setup() -> Result<(Self, Receiver<TrayAction>), Box<dyn std::error::Error>> {
        let tray_menu = Menu::new();
        let open_item = MenuItem::new("Открыть Delegator", true, None);
        let toggle_item = MenuItem::new("Активен / Пауза", true, None);
        let quit_item = MenuItem::new("Выйти из Delegator", true, None);

        let _ = tray_menu.append(&open_item);
        let _ = tray_menu.append(&toggle_item);
        let _ = tray_menu.append(&quit_item);

        let logo = image::load_from_memory(include_bytes!("../assets/delegator-logo.png"))?
            .resize_exact(64, 64, image::imageops::FilterType::Lanczos3)
            .into_rgba8();
        let (width, height) = logo.dimensions();
        let icon = Icon::from_rgba(logo.into_raw(), width, height)?;

        let tray_icon = TrayIconBuilder::new()
            .with_menu(Box::new(tray_menu))
            .with_tooltip(concat!("Delegator v", env!("CARGO_PKG_VERSION")))
            .with_icon(icon)
            .build()?;

        let (tx, rx) = channel();
        let _ = QUIT_TX.set(tx.clone());
        let open_id = open_item.id().clone();
        let toggle_id = toggle_item.id().clone();
        let quit_id = quit_item.id().clone();
        let menu_tx = tx.clone();
        MenuEvent::set_event_handler(Some(move |event: MenuEvent| {
            let action = if event.id == open_id {
                Some(TrayAction::Open)
            } else if event.id == toggle_id {
                Some(TrayAction::Toggle)
            } else if event.id == quit_id {
                start_quit_watchdog();
                Some(TrayAction::Quit)
            } else {
                None
            };
            if let Some(action) = action {
                let _ = menu_tx.send(action);
                wake_ui();
            }
        }));
        TrayIconEvent::set_event_handler(Some(move |event: TrayIconEvent| {
            if matches!(event, TrayIconEvent::DoubleClick { .. }) {
                let _ = tx.send(TrayAction::Open);
                wake_ui();
            }
        }));

        Ok((
            Self {
                _tray_icon: tray_icon,
                _open_item: open_item,
                _toggle_item: toggle_item,
                _quit_item: quit_item,
            },
            rx,
        ))
    }
}
