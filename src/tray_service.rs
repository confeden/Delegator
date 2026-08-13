use eframe::egui;
use std::cell::RefCell;
use std::os::windows::process::CommandExt;
use std::process::Command;
use std::sync::atomic::{AtomicBool, AtomicIsize, Ordering};
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

/// Injects the action «Открыть Delegator» produces. Used by the
/// `DELEGATOR_SELFTEST_OPEN_SECS` hook to verify that the window really comes
/// to the front without driving the tray menu by hand.
pub fn request_open_for_test() {
    if let Some(tx) = QUIT_TX.get() {
        raise_window();
        let _ = tx.send(TrayAction::Open);
        wake_ui();
    }
}

/// Window handle of the GUI, published once eframe has created it.
///
/// Windows delivers no paint messages to a hidden window, so while Delegator
/// sits in the tray its egui loop does not run at all: a queued «Открыть»
/// action would only be handled the next time something else woke the loop
/// (reported 2026-08-11 — the window simply stayed hidden). Showing the window
/// therefore has to happen through Win32 directly, from the tray callback.
static WINDOW_HANDLE: AtomicIsize = AtomicIsize::new(0);

pub fn attach_window_handle(handle: isize) {
    WINDOW_HANDLE.store(handle, Ordering::SeqCst);
}

/// Shows, un-minimises and foregrounds the GUI window. No-op until the window
/// exists.
pub fn raise_window() {
    let handle = WINDOW_HANDLE.load(Ordering::SeqCst);
    if handle == 0 {
        return;
    }
    #[cfg(target_os = "windows")]
    unsafe {
        use windows_sys::Win32::Foundation::HWND;
        use windows_sys::Win32::System::Threading::{AttachThreadInput, GetCurrentThreadId};
        use windows_sys::Win32::UI::Input::KeyboardAndMouse::SetFocus;
        use windows_sys::Win32::UI::WindowsAndMessaging::{
            BringWindowToTop, GetForegroundWindow, GetWindowThreadProcessId, IsIconic,
            SetForegroundWindow, ShowWindow, SW_RESTORE, SW_SHOW,
        };

        let hwnd = handle as HWND;
        ShowWindow(hwnd, SW_SHOW);
        if IsIconic(hwnd) != 0 {
            ShowWindow(hwnd, SW_RESTORE);
        }

        // Windows only hands the foreground to the process that owns the
        // current foreground window, so borrow its input queue for the switch.
        let foreground = GetForegroundWindow();
        let foreground_thread = if foreground.is_null() {
            0
        } else {
            GetWindowThreadProcessId(foreground, std::ptr::null_mut())
        };
        let this_thread = GetCurrentThreadId();
        let attached = foreground_thread != 0
            && foreground_thread != this_thread
            && AttachThreadInput(this_thread, foreground_thread, 1) != 0;

        BringWindowToTop(hwnd);
        SetForegroundWindow(hwnd);
        SetFocus(hwnd);

        if attached {
            AttachThreadInput(this_thread, foreground_thread, 0);
        }
    }
}

/// True while the main window is on screen. A hidden window gets no paint
/// messages, so its egui loop — and everything driven from it — is frozen.
fn window_is_visible() -> bool {
    let handle = WINDOW_HANDLE.load(Ordering::SeqCst);
    if handle == 0 {
        return false;
    }
    #[cfg(target_os = "windows")]
    unsafe {
        use windows_sys::Win32::Foundation::HWND;
        use windows_sys::Win32::UI::WindowsAndMessaging::IsWindowVisible;
        IsWindowVisible(handle as HWND) != 0
    }
    #[cfg(not(target_os = "windows"))]
    true
}

/// Set by the GUI as soon as it acts on «Выйти».
static QUIT_HANDLED: AtomicBool = AtomicBool::new(false);
const QUIT_WATCHDOG: Duration = Duration::from_secs(5);
/// From the tray the GUI cannot act at all (frozen loop), so waiting the full
/// watchdog only adds dead time before the forced exit.
const QUIT_WATCHDOG_HIDDEN: Duration = Duration::from_millis(1200);

pub fn mark_quit_handled() {
    QUIT_HANDLED.store(true, Ordering::SeqCst);
}

/// Last-resort exit: "Выйти" must never look like it did nothing. If the GUI
/// has not acted within the watchdog window, terminate the core and this
/// process directly.
fn start_quit_watchdog() {
    let budget = if window_is_visible() {
        QUIT_WATCHDOG
    } else {
        QUIT_WATCHDOG_HIDDEN
    };
    std::thread::spawn(move || {
        std::thread::sleep(budget);
        if QUIT_HANDLED.load(Ordering::SeqCst) {
            return;
        }
        // Stop the supervisor first, or it treats the kill below as a crash and
        // starts a fresh core that then outlives this process.
        crate::gui::background::request_stop();
        crate::gui::background::wait_until_core_released(Duration::from_secs(2));
        let _ = Command::new("taskkill")
            .args(["/IM", "delegator-core.exe", "/T", "/F"])
            .creation_flags(CREATE_NO_WINDOW)
            .output();
        std::process::exit(0);
    });
}

