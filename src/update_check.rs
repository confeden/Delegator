//! Periodic "is there a newer release?" check against the GitHub releases API,
//! plus the release metadata the in-app updater needs (the installer asset).
//!
//! Release tags follow the `vMAJOR.MINOR[.PATCH]` scheme (e.g. `v0.4`). The check
//! runs at most once every 8 hours; the last attempt is persisted in the runtime
//! data dir so restarts do not re-query GitHub on every launch. State lives next
//! to the PowerShell runtime state (not in config.json) so the GUI config stays
//! purely user-owned.
//!
//! # Test overrides (both are OFF unless the variable is set)
//!
//! * `DELEGATOR_UPDATE_API_URL` — replaces the GitHub "latest release" endpoint,
//!   so the whole flow can be exercised against a local stub server. While it is
//!   set the 8-hour throttle is bypassed and the cached result is ignored, so a
//!   stub run always sees a fresh answer instead of yesterday's real one.
//!   Production behaviour is untouched when the variable is absent.
//! * `DELEGATOR_SELFTEST_UPDATE=1` — see `gui::app`: the GUI presses its own
//!   «Обновить до …» button as soon as a newer release is known.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

pub const RELEASES_URL: &str = "https://github.com/confeden/Delegator/releases";
const LATEST_RELEASE_API: &str = "https://api.github.com/repos/confeden/Delegator/releases/latest";
/// Endpoint override for end-to-end tests against a local stub.
const API_URL_ENV: &str = "DELEGATOR_UPDATE_API_URL";
const CHECK_INTERVAL: Duration = Duration::from_secs(8 * 60 * 60);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);

/// The installer published with every release: `DelegatorSetup-<version>.exe`.
const INSTALLER_PREFIX: &str = "delegatorsetup-";
const INSTALLER_SUFFIX: &str = ".exe";

/// Shown (as a tooltip) when the release carries no installer to run.
pub const NO_INSTALLER_ASSET: &str = "в релизе нет файла DelegatorSetup-*.exe";

/// The downloadable installer of a release.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct ReleaseAsset {
    pub name: String,
    pub url: String,
    /// Size reported by the API; 0 when the API did not say.
    pub size: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UpdateStatus {
    UpToDate,
    Available {
        tag: String,
        url: String,
        /// `None` when the release publishes no `DelegatorSetup-*.exe`; the
        /// button then reports the failure instead of downloading nothing.
        asset: Option<ReleaseAsset>,
    },
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
    /// Installer of the latest release, so the button still works after a
    /// restart inside the 8-hour window.
    #[serde(default)]
    installer: Option<ReleaseAsset>,
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
    #[serde(default)]
    assets: Vec<GithubAsset>,
}

#[derive(Deserialize)]
struct GithubAsset {
    #[serde(default)]
    name: String,
    #[serde(default)]
    browser_download_url: String,
    #[serde(default)]
    size: u64,
}

impl From<GithubAsset> for ReleaseAsset {
    fn from(asset: GithubAsset) -> Self {
        Self {
            name: asset.name,
            url: asset.browser_download_url,
            size: asset.size,
        }
    }
}

/// The `DelegatorSetup-*.exe` of a release (case-insensitive, first match wins).
/// Assets without a download url are ignored: they cannot be fetched anyway.
pub fn pick_installer_asset(assets: &[ReleaseAsset]) -> Result<ReleaseAsset, String> {
    assets
        .iter()
        .find(|asset| {
            let name = asset.name.trim().to_ascii_lowercase();
            name.starts_with(INSTALLER_PREFIX)
                && name.ends_with(INSTALLER_SUFFIX)
                && !asset.url.trim().is_empty()
        })
        .cloned()
        .ok_or_else(|| NO_INSTALLER_ASSET.to_string())
}

/// `DELEGATOR_UPDATE_API_URL` when set and non-empty, the GitHub endpoint otherwise.
fn latest_release_api() -> String {
    api_url_override().unwrap_or_else(|| LATEST_RELEASE_API.to_string())
}

