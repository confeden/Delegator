//! What a provider says about its own models, asked with a real request.
//!
//! A provider's `GET /models` is not an answer to "is this free on MY key".
//! Measured on b.ai: the listing carries 48 models and no prices, and exactly
//! four of them answer on a deposit-free key. A hand-written allowlist is a
//! guess about someone else's pricing and it rots — free-router's own list for
//! the same provider still names `deepseek-v4-flash`, which today replies
//! `balance=0`. A quota figure from the provider is that provider stating its
//! own terms, so one small request settles what no listing can.
//!
//! Two rules make this safe to automate:
//!
//! * **A verdict may only REMOVE.** I8 says the GUI selection is the mandatory
//!   allowlist; nothing here ever ticks a box. `Paid`/`Absent` drop a model from
//!   the pool, `Free` merely confirms what the user already enabled.
//! * **Silence is not a verdict.** A timeout, a 5xx, a 401 or a 429 says
//!   nothing about the model — only about the key, the quota or the transport.
//!   Recording those as "not free" is how one dead proxy retires a whole
//!   provider (G98 is the same failure one layer down).

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

/// How long a negative verdict stands before the model is asked again. A plan
/// changes, a promotion starts, a provider fixes a misconfiguration — none of
/// which anyone tells us about, so "not free" has to expire. "Free" does not:
/// ordinary traffic revisits it constantly and a later refusal replaces it.
pub const NEGATIVE_VERDICT_TTL_SECS: u64 = 48 * 60 * 60;

/// Probes per refresh, per provider. A probe spends the provider's quota and
/// saves nothing (I11), so the cost has to be bounded and paid once per model
/// rather than once per run — which is what caching the verdict achieves.
pub const MAX_PROBES_PER_RUN: usize = 8;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Verdict {
    /// Served on this key, right now.
    Free,
    /// Refused for money: no free allowance, or the balance is spent.
    Paid,
    /// Not served at all — withdrawn, or never a chat model.
    Absent,
}

impl Verdict {
    /// Whether a model carrying this verdict may still reach the pool.
    pub fn usable(self) -> bool {
        matches!(self, Verdict::Free)
    }

