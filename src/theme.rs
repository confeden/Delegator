use eframe::egui::{self, Color32, FontData, FontDefinitions, FontFamily, FontId, TextStyle};
use serde::Deserialize;
use std::collections::BTreeMap;
use std::path::PathBuf;

const DEFAULT_THEME_JSON: &str = include_str!("../assets/theme.json");

#[derive(Debug, Clone, Deserialize)]
pub struct ThemeConfig {
    #[allow(dead_code)]
    pub name: String,
    pub font_family: String,
    pub font_size: f32,
    pub item_spacing_x: f32,
    pub item_spacing_y: f32,
    pub button_padding_x: f32,
    pub button_padding_y: f32,
    pub background: String,
    pub panel: String,
    pub window: String,
    pub control: String,
    pub control_hovered: String,
    pub control_active: String,
    pub text: String,
    pub weak_text: String,
    pub accent: String,
    pub selection: String,
    pub hyperlink: String,
    pub success: String,
    pub warning: String,
    pub error: String,
}

impl ThemeConfig {
    pub fn load() -> Self {
        theme_path()
            .and_then(|path| std::fs::read_to_string(path).ok())
            .and_then(|content| serde_json::from_str(&content).ok())
            .or_else(|| serde_json::from_str(DEFAULT_THEME_JSON).ok())
            .expect("embedded theme.json must be valid")
    }

    pub fn accent_color(&self) -> Color32 {
        parse_color(&self.accent, Color32::LIGHT_BLUE)
    }

    pub fn success_color(&self) -> Color32 {
        parse_color(&self.success, Color32::LIGHT_GREEN)
    }

    pub fn weak_text_color(&self) -> Color32 {
        parse_color(&self.weak_text, Color32::GRAY)
    }

    #[allow(dead_code)]
    pub fn warning_color(&self) -> Color32 {
        parse_color(&self.warning, Color32::YELLOW)
    }

    #[allow(dead_code)]
    pub fn error_color(&self) -> Color32 {
        parse_color(&self.error, Color32::LIGHT_RED)
    }
}

pub fn apply(ctx: &egui::Context) -> ThemeConfig {
    let theme = ThemeConfig::load();
    install_segoe_semibold(ctx, &theme.font_family);
    ctx.set_theme(egui::Theme::Dark);

    let font = FontId::new(theme.font_size.max(8.0), FontFamily::Proportional);
    let mut text_styles = BTreeMap::new();
    text_styles.insert(TextStyle::Small, font.clone());
    text_styles.insert(TextStyle::Body, font.clone());
    text_styles.insert(TextStyle::Button, font.clone());
    text_styles.insert(TextStyle::Heading, font.clone());
    text_styles.insert(TextStyle::Monospace, font);

    let mut style = (*ctx.style()).clone();
    style.text_styles = text_styles;
    style.spacing.item_spacing = egui::vec2(theme.item_spacing_x, theme.item_spacing_y);
    style.spacing.button_padding = egui::vec2(theme.button_padding_x, theme.button_padding_y);

    let mut visuals = egui::Visuals::dark();
    visuals.override_text_color = Some(parse_color(&theme.text, Color32::WHITE));
    visuals.panel_fill = parse_color(&theme.panel, Color32::from_rgb(21, 25, 34));
    visuals.window_fill = parse_color(&theme.window, Color32::from_rgb(24, 29, 39));
    visuals.extreme_bg_color = parse_color(&theme.background, Color32::from_rgb(16, 18, 24));
    visuals.faint_bg_color = parse_color(&theme.control, Color32::from_rgb(34, 41, 54));
    visuals.selection.bg_fill = parse_color(&theme.selection, Color32::from_rgb(36, 86, 106));
    visuals.selection.stroke.color = theme.accent_color();
    visuals.hyperlink_color = parse_color(&theme.hyperlink, Color32::LIGHT_BLUE);
    visuals.warn_fg_color = theme.warning_color();
    visuals.error_fg_color = theme.error_color();
    visuals.widgets.noninteractive.bg_fill = parse_color(&theme.panel, visuals.panel_fill);
    visuals.widgets.inactive.bg_fill = parse_color(&theme.control, visuals.faint_bg_color);
    visuals.widgets.hovered.bg_fill = parse_color(&theme.control_hovered, visuals.faint_bg_color);
    visuals.widgets.hovered.fg_stroke.color = theme.accent_color();
    visuals.widgets.active.bg_fill = parse_color(&theme.control_active, visuals.faint_bg_color);
    visuals.widgets.active.fg_stroke.color = theme.accent_color();

    style.visuals = visuals;
    ctx.set_style(style);
    theme
}

fn theme_path() -> Option<PathBuf> {
    std::env::current_exe()
        .ok()?
        .parent()
        .map(|root| root.join("resources").join("theme.json"))
}

fn install_segoe_semibold(ctx: &egui::Context, family_name: &str) {
    let windows_dir = std::env::var_os("WINDIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(r"C:\Windows"));
    let font_path = windows_dir.join("Fonts").join("seguisb.ttf");
    let Ok(bytes) = std::fs::read(font_path) else {
        return;
    };

    let mut fonts = FontDefinitions::default();
    let font_key = family_name.trim().to_string();
    fonts
        .font_data
        .insert(font_key.clone(), FontData::from_owned(bytes).into());
    fonts
        .families
        .entry(FontFamily::Proportional)
        .or_default()
        .insert(0, font_key);
    ctx.set_fonts(fonts);
}

fn parse_color(value: &str, fallback: Color32) -> Color32 {
    let hex = value.trim().trim_start_matches('#');
    if hex.len() != 6 {
        return fallback;
    }
    let Ok(rgb) = u32::from_str_radix(hex, 16) else {
        return fallback;
    };
    Color32::from_rgb(
        ((rgb >> 16) & 0xff) as u8,
        ((rgb >> 8) & 0xff) as u8,
        (rgb & 0xff) as u8,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn embedded_theme_is_valid_and_dark() {
        let theme: ThemeConfig = serde_json::from_str(DEFAULT_THEME_JSON).unwrap();
        assert_eq!(theme.font_family, "Segoe UI Semibold");
        assert_eq!(theme.font_size, 16.0);
        assert_eq!(
            parse_color(&theme.background, Color32::WHITE),
            Color32::from_rgb(16, 18, 24)
        );
    }
}
