//! Provider limits, read from the runtime's own cooldown ledger.
//!
//! When a free tier runs out the provider scripts already record it in
//! `<RT>\cooldowns.json` (DEV_CONTRACTS §5) with the moment the model becomes
//! usable again — Retry-After when the provider sent one, midnight Pacific for
//! a Gemini daily quota. Until now that was invisible in the window: the owner
//! only found out because a benchmark run started answering badly.
//!
//! Nothing here talks to a provider. It reads a file the runtime maintains, so
//! it costs nothing and stays correct while the app sits in the tray.

use serde::Deserialize;
use std::collections::BTreeMap;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

/// Reasons that mean "you ran out", as opposed to "this model misbehaved".
const LIMIT_REASONS: &[&str] = &["rate_limit", "quota", "daily_quota"];

#[derive(Debug, Clone, Default, Deserialize)]
struct CooldownFile {
    #[serde(default)]
    models: BTreeMap<String, CooldownEntry>,
}

/// The PowerShell writer uses camelCase (`lastStatus`); without the rename the
/// field silently stays None in production while the tests pass.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CooldownEntry {
    #[serde(default)]
    until: String,
    #[serde(default)]
    reason: String,
    #[serde(default)]
    last_status: Option<i64>,
}

/// One provider's limit state, ready to print.
#[derive(Debug, Clone, PartialEq)]
pub struct ProviderLimit {
    /// The model that reported it — the user wants to know which one.
    pub model: String,
    /// Seconds until the earliest model of this provider is usable again.
    pub resets_in_sec: u64,
    pub reason: String,
}

impl ProviderLimit {
    /// «3д 5ч 23м», the shape the owner asked for. Under a minute reads as
    /// «меньше минуты» rather than «0м», which looks like a bug.
    pub fn remaining_text(&self) -> String {
        format_remaining(self.resets_in_sec)
    }
}

pub fn format_remaining(seconds: u64) -> String {
    if seconds < 60 {
        return "меньше минуты".to_string();
    }
    let days = seconds / 86_400;
    let hours = (seconds % 86_400) / 3_600;
    let minutes = (seconds % 3_600) / 60;
    let mut parts = Vec::new();
    if days > 0 {
        parts.push(format!("{days}д"));
    }
    if hours > 0 || days > 0 {
        parts.push(format!("{hours}ч"));
    }
    parts.push(format!("{minutes}м"));
    parts.join(" ")
}

/// True when this model id belongs to the OpenCode/Zen side.
fn is_opencode(model: &str) -> bool {
    model.starts_with("opencode/")
        || model.starts_with("openrouter/")
        || model.starts_with("google/gemma")
}

fn unix_now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_secs() as i64)
        .unwrap_or(0)
}

/// Parses the RFC3339 stamps the PowerShell side writes (`2026-08-12T13:32:23Z`).
///
/// Hand-rolled because the app carries no date crate and this is the only place
/// that needs one; anything unparsable is treated as "not limited" rather than
/// as an alarm the user cannot act on.
fn parse_unix(stamp: &str) -> Option<i64> {
    let stamp = stamp.trim();
    let (date, rest) = stamp.split_once('T')?;
    // The two writers disagree: cooldowns.json is UTC («…23Z»), the Google
    // account ledger is local with an offset («…15.63+03:00»). Ignoring the
    // offset put the reset three hours into the future.
    let (clock, offset_sec) = split_offset(rest)?;
    let time = clock.split('.').next().unwrap_or_default();
    let mut date_parts = date.split('-');
    let year: i64 = date_parts.next()?.parse().ok()?;
    let month: i64 = date_parts.next()?.parse().ok()?;
    let day: i64 = date_parts.next()?.parse().ok()?;
    let mut time_parts = time.split(':');
    let hour: i64 = time_parts.next()?.parse().ok()?;
    let minute: i64 = time_parts.next()?.parse().ok()?;
    let second: i64 = time_parts.next().unwrap_or("0").parse().ok()?;
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }
    // Days from the civil calendar (Howard Hinnant's algorithm), UTC.
    let year = if month <= 2 { year - 1 } else { year };
    let era = if year >= 0 { year } else { year - 399 } / 400;
    let year_of_era = year - era * 400;
    let day_of_year = (153 * (if month > 2 { month - 3 } else { month + 9 }) + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    let days = era * 146_097 + day_of_era - 719_468;
    Some(days * 86_400 + hour * 3_600 + minute * 60 + second - offset_sec)
}