    /// Short Russian label for the models list.
    pub fn label(self) -> &'static str {
        match self {
            Verdict::Free => "бесплатна",
            Verdict::Paid => "нужен депозит или баланс",
            Verdict::Absent => "провайдер её не отдаёт",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelVerdict {
    pub verdict: Verdict,
    /// HTTP status that produced it, for the tooltip and for debugging a
    /// verdict that looks wrong.
    #[serde(default)]
    pub status: u16,
    /// The provider's own wording, trimmed. Quoting it is the difference
    /// between "нужен депозит" and a guess.
    #[serde(default)]
    pub reason: String,
    pub checked_at: u64,
    /// Unix seconds after which the verdict must be re-asked. `None` = never
    /// expires, which only `Free` ever gets.
    #[serde(default)]
    pub expires_at: Option<u64>,
}

impl ModelVerdict {
    pub fn is_live(&self, now: u64) -> bool {
        match self.expires_at {
            Some(expiry) => now < expiry,
            None => true,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VerdictStore {
    #[serde(default = "default_version")]
    pub version: u32,
    /// provider id → model id → verdict.
    #[serde(default)]
    pub providers: HashMap<String, HashMap<String, ModelVerdict>>,
}

/// Hand-written rather than derived: `#[serde(default = ...)]` only fills a
/// field MISSING from the json, so a derived `Default` gave `version: 0` and any
/// store built that way was saved claiming version 0. Found by round-tripping
/// the file through the PowerShell reader, which is the only place the two
/// processes actually meet.
impl Default for VerdictStore {
    fn default() -> Self {
        Self {
            version: STORE_VERSION,
            providers: HashMap::new(),
        }
    }
}

/// Bumped only when the on-disk shape changes in a way the runtime reader
/// (`Get-ProviderVerdicts`) has to know about.
pub const STORE_VERSION: u32 = 1;

fn default_version() -> u32 {
    STORE_VERSION
}

impl VerdictStore {
    pub fn path(runtime_home: &Path) -> PathBuf {
        runtime_home.join("provider-verdicts.json")
    }

    /// Never fails: a missing or corrupt file is an empty store, because the
    /// only thing it can do is fail to remove a model, and the allowlist is
    /// still the user's.
    pub fn load(runtime_home: &Path) -> Self {
        let path = Self::path(runtime_home);
        let Ok(text) = fs::read_to_string(&path) else {
            return Self::default();
        };
        serde_json::from_str(&text).unwrap_or_default()
    }

    pub fn save(&self, runtime_home: &Path) {
        let path = Self::path(runtime_home);
        if let Some(parent) = path.parent() {
            let _ = fs::create_dir_all(parent);
        }
        let Ok(text) = serde_json::to_string_pretty(self) else {
            return;
        };
        // Same write-then-rename as the config: a torn verdict file read back
        // as garbage would silently drop every model of every provider.
        let tmp = path.with_extension("json.tmp");
        if fs::write(&tmp, text).is_ok() {
            let _ = fs::remove_file(&path);
            if fs::rename(&tmp, &path).is_err() {
                let _ = fs::remove_file(&tmp);
            }
        }
    }

    pub fn get(&self, provider_id: &str, model: &str, now: u64) -> Option<&ModelVerdict> {
        self.providers
            .get(provider_id)
            .and_then(|models| models.get(model))
            .filter(|verdict| verdict.is_live(now))
    }

    pub fn record(
        &mut self,
        provider_id: &str,
        model: &str,
        verdict: Verdict,
        status: u16,
        reason: String,
        now: u64,
    ) {
        let expires_at = match verdict {
            Verdict::Free => None,
            Verdict::Paid | Verdict::Absent => Some(now + NEGATIVE_VERDICT_TTL_SECS),
        };
        self.providers
            .entry(provider_id.to_string())
            .or_default()
            .insert(
                model.to_string(),
                ModelVerdict {
                    verdict,
                    status,
                    reason: trim_reason(&reason),
                    checked_at: now,
                    expires_at,
                },
            );
    }

    /// Which of `candidates` still needs asking: no verdict, or one that has
    /// expired. Capped at `MAX_PROBES_PER_RUN` — the rest wait for tomorrow,
    /// which is why a verdict is cached rather than re-measured per run.
    pub fn models_needing_probe(
        &self,
        provider_id: &str,
        candidates: &[String],
        now: u64,
    ) -> Vec<String> {
        candidates
            .iter()
            .filter(|model| self.get(provider_id, model, now).is_none())
            .take(MAX_PROBES_PER_RUN)
            .cloned()
            .collect()
    }

    /// Drops verdicts for providers that no longer exist, so a removed and
    /// re-added provider starts from an honest blank rather than from what its
    /// predecessor's key could reach.
    pub fn retain_providers(&mut self, live: &[String]) {
        self.providers
            .retain(|provider_id, _| live.iter().any(|id| id == provider_id));
    }
}

/// One line of the provider's own wording, short enough for a tooltip.
fn trim_reason(reason: &str) -> String {
    let single_line: String = reason
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect();
    let squeezed = single_line.split_whitespace().collect::<Vec<_>>().join(" ");
    if squeezed.chars().count() <= 180 {
        return squeezed;
    }
    squeezed.chars().take(177).collect::<String>() + "..."
}

/// Turns one probe outcome into a verdict, or into nothing.
///
/// `status` is the HTTP status; `body` the response text. The mapping is the
/// one b.ai demonstrated live, and the `None` arms are the important half:
///
/// | answer | meaning | verdict |
/// |---|---|---|
/// | 200 | served on this key | `Free` |
/// | 402/403 | gated behind a deposit | `Paid` |
/// | 400 + insufficient balance/quota | metered, balance spent | `Paid` |
/// | 400, anything else | a malformed request of ours | none |
/// | 404 | not served, or withdrawn | `Absent` |
/// | 401 | the KEY is wrong — says nothing about the model | none |
/// | 429 | spent for now — it exists and it is allowed | none |
/// | 5xx, timeout | says nothing | none |
pub fn classify_probe(status: u16, body: &str) -> Option<(Verdict, String)> {
    let lower = body.to_lowercase();
    match status {
        200 => Some((Verdict::Free, String::new())),
        402 | 403 => Some((Verdict::Paid, provider_message(body))),
        400 => {
            // A 400 is usually OUR fault (a body the provider dislikes), so it
            // only becomes a verdict when the provider names money.
            if lower.contains("insufficient")
                || lower.contains("balance")
                || lower.contains("quota")
                || lower.contains("credit")
            {
                Some((Verdict::Paid, provider_message(body)))
            } else {
                None
            }
        }
        404 => Some((Verdict::Absent, provider_message(body))),
        _ => None,
    }
}

/// The provider's `error.message` when the body is the usual OpenAI shape,
/// else the raw body. Quoting the provider is what makes a verdict checkable.
fn provider_message(body: &str) -> String {
    if let Ok(value) = serde_json::from_str::<serde_json::Value>(body) {
        if let Some(message) = value
            .get("error")
            .and_then(|error| error.get("message"))
            .and_then(|message| message.as_str())
        {
            return message.to_string();
        }
    }
    body.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    const BAI_DEPOSIT: &str = r#"{"error":{"code":"access_denied","message":"Access restricted. Deposit required to unlock premium models. (request id: 2026)","type":"api_error"}}"#;
    const BAI_BALANCE: &str = r#"{"error":{"message":"credit insufficient balance: balance=0 required=8 (request id: 2026)","type":"api_error","param":"","code":"insufficient_user_quota"}}"#;

    #[test]
    fn the_two_refusals_b_ai_actually_sends_are_both_paid() {
        // Measured on a real deposit-free key: premium models answer 403
        // access_denied, metered ones answer 400 with balance=0. Different
        // shapes, same consequence — neither will ever serve for free.
        let (verdict, reason) = classify_probe(403, BAI_DEPOSIT).expect("403 is a verdict");
        assert_eq!(verdict, Verdict::Paid);
        assert!(reason.contains("Deposit required"), "{reason}");

        let (verdict, reason) = classify_probe(400, BAI_BALANCE).expect("400+balance is a verdict");
        assert_eq!(verdict, Verdict::Paid);
        assert!(reason.contains("balance=0"), "{reason}");

        assert_eq!(classify_probe(200, "{}").expect("200").0, Verdict::Free);
        assert_eq!(classify_probe(404, "{}").expect("404").0, Verdict::Absent);
    }

    #[test]
    fn silence_is_not_a_verdict() {
        // Each of these says something about the key, the quota or the wire —
        // nothing about the model. Recording them would let one bad key or one
        // dead proxy retire every model of a provider, and `Paid` expires in
        // 48 h while the user's list looks broken the whole time.
        for (status, body) in [
            (401u16, r#"{"error":{"message":"invalid api key"}}"#),
            (429, r#"{"error":{"message":"rate limit"}}"#),
            (500, "upstream exploded"),
            (502, ""),
            (0, "connection was closed unexpectedly"),
            (
                400,
                r#"{"error":{"message":"messages[0] must be an object"}}"#,
            ),
        ] {
            assert!(
                classify_probe(status, body).is_none(),
                "{status} must not produce a verdict"
            );
        }
    }

    #[test]
    fn a_negative_verdict_expires_and_a_positive_one_does_not() {
        let mut store = VerdictStore::default();
        let now = 1_000_000u64;
        store.record("bai", "hy3", Verdict::Free, 200, String::new(), now);
        store.record("bai", "glm-5.3", Verdict::Paid, 403, "deposit".into(), now);

        assert!(store.get("bai", "hy3", now).is_some());
        assert!(store
            .get("bai", "hy3", now + 10 * NEGATIVE_VERDICT_TTL_SECS)
            .is_some());

        assert!(store.get("bai", "glm-5.3", now).is_some());
        assert!(store
            .get("bai", "glm-5.3", now + NEGATIVE_VERDICT_TTL_SECS)
            .is_none());
    }

    #[test]
    fn only_unanswered_models_are_probed_and_never_more_than_the_cap() {
        let mut store = VerdictStore::default();
        let now = 1_000u64;
        store.record("bai", "hy3", Verdict::Free, 200, String::new(), now);
        store.record("bai", "old", Verdict::Paid, 403, String::new(), now);

        let candidates: Vec<String> = std::iter::once("hy3".to_string())
            .chain(std::iter::once("old".to_string()))
            .chain((0..20).map(|i| format!("m{i}")))
            .collect();

        let fresh = store.models_needing_probe("bai", &candidates, now);
        assert_eq!(fresh.len(), MAX_PROBES_PER_RUN);
        assert!(!fresh.contains(&"hy3".to_string()));
        assert!(!fresh.contains(&"old".to_string()));

        // Once the negative verdict expires the model is asked again.
        let later = now + NEGATIVE_VERDICT_TTL_SECS;
        assert!(store
            .models_needing_probe("bai", &candidates, later)
            .contains(&"old".to_string()));
    }

    #[test]
    fn the_cap_is_spent_in_the_order_it_is_given() {
        // `models_needing_probe` keeps the caller's order and takes the first N,
        // which is what lets the round put ENABLED models first. Measured on the
        // first live round: the provider's listing order put unknown premium
        // models first, the cap ate all eight, and the four the user had ticked
        // went unasked — the only four whose verdict costs a delegation.
        let store = VerdictStore::default();
        let enabled = ["hy3", "mimo-v2.5", "glm-5.3-flash", "qwen3.8-flash"];
        let candidates: Vec<String> = enabled
            .iter()
            .map(|model| model.to_string())
            .chain((0..40).map(|i| format!("premium-{i}")))
            .collect();

        let picked = store.models_needing_probe("bai", &candidates, 0);
        assert_eq!(picked.len(), MAX_PROBES_PER_RUN);
        for model in enabled {
            assert!(
                picked.contains(&model.to_string()),
                "{model} was enabled and must be asked in the first round"
            );
        }
    }

    #[test]
    fn a_removed_provider_takes_its_verdicts_with_it() {
        // Re-adding a provider with a different key must not inherit what the
        // previous key could reach.
        let mut store = VerdictStore::default();
        store.record("bai", "hy3", Verdict::Free, 200, String::new(), 1);
        store.record("gone", "x", Verdict::Free, 200, String::new(), 1);
        store.retain_providers(&["bai".to_string()]);
        assert!(store.providers.contains_key("bai"));
        assert!(!store.providers.contains_key("gone"));
    }

    #[test]
    fn a_corrupt_or_missing_store_is_empty_and_removes_nothing() {
        let dir =
            std::env::temp_dir().join(format!("delegator-verdicts-{}", crate::config::unix_now()));
        fs::create_dir_all(&dir).expect("temp dir");
        assert!(VerdictStore::load(&dir).providers.is_empty());

        fs::write(VerdictStore::path(&dir), "{not json").expect("write");
        assert!(VerdictStore::load(&dir).providers.is_empty());

        let mut store = VerdictStore::default();
        store.record("bai", "hy3", Verdict::Free, 200, "ok".into(), 5);
        store.save(&dir);
        let reloaded = VerdictStore::load(&dir);
        assert_eq!(
            reloaded.get("bai", "hy3", 5).map(|v| v.verdict),
            Some(Verdict::Free)
        );
        // The stamp the runtime reader keys off must survive a save, and a
        // DERIVED Default wrote 0 here.
        assert_eq!(reloaded.version, STORE_VERSION);
        assert_eq!(VerdictStore::default().version, STORE_VERSION);

        let _ = fs::remove_dir_all(&dir);
    }

    /// Writes a store the PowerShell runtime then reads, so the two processes
    /// are checked against the same bytes rather than against each other's
    /// documentation (I1). Ignored because it is half of a two-process check —
    /// `tests/ps` cannot run Rust and `cargo` cannot run the runtime.
    ///
    /// ```text
    /// $env:DELEGATOR_VERDICT_FIXTURE_DIR = "$env:TEMP\dg-verdicts"
    /// cargo test --offline live_verdict_store_round_trip -- --ignored --nocapture
    /// powershell -File <the reader shown in kb/environment.md>
    /// ```
    #[test]
    #[ignore]
    fn live_verdict_store_round_trip() {
        let Ok(dir) = std::env::var("DELEGATOR_VERDICT_FIXTURE_DIR") else {
            println!("DELEGATOR_VERDICT_FIXTURE_DIR is not set; nothing written");
            return;
        };
        let dir = std::path::PathBuf::from(dir);
        fs::create_dir_all(&dir).expect("fixture dir");

        let now = crate::config::unix_now();
        let mut store = VerdictStore::default();
        store.record("bai", "hy3", Verdict::Free, 200, String::new(), now);
        store.record(
            "bai",
            "glm-5.3",
            Verdict::Paid,
            403,
            "Access restricted. Deposit required to unlock premium models.".into(),
            now,
        );
        store.record(
            "bai",
            "withdrawn",
            Verdict::Absent,
            404,
            "no such model".into(),
            now,
        );
        // Already expired: the runtime must ignore it, exactly as `get` does.
        store.providers.get_mut("bai").expect("provider").insert(
            "stale".to_string(),
            ModelVerdict {
                verdict: Verdict::Paid,
                status: 403,
                reason: "old".into(),
                checked_at: now - 10 * NEGATIVE_VERDICT_TTL_SECS,
                expires_at: Some(now - NEGATIVE_VERDICT_TTL_SECS),
            },
        );
        store.save(&dir);
        println!("wrote {}", VerdictStore::path(&dir).display());
    }

    #[test]
    fn the_providers_own_wording_survives_into_the_tooltip() {
        let mut store = VerdictStore::default();
        store.record(
            "bai",
            "m",
            Verdict::Paid,
            403,
            "line one\nline two\t  spaced".into(),
            1,
        );
        let stored = store.get("bai", "m", 1).expect("verdict");
        assert_eq!(stored.reason, "line one line two spaced");
        assert_eq!(stored.status, 403);

        store.record("bai", "long", Verdict::Paid, 403, "x".repeat(400), 1);
        assert_eq!(
            store
                .get("bai", "long", 1)
                .expect("verdict")
                .reason
                .chars()
                .count(),
            180
        );
    }
}