fn api_url_override() -> Option<String> {
    std::env::var(API_URL_ENV)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
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

/// True when the 8-hour window since the last attempt has elapsed. A stub
/// endpoint (`DELEGATOR_UPDATE_API_URL`) is always due — otherwise a real check
/// done hours ago would silence the test run.
pub fn is_check_due() -> bool {
    if api_url_override().is_some() {
        return true;
    }
    let state = read_state();
    if state.last_checked_unix == 0 {
        return true;
    }
    now_unix().saturating_sub(state.last_checked_unix) >= CHECK_INTERVAL.as_secs()
}

/// Last known result without touching the network (used to restore the button
/// after a restart inside the 8-hour window). Suppressed while the endpoint is
/// overridden: a cached asset url would point at GitHub, not at the stub.
pub fn cached_status() -> Option<UpdateStatus> {
    if api_url_override().is_some() {
        return None;
    }
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
            asset: state.installer,
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
        .get(latest_release_api())
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
    let assets: Vec<ReleaseAsset> = release.assets.into_iter().map(ReleaseAsset::from).collect();
    state.installer = match pick_installer_asset(&assets) {
        Ok(asset) => {
            println!(
                "Release {} carries installer {}",
                state.latest_tag, asset.name
            );
            Some(asset)
        }
        Err(_) => {
            // Not fatal: the release still exists, only the one-click install
            // is unavailable. The button reports it when pressed.
            eprintln!(
                "Release {} has no DelegatorSetup-*.exe asset ({} assets seen)",
                state.latest_tag,
                assets.len()
            );
            None
        }
    };
    write_state(&state);

    if is_newer_than_current(&state.latest_tag) {
        UpdateStatus::Available {
            tag: state.latest_tag.clone(),
            url: state.latest_url.clone(),
            asset: state.installer.clone(),
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

    fn asset(name: &str, url: &str) -> ReleaseAsset {
        ReleaseAsset {
            name: name.to_string(),
            url: url.to_string(),
            size: 42,
        }
    }

    #[test]
    fn picks_the_installer_asset_case_insensitively() {
        let assets = vec![
            asset("checksums.txt", "https://example/checksums.txt"),
            asset("Delegator-source.zip", "https://example/source.zip"),
            asset(
                "delegatorsetup-0.4.4.EXE",
                "https://example/DelegatorSetup-0.4.4.exe",
            ),
        ];
        let picked = pick_installer_asset(&assets).expect("installer is found");
        assert_eq!(picked.name, "delegatorsetup-0.4.4.EXE");
        assert_eq!(picked.url, "https://example/DelegatorSetup-0.4.4.exe");
        assert_eq!(picked.size, 42);
    }

    #[test]
    fn installer_asset_needs_the_right_name_and_a_url() {
        // Nothing that looks like the installer at all.
        assert_eq!(
            pick_installer_asset(&[
                asset("Delegator.zip", "https://example/Delegator.zip"),
                asset("DelegatorSetup.exe", "https://example/DelegatorSetup.exe"),
                asset(
                    "DelegatorSetup-0.4.4.exe.sha256",
                    "https://example/hash.txt"
                ),
            ]),
            Err(NO_INSTALLER_ASSET.to_string())
        );
        assert_eq!(
            pick_installer_asset(&[]),
            Err(NO_INSTALLER_ASSET.to_string())
        );
        // Right name, but the API gave no download url — unusable.
        assert_eq!(
            pick_installer_asset(&[asset("DelegatorSetup-0.4.4.exe", "  ")]),
            Err(NO_INSTALLER_ASSET.to_string())
        );
    }

    #[test]
    fn release_json_yields_the_installer_asset() {
        // Shape trimmed from a real GitHub /releases/latest response.
        let raw = r#"{
            "tag_name": "v9.9",
            "html_url": "https://github.com/confeden/Delegator/releases/tag/v9.9",
            "draft": false,
            "prerelease": false,
            "assets": [
                {"name":"README.md","browser_download_url":"https://example/README.md","size":10},
                {"name":"DelegatorSetup-9.9.exe",
                 "browser_download_url":"https://example/DelegatorSetup-9.9.exe",
                 "size":12345678}
            ]
        }"#;
        let release: GithubRelease = serde_json::from_str(raw).expect("release json parses");
        let assets: Vec<ReleaseAsset> =
            release.assets.into_iter().map(ReleaseAsset::from).collect();
        let picked = pick_installer_asset(&assets).expect("installer is found");
        assert_eq!(picked.name, "DelegatorSetup-9.9.exe");
        assert_eq!(picked.url, "https://example/DelegatorSetup-9.9.exe");
        assert_eq!(picked.size, 12_345_678);
    }

    #[test]
    fn state_file_keeps_the_installer_across_restarts() {
        // Old state files (0.4.3 and earlier) have no `installer` key.
        let legacy: UpdateCheckState = serde_json::from_str(
            r#"{"last_checked_unix":1,"latest_tag":"v9.9","latest_url":"https://example/tag"}"#,
        )
        .expect("legacy state parses");
        assert_eq!(legacy.installer, None);

        let state = UpdateCheckState {
            last_checked_unix: 1,
            latest_tag: "v9.9".to_string(),
            latest_url: "https://example/tag".to_string(),
            installer: Some(asset("DelegatorSetup-9.9.exe", "https://example/setup.exe")),
        };
        let text = serde_json::to_string(&state).expect("state serializes");
        let parsed: UpdateCheckState = serde_json::from_str(&text).expect("state parses");
        assert_eq!(parsed.installer, state.installer);
    }
}
