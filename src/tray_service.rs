use std::sync::mpsc::{channel, Receiver};
use tray_icon::menu::{Menu, MenuEvent, MenuItem};
use tray_icon::{Icon, TrayIcon, TrayIconBuilder, TrayIconEvent};

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
                Some(TrayAction::Quit)
            } else {
                None
            };
            if let Some(action) = action {
                let _ = menu_tx.send(action);
            }
        }));
        TrayIconEvent::set_event_handler(Some(move |event: TrayIconEvent| {
            if matches!(event, TrayIconEvent::DoubleClick { .. }) {
                let _ = tx.send(TrayAction::Open);
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
