//! Periodic "is there a newer release?" check against the GitHub releases API.
//!
//! Release tags follow the `vMAJOR.MINOR[.PATCH]` scheme (e.g. `v0.4`). The check
//! runs at most once every 8 hours; the last attempt is persisted in the runtime
//! data dir so restarts do not re-query GitHub on every launch. State lives next
//! to the PowerShell runtime state (not in config.json) so the GUI config stays
//! purely user-owned.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

pub const RELEASES_URL: &str = "https://github.com/confeden/Delegator/releases";
const LATEST_RELEASE_API: &str = "https://api.github.com/repos/confeden/Delegator/releases/latest";
const CHECK_INTERVAL: Duration = Duration::from_secs(8 * 60 * 60);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UpdateStatus {
    UpToDate,
    Available { tag: String, url: String },
    Failed(String),
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct UpdateCheckState {
    #[serde(default)]
    last_checked_unix: u64,
    #[serde(default)]
    latest_tag: String,
    #[serde(default)]
    latest_url: String,
}

#[derive(Deserialize)]
struct GithubRelease {
    #[serde(default)]
    tag_name: String,
    #[serde(default)]
    html_url: String,
    #[serde(default)]
    draft: bool,
    #[serde(default)]
    prerelease: bool,
}

fn runtime_home() -> PathBuf {
    if let Ok(explicit) = std::env::var("DELEGATOR_RUNTIME_HOME") {
        if !explicit.trim().is_empty() {
            return PathBuf::from(explicit);
        }
    }
    let base = std::env::var("LOCALAPPDATA")
        .or_else(|_| std::env::var("APPDATA"))
        .unwrap_or_default();
    PathBuf::from(base).join("DelegatorWin").join("runtime")
}

fn state_path() -> PathBuf {
    runtime_home().join("update-check.json")
}

fn now_unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn read_state() -> UpdateCheckState {
    std::fs::read_to_string(state_path())
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_default()
}

fn write_state(state: &UpdateCheckState) {
    let path = state_path();
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Ok(text) = serde_json::to_string_pretty(state) {
        let _ = std::fs::write(path, text);
    }
}

/// True when the 8-hour window since the last attempt has elapsed.
pub fn is_check_due() -> bool {
    let state = read_state();
    if state.last_checked_unix == 0 {
        return true;
    }
    now_unix().saturating_sub(state.last_checked_unix) >= CHECK_INTERVAL.as_secs()
}

/// Last known result without touching the network (used to restore the banner
/// after a restart inside the 8-hour window).
pub fn cached_status() -> Option<UpdateStatus> {
    let state = read_state();
    if state.latest_tag.is_empty() {
        return None;
    }
    if is_newer_than_current(&state.latest_tag) {
        Some(UpdateStatus::Available {
            tag: state.latest_tag.clone(),
            url: if state.latest_url.is_empty() {
                RELEASES_URL.to_string()
            } else {
                state.latest_url
            },
        })
    } else {
        Some(UpdateStatus::UpToDate)
    }
}

/// Query GitHub for the latest release. Records the attempt (success or failure)
/// so a broken network cannot cause a request storm.
pub async fn fetch_latest_release() -> UpdateStatus {
    let mut state = read_state();
    state.last_checked_unix = now_unix();

    let client = match reqwest::Client::builder()
        .timeout(REQUEST_TIMEOUT)
        // GitHub rejects requests without a User-Agent.
        .user_agent(concat!("Delegator/", env!("CARGO_PKG_VERSION")))
        .build()
    {
        Ok(client) => client,
        Err(error) => {
            write_state(&state);
            return UpdateStatus::Failed(format!("HTTP client error: {error}"));
        }
    };

    let response = match client
        .get(LATEST_RELEASE_API)
        .header("Accept", "application/vnd.github+json")
        .send()
        .await
    {
        Ok(response) => response,
        Err(error) => {
            write_state(&state);
            return UpdateStatus::Failed(short_error(&error.to_string()));
        }
    };

    if response.status() == reqwest::StatusCode::NOT_FOUND {
        // No published release yet — that is not an error worth showing.
        write_state(&state);
        return UpdateStatus::UpToDate;
    }
    if !response.status().is_success() {
        let status = response.status().as_u16();
        write_state(&state);
        return UpdateStatus::Failed(format!("GitHub HTTP {status}"));
    }

    let release: GithubRelease = match response.json().await {
        Ok(release) => release,
        Err(error) => {
            write_state(&state);
            return UpdateStatus::Failed(short_error(&error.to_string()));
        }
    };

    if release.draft || release.prerelease || release.tag_name.trim().is_empty() {
        write_state(&state);
        return UpdateStatus::UpToDate;
    }

    state.latest_tag = release.tag_name.trim().to_string();
    state.latest_url = if release.html_url.trim().is_empty() {
        RELEASES_URL.to_string()
    } else {
        release.html_url.trim().to_string()
    };
    write_state(&state);

    if is_newer_than_current(&state.latest_tag) {
        UpdateStatus::Available {
            tag: state.latest_tag.clone(),
            url: state.latest_url.clone(),
        }
    } else {
        UpdateStatus::UpToDate
    }
}

fn short_error(message: &str) -> String {
    let trimmed = message.trim();
    if trimmed.chars().count() > 120 {
        let cut: String = trimmed.chars().take(117).collect();
        format!("{cut}...")
    } else {
        trimmed.to_string()
    }
}

/// Tags are `vMAJOR.MINOR[.PATCH]`; missing components count as 0, so `v0.4`
/// and `v0.4.0` compare equal.
fn parse_version(raw: &str) -> Option<(u64, u64, u64)> {
    let cleaned = raw.trim().trim_start_matches(['v', 'V']);
    let core = cleaned
        .split(['-', '+'])
        .next()
        .unwrap_or(cleaned)
        .trim_end_matches('.');
    if core.is_empty() {
        return None;
    }
    let mut parts = core.split('.');
    let major = parts.next()?.parse::<u64>().ok()?;
    let minor = parts.next().unwrap_or("0").parse::<u64>().ok()?;
    let patch = parts.next().unwrap_or("0").parse::<u64>().ok()?;
    Some((major, minor, patch))
}

fn is_newer_than_current(tag: &str) -> bool {
    match (parse_version(tag), parse_version(env!("CARGO_PKG_VERSION"))) {
        (Some(remote), Some(current)) => remote > current,
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_two_and_three_component_tags() {
        assert_eq!(parse_version("v0.4"), Some((0, 4, 0)));
        assert_eq!(parse_version("v0.4.0"), Some((0, 4, 0)));
        assert_eq!(parse_version("0.4.2"), Some((0, 4, 2)));
        assert_eq!(parse_version("v1.0.0-beta.1"), Some((1, 0, 0)));
        assert_eq!(parse_version("release"), None);
        assert_eq!(parse_version(""), None);
    }

    #[test]
    fn compares_tag_against_crate_version() {
        let current = parse_version(env!("CARGO_PKG_VERSION")).expect("crate version parses");
        let newer = format!("v{}.{}", current.0, current.1 + 1);
        let older = format!("v{}.{}.{}", current.0, current.1, current.2);
        assert!(is_newer_than_current(&newer));
        assert!(!is_newer_than_current(&older));
        // A malformed tag must never claim an update is available.
        assert!(!is_newer_than_current("not-a-version"));
    }

    #[test]
    fn truncates_long_error_text() {
        let long = "x".repeat(400);
        assert_eq!(short_error(&long).chars().count(), 120);
        assert_eq!(short_error("  boom  "), "boom");
    }
}
