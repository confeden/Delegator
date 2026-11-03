//! «Интеграция → Web»: what the core knows about each web door, and the «Войти» button.
//!
//! The GUI never touches a site. «Войти» asks the core, the core asks the extension, the extension
//! opens the site in the user's Chrome and reports the sign-in when the page shows one.

use serde::Deserialize;
use std::time::Duration;

const CORE_URL: &str = "http://127.0.0.1:1380";

/// Shape of GET /api/web/doors (DEV_CONTRACTS §14). Defaulted so an older core still renders.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct WebDoorsReport {
    pub connected: bool,
    pub doors: Vec<WebDoorRow>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct WebDoorRow {
    pub id: String,
    pub auth: String,
    pub auth_label: String,
    pub resting_sec: u64,
    pub rest_reason: String,
    pub last_error: String,
    pub last_seconds: f64,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct WebLoginReply {
    /// False when the extension has not called in lately: nothing will open the page by itself.
    pub queued: bool,
    pub url: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DoorTone {
    Good,
    Warn,
    Weak,
}

/// The status next to a door's «Войти». One short phrase (D9); the tooltip carries the detail.
pub fn door_status(row: Option<&WebDoorRow>, connected: bool) -> (String, DoorTone) {
    let Some(row) = row else {
        return ("нет связи с ядром".to_string(), DoorTone::Weak);
    };
    if row.auth == "checking" {
        return ("жду вход в браузере…".to_string(), DoorTone::Warn);
    }
    if !connected {
        return ("расширение не подключено".to_string(), DoorTone::Warn);
    }
    if row.auth == "signed_out" {
        return ("нужен вход".to_string(), DoorTone::Warn);
    }
    if row.resting_sec > 0 {
        let minutes = row.resting_sec.div_ceil(60);
        let why = match row.rest_reason.as_str() {
            "quota" => "лимит",
            "slow" => "не отвечал",
            "login" => "нужен вход",
            _ => "сбой",
        };
        return (format!("{why}, пауза {minutes} мин"), DoorTone::Warn);
    }
    if row.auth == "signed_in" {
        return ("вход подтверждён".to_string(), DoorTone::Good);
    }
    ("вход не проверен".to_string(), DoorTone::Weak)
}

fn client() -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .timeout(Duration::from_secs(5))
        .build()
        .map_err(|error| format!("не удалось создать HTTP-клиент ({error})"))
}

pub async fn fetch_web_doors() -> Result<WebDoorsReport, String> {
    let response = client()?
        .get(format!("{CORE_URL}/api/web/doors"))
        .send()
        .await
        .map_err(|_| "ядро Delegator не отвечает".to_string())?;
    if !response.status().is_success() {
        return Err(format!("ядро вернуло HTTP {}", response.status().as_u16()));
    }
    response
        .json::<WebDoorsReport>()
        .await
        .map_err(|_| "не удалось разобрать ответ ядра".to_string())
}

pub async fn request_login(door: &str) -> Result<WebLoginReply, String> {
    let response = client()?
        .post(format!("{CORE_URL}/api/web/login"))
        .json(&serde_json::json!({ "door": door }))
        .send()
        .await
        .map_err(|_| "ядро Delegator не отвечает".to_string())?;
    if !response.status().is_success() {
        return Err(format!("ядро вернуло HTTP {}", response.status().as_u16()));
    }
    response
        .json::<WebLoginReply>()
        .await
        .map_err(|_| "не удалось разобрать ответ ядра".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(auth: &str) -> WebDoorRow {
        WebDoorRow {
            id: "kimi".to_string(),
            auth: auth.to_string(),
            ..WebDoorRow::default()
        }
    }

    #[test]
    fn a_confirmed_sign_in_is_the_only_good_status() {
        assert_eq!(door_status(Some(&row("signed_in")), true).1, DoorTone::Good);
        assert_eq!(door_status(Some(&row("unknown")), true).1, DoorTone::Weak);
        assert_eq!(
            door_status(Some(&row("signed_out")), true).1,
            DoorTone::Warn
        );
    }

    #[test]
    fn a_login_in_progress_outranks_a_silent_extension() {
        // The worker may sleep through a poll while the user is typing a password.
        assert_eq!(
            door_status(Some(&row("checking")), false).0,
            "жду вход в браузере…"
        );
    }

    #[test]
    fn no_extension_is_not_reported_as_signed_in() {
        let (text, tone) = door_status(Some(&row("signed_in")), false);
        assert_eq!(tone, DoorTone::Warn);
        assert!(text.contains("расширение"), "{text}");
    }

    #[test]
    fn a_resting_door_says_why_and_rounds_minutes_up() {
        let resting = WebDoorRow {
            auth: "signed_in".to_string(),
            resting_sec: 61,
            rest_reason: "quota".to_string(),
            ..WebDoorRow::default()
        };
        assert_eq!(door_status(Some(&resting), true).0, "лимит, пауза 2 мин");
    }

    #[test]
    fn a_core_that_is_down_is_named() {
        assert_eq!(door_status(None, false).0, "нет связи с ядром");
    }
}