/// The «Включить/Отключить» item, so its label can follow the actual state.
/// Thread-local because tray handles may only be touched from the thread that
/// created them — the same thread that runs the egui loop.
thread_local! {
    static TOGGLE_ITEM: RefCell<Option<MenuItem>> = const { RefCell::new(None) };
}

/// Label the tray toggle with the action it performs, not with the state.
pub fn set_toggle_label(enabled: bool) {
    let text = if enabled {
        "Отключить"
    } else {
        "Включить"
    };
    TOGGLE_ITEM.with(|item| {
        if let Some(item) = item.borrow().as_ref() {
            item.set_text(text);
        }
    });
}

/// Actions the GUI still has to perform itself. «Включить/Отключить» is NOT
/// among them: it is executed right in the menu callback, because that callback
/// runs on the tray/UI thread while the egui loop of a hidden window does not
/// run at all (see `gui::background`).
#[derive(Debug, Clone, Copy)]
pub enum TrayAction {
    Open,
    Quit,
}

pub struct TrayManager {
    tray_icon: TrayIcon,
    base_pixels: Vec<u8>,
    icon_size: (u32, u32),
    _open_item: MenuItem,
    _toggle_item: MenuItem,
    _quit_item: MenuItem,
}

impl TrayManager {
    pub fn setup() -> Result<(Self, Receiver<TrayAction>), Box<dyn std::error::Error>> {
        let tray_menu = Menu::new();
        let open_item = MenuItem::new("Открыть Delegator", true, None);
        // Text is replaced by set_toggle_label as soon as the GUI knows the state.
        let toggle_item = MenuItem::new("Отключить", true, None);
        let quit_item = MenuItem::new("Выйти из Delegator", true, None);

        let _ = tray_menu.append(&open_item);
        let _ = tray_menu.append(&toggle_item);
        let _ = tray_menu.append(&quit_item);

        let logo = image::load_from_memory(include_bytes!("../assets/delegator-logo.png"))?
            .resize_exact(64, 64, image::imageops::FilterType::Lanczos3)
            .into_rgba8();
        let (width, height) = logo.dimensions();
        let base_pixels = logo.into_raw();
        let icon = Icon::from_rgba(base_pixels.clone(), width, height)?;

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
                raise_window();
                Some(TrayAction::Open)
            } else if event.id == toggle_id {
                // Done here and now: the GUI would only see the request the
                // next time the window is opened. This callback runs on the
                // thread that owns the menu item, so relabelling works too.
                set_toggle_label(crate::gui::background::toggle_delegator_enabled());
                // An open window has to re-read the config it no longer owns.
                wake_ui();
                None
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
                raise_window();
                let _ = tx.send(TrayAction::Open);
                wake_ui();
            }
        }));

        TOGGLE_ITEM.with(|slot| *slot.borrow_mut() = Some(toggle_item.clone()));

        Ok((
            Self {
                tray_icon,
                base_pixels,
                icon_size: (width, height),
                _open_item: open_item,
                _toggle_item: toggle_item,
                _quit_item: quit_item,
            },
            rx,
        ))
    }

    /// Pulses the tray icon and switches the tooltip to «Завершение работы…»
    /// while shutdown work runs, so a quit that takes a few seconds does not
    /// look like a hang. Must be called on the thread that owns the tray icon.
    pub fn run_shutdown_animation(&self, done: &dyn Fn() -> bool, max: Duration) {
        let _ = self
            .tray_icon
            .set_tooltip(Some("Delegator: завершение работы..."));
        let (width, height) = self.icon_size;
        let started = std::time::Instant::now();
        let mut step: usize = 0;
        while !done() && started.elapsed() < max {
            // Fade the icon in and out: 100% -> 40% alpha and back.
            let phase = step % 8;
            let level = if phase < 4 { 4 - phase } else { phase - 3 };
            let alpha_scale = 0.4 + 0.15 * level as f32;
            let mut pixels = self.base_pixels.clone();
            for chunk in pixels.chunks_exact_mut(4) {
                chunk[3] = (chunk[3] as f32 * alpha_scale).round().clamp(0.0, 255.0) as u8;
            }
            if let Ok(frame) = Icon::from_rgba(pixels, width, height) {
                let _ = self.tray_icon.set_icon(Some(frame));
            }
            step += 1;
            std::thread::sleep(Duration::from_millis(120));
        }
    }
}