/// Splits «13:19:15.63+03:00» into the clock part and the offset in seconds.
fn split_offset(rest: &str) -> Option<(&str, i64)> {
    if let Some(clock) = rest.strip_suffix('Z').or_else(|| rest.strip_suffix('z')) {
        return Some((clock, 0));
    }
    // Scan from the end so the sign is not confused with anything in the time.
    for (index, ch) in rest.char_indices().rev() {
        if ch == '+' || ch == '-' {
            let (clock, tail) = rest.split_at(index);
            let sign = if ch == '-' { -1 } else { 1 };
            let digits = &tail[1..];
            let (hours, minutes) = match digits.split_once(':') {
                Some((hours, minutes)) => (hours, minutes),
                None if digits.len() == 4 => (&digits[..2], &digits[2..]),
                None => (digits, "0"),
            };
            let hours: i64 = hours.parse().ok()?;
            let minutes: i64 = minutes.parse().ok()?;
            return Some((clock, sign * (hours * 3_600 + minutes * 60)));
        }
        if ch == ':' || ch == '.' {
            continue;
        }
        if !ch.is_ascii_digit() {
            return None;
        }
    }
    // No marker at all: the writers we read always emit one, so treat a naive
    // stamp as UTC rather than guessing the machine's zone.
    Some((rest, 0))
}

/// Google's per-ACCOUNT ledger. The per-model cooldowns in `cooldowns.json`
/// miss this entirely: measured live 2026-08-13, both accounts were
/// `quota_or_rate_limited` with an active cooldown while `cooldowns.json` held
/// nothing but expired entries — the exact outage the owner asked to see.
#[derive(Debug, Clone, Default, Deserialize)]
struct GoogleUsage {
    #[serde(default)]
    accounts: BTreeMap<String, GoogleAccount>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GoogleAccount {
    #[serde(default)]
    label: String,
    #[serde(default)]
    cooldown_until: String,
    #[serde(default)]
    last_status: String,
}

/// The Gemini limit, taken from the account ledger.
///
/// Reported only when EVERY account is cooling: one working account is enough
/// for delegation to keep going, and an alarm the user cannot act on is worse
/// than none. The reset shown is the earliest — that is when service resumes.
fn google_account_limit(runtime_home: &Path, now: i64) -> Option<ProviderLimit> {
    let raw = std::fs::read_to_string(runtime_home.join("google-api-usage.json")).ok()?;
    let parsed: GoogleUsage = serde_json::from_str(&raw).ok()?;
    if parsed.accounts.is_empty() {
        return None;
    }
    let mut earliest: Option<ProviderLimit> = None;
    for account in parsed.accounts.values() {
        let status = account.last_status.to_ascii_lowercase();
        let limited = LIMIT_REASONS.iter().any(|known| status.contains(known));
        let until = parse_unix(&account.cooldown_until).filter(|value| *value > now);
        let (Some(until), true) = (until, limited) else {
            return None; // this account still works, so the provider does too
        };
        let candidate = ProviderLimit {
            model: if account.label.is_empty() {
                "аккаунт Google".to_string()
            } else {
                account.label.clone()
            },
            resets_in_sec: (until - now).max(0) as u64,
            reason: account.last_status.clone(),
        };
        match &earliest {
            Some(current) if current.resets_in_sec <= candidate.resets_in_sec => {}
            _ => earliest = Some(candidate),
        }
    }
    earliest
}

/// Reads the runtime's limit ledgers and reports what is limited right now.
///
/// Returns `(gemini, opencode)`; `None` means that provider is fine.
pub fn read_limits(runtime_home: &Path) -> (Option<ProviderLimit>, Option<ProviderLimit>) {
    let now_for_accounts = unix_now();
    let account_limit = google_account_limit(runtime_home, now_for_accounts);
    let Ok(raw) = std::fs::read_to_string(runtime_home.join("cooldowns.json")) else {
        return (account_limit, None);
    };
    let Ok(parsed) = serde_json::from_str::<CooldownFile>(&raw) else {
        return (account_limit, None);
    };
    let now = unix_now();
    // An account-wide limit outranks a single model's: it is the one that stops
    // every Google call, whatever model the router picks.
    let mut gemini: Option<ProviderLimit> = account_limit;
    let mut opencode: Option<ProviderLimit> = None;
    let gemini_is_account_wide = gemini.is_some();

    for (model, entry) in parsed.models {
        let reason = entry.reason.to_ascii_lowercase();
        let is_limit = LIMIT_REASONS.iter().any(|known| reason.contains(known))
            || entry.last_status == Some(429);
        if !is_limit {
            continue;
        }
        let Some(until) = parse_unix(&entry.until) else {
            continue;
        };
        if until <= now {
            continue; // already expired: the ledger keeps history
        }
        let candidate = ProviderLimit {
            model: model.clone(),
            resets_in_sec: (until - now).max(0) as u64,
            reason: entry.reason.clone(),
        };
        // The EARLIEST reset is what the user is waiting for: one model coming
        // back is enough for delegation to work again.
        if !is_opencode(&model) && gemini_is_account_wide {
            continue; // the account-level outage already says it better
        }
        let slot = if is_opencode(&model) {
            &mut opencode
        } else {
            &mut gemini
        };
        match slot {
            Some(current) if current.resets_in_sec <= candidate.resets_in_sec => {}
            _ => *slot = Some(candidate),
        }
    }
    (gemini, opencode)
}

/// The line shown inside the affected tab.
pub fn limit_line(provider: &str, limit: &ProviderLimit) -> String {
    format!(
        "{provider} сообщает о достижении лимита ({}). Примерно до сброса: {}.",
        limit.model,
        limit.remaining_text()
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(dir: &Path, body: &str) {
        std::fs::write(dir.join("cooldowns.json"), body).expect("write ledger");
    }

    #[test]
    fn remaining_time_reads_the_way_the_owner_asked() {
        assert_eq!(
            format_remaining(3 * 86_400 + 5 * 3_600 + 23 * 60),
            "3д 5ч 23м"
        );
        assert_eq!(format_remaining(5 * 3_600 + 23 * 60), "5ч 23м");
        assert_eq!(format_remaining(23 * 60), "23м");
        // «0м» would look like a bug rather than "almost back".
        assert_eq!(format_remaining(30), "меньше минуты");
    }

    #[test]
    fn parses_the_stamps_powershell_writes() {
        // 2026-08-12T13:32:23Z
        let parsed = parse_unix("2026-08-12T13:32:23Z").expect("parses");
        assert_eq!(parsed, 1_786_541_543);
        assert_eq!(parse_unix("2026-08-12T13:32:23.500Z"), Some(1_786_541_543));
        assert_eq!(parse_unix("2026-08-12T13:32:23+00:00"), Some(1_786_541_543));
        assert_eq!(parse_unix("nonsense"), None);
        assert_eq!(parse_unix("2026-13-12T00:00:00Z"), None);
    }

    #[test]
    fn an_expired_cooldown_is_not_a_limit() {
        let dir = std::env::temp_dir().join(format!("dg-quota-{}", unix_now()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        write(
            &dir,
            r#"{"version":1,"models":{
                 "opencode/big-pickle":{"until":"2020-01-01T00:00:00Z","reason":"rate_limit"}}}"#,
        );
        let (gemini, opencode) = read_limits(&dir);
        assert!(gemini.is_none() && opencode.is_none());
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_live_limit_is_reported_per_provider_with_the_earliest_reset() {
        let dir = std::env::temp_dir().join(format!("dg-quota-live-{}", unix_now()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        write(
            &dir,
            r#"{"version":1,"models":{
                 "opencode/big-pickle":{"until":"2099-01-02T00:00:00Z","reason":"rate_limit"},
                 "opencode/hy3-free":{"until":"2099-01-01T00:00:00Z","reason":"rate_limit"},
                 "gemini-pro-latest":{"until":"2099-06-01T00:00:00Z","reason":"quota","lastStatus":429},
                 "gemini-flash-latest":{"until":"2099-06-01T00:00:00Z","reason":"timeout"}}}"#,
        );
        let (gemini, opencode) = read_limits(&dir);
        let opencode = opencode.expect("opencode limited");
        // The earliest reset wins: one model back is enough to keep working.
        assert_eq!(opencode.model, "opencode/hy3-free");
        let gemini = gemini.expect("gemini limited");
        assert_eq!(gemini.model, "gemini-pro-latest");
        // A timeout is a misbehaving model, not an exhausted quota.
        assert!(!gemini.remaining_text().is_empty());
        assert!(limit_line("OpenCode", &opencode).contains("до сброса"));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_timezone_offset_is_applied_not_ignored() {
        // The Google ledger writes local time with an offset; treating it as UTC
        // put the reset three hours into the future.
        let utc = parse_unix("2026-08-13T10:19:15Z").expect("utc");
        let local = parse_unix("2026-08-13T13:19:15.6324333+03:00").expect("offset");
        assert_eq!(utc, local);
        assert_eq!(parse_unix("2026-08-13T07:19:15-03:00"), Some(utc));
        assert_eq!(parse_unix("2026-08-13T13:19:15+0300"), Some(utc));
    }

    #[test]
    fn every_google_account_must_be_cooling_before_it_counts_as_a_limit() {
        let dir = std::env::temp_dir().join(format!("dg-quota-acct-{}", unix_now()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        let both = r#"{"version":1,"accounts":{
             "a":{"label":"Account 1","cooldownUntil":"2099-01-01T00:00:00Z",
                  "lastStatus":"quota_or_rate_limited"},
             "b":{"label":"Account 2","cooldownUntil":"2099-01-02T00:00:00Z",
                  "lastStatus":"quota_or_rate_limited"}}}"#;
        std::fs::write(dir.join("google-api-usage.json"), both).expect("write");
        let (gemini, _) = read_limits(&dir);
        let gemini = gemini.expect("both accounts cooling");
        // The EARLIEST reset is when service resumes.
        assert_eq!(gemini.model, "Account 1");

        // One healthy account means delegation still works: no alarm.
        let one_ok = r#"{"version":1,"accounts":{
             "a":{"label":"Account 1","cooldownUntil":"2099-01-01T00:00:00Z",
                  "lastStatus":"quota_or_rate_limited"},
             "b":{"label":"Account 2","cooldownUntil":"","lastStatus":"ok"}}}"#;
        std::fs::write(dir.join("google-api-usage.json"), one_ok).expect("write");
        assert!(read_limits(&dir).0.is_none());
        std::fs::remove_dir_all(&dir).ok();
    }

    /// Reads the REAL ledgers on this machine. Ignored in CI (there are none
    /// there); run with `cargo test -- --ignored` to see what the tab will show.
    #[test]
    #[ignore]
    fn shows_what_this_machine_reports_right_now() {
        let home = crate::config::runtime_home_dir();
        let (gemini, opencode) = read_limits(&home);
        println!("runtime: {}", home.display());
        match &gemini {
            Some(limit) => println!("GEMINI: {}", limit_line("Google AI Studio", limit)),
            None => println!("GEMINI: лимита нет"),
        }
        match &opencode {
            Some(limit) => println!("OPENCODE: {}", limit_line("OpenCode", limit)),
            None => println!("OPENCODE: лимита нет"),
        }
    }

    #[test]
    fn a_missing_or_broken_ledger_never_raises_an_alarm() {
        let dir = std::env::temp_dir().join(format!("dg-quota-bad-{}", unix_now()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        assert_eq!(read_limits(&dir), (None, None));
        write(&dir, "{ this is not json");
        assert_eq!(read_limits(&dir), (None, None));
        std::fs::remove_dir_all(&dir).ok();
    }
}
