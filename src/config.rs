use crate::crypto::{decrypt_string, encrypt_string};
#[cfg(not(target_os = "macos"))]
use directories::ProjectDirs;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard, PoisonError};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GoogleApiAccount {
    pub id: String,
    pub label: String,
    pub api_key_enc: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OpenCodeApiAccount {
    pub id: String,
    pub label: String,
    pub api_key_enc: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
}

/// One API key of a user-added provider. Field-for-field identical to
/// `GoogleApiAccount` / `OpenCodeApiAccount` on purpose rather than shared with
/// them: those two are already serialized in every installed `config.json`, and
/// retyping a live field is a migration risk paid for nothing (I14 — the
/// duplication here is deliberate, and all three shapes must stay identical).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderApiAccount {
    pub id: String,
    pub label: String,
    pub api_key_enc: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
}

/// One user-added OpenAI-compatible provider (b.ai, TokenRouter, …).
///
/// Its models are addressed `<provider id>/<model>` everywhere — pool,
/// allowlist, catalog, cooldowns — exactly like `openrouter/*`, so the runtime
/// splits on the first `/` and needs no per-provider branch. `enabled_models`
/// is a MANDATORY allowlist (I8): catalog discovery may add ids to
/// `known_models`, never to `enabled_models`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CustomProvider {
    /// Lowercase slug; doubles as the model-id prefix, so it may not contain
    /// `/` or whitespace.
    pub id: String,
    #[serde(default)]
    pub label: String,
    /// OpenAI-compatible root, e.g. `https://api.b.ai/v1`. `/chat/completions`
    /// and `/models` are appended by the runtime.
    #[serde(default)]
    pub base_url: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default)]
    pub accounts: Vec<ProviderApiAccount>,
    #[serde(default)]
    pub enabled_models: Vec<String>,
    /// Every model id this provider's catalog has ever shown, so a brand-new
    /// upstream model can be told from one the user deliberately switched off.
    #[serde(default)]
    pub known_models: Vec<String>,
}

impl CustomProvider {
    /// Switched on and holding at least one enabled key: the only provider
    /// worth a model in the pool or a request in the daily round.
    pub fn has_usable_key(&self) -> bool {
        self.enabled && self.accounts.iter().any(|account| account.enabled)
    }
}

/// A provider the GUI can offer with one click: the user pastes a key and the
/// candidate models are already there. `models` is a STARTING GUESS, not a
/// promise — a provider's `/models` listing carries no prices, so what a given
/// key actually serves is settled by the catalog refresh, not by this table.
///
/// `models` lists the FREE ones first (the first `free_count`), then the paid
/// ones. Adding a preset enables only the free ones; the rest are ticked by hand.
pub struct ProviderPreset {
    pub id: &'static str,
    pub label: &'static str,
    pub base_url: &'static str,
    pub free_count: usize,
    /// Enabled when the preset is added: the owner's pick (free ones included).
    pub default_count: usize,
    pub models: &'static [&'static str],
}

impl ProviderPreset {
    pub fn free_models(&self) -> &'static [&'static str] {
        &self.models[..self.free_count]
    }

    pub fn default_models(&self) -> &'static [&'static str] {
        &self.models[..self.default_count]
    }
}

/// Presets shown on the «API» tab under «+ Добавить провайдера». The six
/// providers that used to live in OpenCode are presets of their own, labelled the
/// way their sites are written. The model lists follow the live `/models`
/// listings read in October 2026; a listing is not a verdict, and a model the
/// key cannot run is refused by the provider and marked by the daily probe.
pub const PROVIDER_PRESETS: &[ProviderPreset] = &[
    ProviderPreset {
        id: "opencodeai",
        label: "OpenCode.ai",
        base_url: "https://opencode.ai/zen/v1",
        free_count: 9,
        default_count: 9,
        models: &[
            "big-pickle",
            "beam-free",
            "flint-40b-free",
            "mimo-v2.6-flash-free",
            "nemotron-3.5-super-vl-free",
            "nemotron-3.5-lightning-free",
            "jev-1.13-free",
            "deepseek-v4.1-flash-free",
            "glm-5.3-flash-free",
            "claude-opus-5-5",
            "claude-sonnet-5-5",
            "claude-haiku-5-5",
            "claude-fable-5-1",
            "gpt-5.5",
            "gpt-6.1-sol",
            "gpt-6-astra",
            "gemini-3.8-flash",
            "glm-5.3",
            "kimi-k3",
            "deepseek-v4-pro",
            "minimax-m3",
            "grok-4.7",
            "qwen3.8-flash",
        ],
    },
    ProviderPreset {
        id: "openrouter",
        label: "OpenRouter.ai",
        base_url: "https://openrouter.ai/api/v1",
        free_count: 9,
        default_count: 9,
        models: &[
            "openrouter/free",
            "nvidia/nemotron-3-ultra-550b-a55b:free",
            "nvidia/nemotron-3-super-120b-a12b:free",
            "google/gemma-4-31b-it:free",
            "google/gemma-4-26b-a4b-it:free",
            "nvidia/nemotron-3.5-lightning:free",
            "nvidia/nemotron-3.5-super-vl:free",
            "poolside/laguna-s-2.1:free",
            "thinkingmachines/inkling:free",
            "anthropic/claude-opus-5.5",
            "anthropic/claude-sonnet-5.5",
            "openai/gpt-6.1-sol",
            "openai/gpt-6-astra",
            "google/gemini-3.8-flash",
            "z-ai/glm-5.3",
            "deepseek/deepseek-v4-pro",
            "moonshotai/kimi-k3.1-pro",
        ],
    },
    ProviderPreset {
        id: "bai",
        label: "B.AI",
        base_url: "https://api.b.ai/v1",
        free_count: 4,
        default_count: 4,
        models: &[
            "hy3",
            "mimo-v2.5",
            "glm-5.3-flash",
            "qwen3.8-flash",
            "claude-opus-5.5",
            "claude-sonnet-5.5",
            "gpt-5.6-sol",
            "gemini-3.8-flash",
            "kimi-k3",
            "glm-5.3",
            "deepseek-v4-pro",
        ],
    },
    ProviderPreset {
        id: "groq",
        label: "Groq.com",
        base_url: "https://api.groq.com/openai/v1",
        free_count: 4,
        default_count: 4,
        models: &[
            "qwen/qwen3.8-27b",
            "openai/gpt-oss-120b",
            "openai/gpt-oss-20b",
            "allam-2-7b",
        ],
    },
    ProviderPreset {
        id: "orcarouter",
        label: "OrcaRouter.ai",
        base_url: "https://api.orcarouter.ai/v1",
        free_count: 7,
        default_count: 41,
        models: &[
            "orcarouter/free",
            "deepseek/deepseek-v4-flash-free",
            "deepseek/deepseek-v4.1-flash-free",
            "tencent/hy3-free",
            "z-ai/glm-5.3-flash-free",
            "tencent/hy4-preview-free",
            "orca/orcaverify-text1.0-free",
            "anthropic/claude-fable-5",
            "anthropic/claude-opus-4.8",
            "anthropic/claude-opus-5",
            "anthropic/claude-sonnet-5",
            "deepseek/deepseek-v4-flash-0731",
            "deepseek/deepseek-v4-flash-vision-exp",
            "deepseek/deepseek-v4-pro-0813",
            "google/gemini-3.1-flash-lite",
            "kimi/kimi-k2.7-code",
            "kimi/kimi-k3",
            "meta/muse-spark-1.1",
            "meta/muse-spark-1.2",
            "minimax/minimax-m3",
            "openai/gpt-5.6-luna",
            "openai/gpt-5.6-sol",
            "openai/gpt-5.6-terra",
            "orcarouter/fusion",
            "orcarouter/fusion-flash",
            "orcarouter/fusion-mini",
            "qwen/qwen3.5-flash",
            "qwen/qwen3.6-flash",
            "qwen/qwen3.7-flash",
            "qwen/qwen3.7-max",
            "qwen/qwen3.7-plus",
            "qwen/qwen3.8-27b",
            "qwen/qwen3.8-max",
            "tencent/hy3",
            "z-ai/glm-5.2",
            "z-ai/glm-5.3",
            "z-ai/glm-5.3-flash",
            "google/gemini-flash-lite-latest",
            "google/gemini-flash-latest",
            "google/gemma-4-31b-it",
            "minimax/minimax-m2.7-highspeed",
        ],
    },
    ProviderPreset {
        id: "tokenharbor",
        label: "TokenHarbor.ai",
        base_url: "https://tokenharbor.ai/v1",
        free_count: 6,
        default_count: 6,
        models: &[
            "mimo-v2.5:free",
            "deepseek-v4-flash:free",
            "deepseek-v4.1-flash:free",
            "mimo-v2.6-flash:free",
            "deepseek-v4.1-flash",
            "mimo-v2.6-flash",
            "claude-haiku-5.5",
            "claude-opus-5.5",
            "claude-sonnet-5.5",
            "gpt-6.1-sol",
            "gemini-3.8-flash",
            "glm-5.3",
            "qwen3.8-flash",
        ],
    },
    ProviderPreset {
        id: "agentrouter",
        label: "AgentRouter.org",
        base_url: "https://agentrouter.org/v1",
        free_count: 0,
        default_count: 0,
        models: &[
            "claude-opus-5",
            "gpt-5.6-sol",
            "deepseek-v4-flash",
            "glm-5.3",
        ],
    },
    ProviderPreset {
        id: "aerolink",
        label: "AeroLink.lat",
        base_url: "https://api.aerolink.lat/v1",
        free_count: 0,
        default_count: 0,
        models: &["claude-opus-5", "claude-sonnet-5"],
    },
    ProviderPreset {
        id: "huggingface",
        label: "HuggingFace.co",
        base_url: "https://router.huggingface.co/v1",
        free_count: 0,
        default_count: 0,
        models: &[
            "deepseek-ai/DeepSeek-V4-Pro",
            "moonshotai/Kimi-K3",
            "zai-org/GLM-5.3",
        ],
    },
    ProviderPreset {
        id: "tokenrouter",
        label: "TokenRouter",
        base_url: "https://api.tokenrouter.com/v1",
        free_count: 1,
        default_count: 1,
        models: &["z-ai/glm-5.3-free"],
    },
];

/// Whether a model is free on its provider. A preset's own list decides (its
/// first `free_count` entries); a provider the user added by hand is judged by
/// the word «free» in its id, which is how every free route names itself.
pub fn is_free_model(provider_id: &str, model: &str) -> bool {
    match PROVIDER_PRESETS
        .iter()
        .find(|preset| preset.id == provider_id)
    {
        Some(preset) => preset.free_models().contains(&model),
        None => model.to_ascii_lowercase().contains("free"),
    }
}

/// True when `id` is usable as a model-id prefix: lowercase alphanumerics,
/// `-`, `_` and `.`, and never empty. Anything else would either collide with
/// the `<provider>/<model>` split or land in a cooldown key the runtime cannot
/// round-trip.
pub fn is_valid_provider_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 32
        && id
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, '-' | '_' | '.'))
}

fn default_true() -> bool {
    true
}

/// One user-configured outbound proxy (DEV_CONTRACTS §7a). The PowerShell
/// runtime reads this list from config.json and applies rule 2 of the
/// contract per provider; the GUI mirrors the same rule for status display
/// and the «Проверить» connectivity test.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProxyEntry {
    pub id: String,
    #[serde(default)]
    pub label: String,
    #[serde(default)]
    pub url: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default = "default_true")]
    pub use_for_gemini: bool,
    #[serde(default = "default_true")]
    pub use_for_opencode: bool,
}

/// How often the GUI may run `opencode upgrade` in the background.
pub const OPENCODE_UPGRADE_INTERVAL_SECS: u64 = 24 * 60 * 60;

/// How often the GUI re-asks every user-added provider what it serves
/// (DEV_CONTRACTS §12a). A day, because that is the granularity at which a
/// free tier actually changes — and because nothing refreshed these catalogs
/// on a schedule before, so a listing could sit stale for as long as the app
/// went unopened.
pub const PROVIDER_CATALOG_INTERVAL_SECS: u64 = 24 * 60 * 60;

/// Unix seconds → `YYYY-MM-DDTHH:MM:SSZ`.
///
/// Hand-rolled on purpose: this crate carries no date dependency (the quota
/// ledger parsing is hand-rolled for the same reason), and one timestamp is not
/// worth one. Civil-from-days is Howard Hinnant's algorithm, valid for any date
/// after 1970 — the only range that can occur here.
pub fn unix_to_iso8601(seconds: u64) -> String {
    let days = (seconds / 86_400) as i64;
    let time_of_day = seconds % 86_400;
    // Shift the epoch to 0000-03-01 so leap days land at the end of the cycle.
    let shifted = days + 719_468;
    let era = shifted.div_euclid(146_097);
    let day_of_era = shifted.rem_euclid(146_097);
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let shifted_month = (5 * day_of_year + 2) / 153;
    let day = (day_of_year - (153 * shifted_month + 2) / 5 + 1) as u32;
    let month = if shifted_month < 10 {
        shifted_month + 3
    } else {
        shifted_month - 9
    } as u32;
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        time_of_day / 3_600,
        (time_of_day % 3_600) / 60,
        time_of_day % 60
    )
}

/// Current wall clock in unix seconds (0 if the clock predates the epoch).
pub fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs())
        .unwrap_or(0)
}

/// Schemes both the GUI test button and the PowerShell runtime support
/// (http/https natively, socks5/socks5h via curl.exe on the runtime side).
pub const SUPPORTED_PROXY_SCHEMES: [&str; 4] = ["http://", "https://", "socks5://", "socks5h://"];

/// True when the url starts with a supported scheme and has a host part.
pub fn is_supported_proxy_url(url: &str) -> bool {
    let lower = url.trim().to_ascii_lowercase();
    SUPPORTED_PROXY_SCHEMES
        .iter()
        .any(|scheme| lower.starts_with(scheme) && lower.len() > scheme.len())
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppConfig {
    #[serde(default)]
    pub config_version: u32,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub google_api_key_enc: String,
    #[serde(default)]
    pub google_accounts: Vec<GoogleApiAccount>,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub opencode_api_key_enc: String,
    #[serde(default)]
    pub opencode_accounts: Vec<OpenCodeApiAccount>,
    #[serde(default = "default_gemini_models")]
    pub enabled_gemini_models: Vec<String>,
    #[serde(default = "default_opencode_models")]
    pub enabled_opencode_models: Vec<String>,
    /// Every `opencode/*` Zen id — and every model of a provider the user added
    /// to their own OpenCode config — that the app has ever seen, enabled or
    /// not. Lets catalog sync distinguish "new upstream model" (auto-enable)
    /// from "model the user deliberately disabled" (leave alone). Never holds
    /// `openrouter/*`: that catalog is 335 models we do not track.
    #[serde(default)]
    pub known_opencode_models: Vec<String>,
    /// User-added OpenAI-compatible providers (config v13). Google and
    /// OpenRouter keep their own fields above: Google is not OpenAI-compatible
    /// (`generateContent`), and the OpenRouter key also authorises the OpenCode
    /// CLI, so neither can be folded in without moving a live DPAPI blob (I19).
    /// The «API» tab presents all four the same way regardless.
    #[serde(default)]
    pub custom_providers: Vec<CustomProvider>,
    /// Outbound proxies (DEV_CONTRACTS §7a). Always serialized — the mere
    /// presence of the key (even `[]`) makes it authoritative for the
    /// runtime, which then stops consulting the legacy `<RT>\proxy.json`.
    #[serde(default)]
    pub proxies: Vec<ProxyEntry>,
    /// Unix seconds of the last automatic `opencode upgrade` attempt
    /// (0 = never). Keeps the background CLI update to once per 24 h.
    #[serde(default)]
    pub opencode_upgrade_checked_at: u64,
    /// Unix seconds of the last provider catalog refresh + probe round
    /// (0 = never).
    #[serde(default)]
    pub provider_catalog_refreshed_at: u64,
    #[serde(default = "default_ide_states")]
    pub ide_states: HashMap<String, bool>,
    #[serde(default = "default_true")]
    pub delegator_enabled: bool,
    /// «Gemini Web (через Chrome)»: the Chrome extension opens a hidden Gemini
    /// window and the Core routes `gemini-web/*` chats through it. Off by
    /// default: it is the only path that uses a browser session, not a key.
    #[serde(default)]
    pub gemini_web_enabled: bool,
    /// Which model of the Gemini web chat answers: `best` (the newest one in
    /// the page's own menu), or one of `argon`, `3.1-pro`, `3.8-flash`,
    /// `3.5-flash-lite`. The Core and the Chrome extension read the same word.
    #[serde(default = "default_web_best")]
    pub gemini_web_model: String,
    /// Reasoning level in that chat: `best` (the highest the page offers),
    /// `high`, `medium`, `low`, or `auto` (leave the page's default).
    #[serde(default = "default_web_best")]
    pub gemini_web_reasoning: String,
    /// The other web doors, one per site (`delegator_core/providers/web_doors.py`). The same extension
    /// opens each site on demand. Off until the user asks: the text of a task goes to that site.
    #[serde(default)]
    pub aistudio_web_enabled: bool,
    #[serde(default)]
    pub kimi_web_enabled: bool,
    #[serde(default)]
    pub zai_web_enabled: bool,
    #[serde(default)]
    pub qwen_web_enabled: bool,
    #[serde(default)]
    pub deepseek_web_enabled: bool,
    #[serde(default)]
    pub tencent_web_enabled: bool,
    #[serde(default)]
    pub rudder_web_enabled: bool,
    /// What each `-latest` alias resolves to now (`flash` 3.8, `pro` 3.1,
    /// `flash-lite` 3.5), read off the Google model list. The runtime ranks an
    /// alias by this number so "higher version = higher priority" holds for it.
    #[serde(default)]
    pub gemini_alias_versions: HashMap<String, f64>,
}

fn default_web_best() -> String {
    "best".to_string()
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            config_version: 13,
            google_api_key_enc: String::new(),
            google_accounts: Vec::new(),
            opencode_api_key_enc: String::new(),
            opencode_accounts: Vec::new(),
            enabled_gemini_models: default_gemini_models(),
            enabled_opencode_models: default_opencode_models(),
            known_opencode_models: default_known_opencode_models(),
            custom_providers: Vec::new(),
            proxies: Vec::new(),
            opencode_upgrade_checked_at: 0,
            provider_catalog_refreshed_at: 0,
            ide_states: default_ide_states(),
            delegator_enabled: true,
            gemini_web_enabled: false,
            gemini_web_model: default_web_best(),
            gemini_web_reasoning: default_web_best(),
            aistudio_web_enabled: false,
            kimi_web_enabled: false,
            zai_web_enabled: false,
            qwen_web_enabled: false,
            deepseek_web_enabled: false,
            tencent_web_enabled: false,
            rudder_web_enabled: false,
            gemini_alias_versions: HashMap::new(),
        }
    }
}

/// OpenRouter's "auto free" route: it picks whatever free model is available,
/// so it answers when every metered model is rate-limited. The last rung of
/// every fallback ladder, and the reason a quota outage no longer means
/// "Delegator stopped working".
pub const UNIVERSAL_FREE_MODEL: &str = "openrouter/openrouter/free";

/// Held by every write of config.json in this process, and by a load for its
/// whole read-migrate-write.
///
/// The writers — the GUI thread, the tray toggle, the provider round on a tokio
/// worker — all publish through the same `config.json.tmp`. Two saves that
/// interleave end with one renaming a tmp the other already moved; the
/// fallback in `write_locked` then removes config.json and fails its retry, and
/// the DPAPI-encrypted keys are gone for good (G112). A load writes back what
/// it read, so it holds the lock from the read on: a save landing in between
/// would be overwritten with the older copy, a load could take the fallback's
/// remove-and-retry for a missing file and write defaults over it, and two
/// loads could both migrate the same old file (G73).
///
/// `load_readonly` does not take it: it never writes.
static CONFIG_FILE_LOCK: Mutex<()> = Mutex::new(());

/// Never nested — std's `Mutex` is not reentrant. Code that already holds the
/// guard passes it to `write_locked` instead of calling `save_to_path`.
fn lock_config_file() -> MutexGuard<'static, ()> {
    // The lock guards the order of file operations, not data, so a poisoned
    // one is as good as a clean one; refusing every later save over one panic
    // would drop every later change.
    CONFIG_FILE_LOCK
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
}

impl AppConfig {
    fn config_path() -> Option<PathBuf> {
        #[cfg(target_os = "macos")]
        {
            let dir = crate::platform::data_root();
            fs::create_dir_all(&dir).ok()?;
            return Some(dir.join("config.json"));
        }
        #[cfg(not(target_os = "macos"))]
        let proj_dirs = ProjectDirs::from("com", "Delegator", "DelegatorWin")?;
        #[cfg(not(target_os = "macos"))]
        let config_dir = proj_dirs.config_dir();
        #[cfg(not(target_os = "macos"))]
        {
            fs::create_dir_all(config_dir).ok()?;
            Some(config_dir.join("config.json"))
        }
    }

    pub fn load() -> Self {
        match Self::config_path() {
            Some(path) => Self::load_from_path(&path),
            None => Self::default(),
        }
    }

    /// Parses config.json WITHOUT migrating or saving it.
    ///
    /// `load` writes the file on every call (it migrates, then persists), which
    /// is right for a startup or a user action and wrong for anything on a
    /// timer: the provider poller wakes every two minutes, and a load there
    /// would rewrite config.json all day and race whatever the GUI is saving.
    /// Every field this is used for has a serde default, so an un-migrated read
    /// answers the only question a poller asks — is a round due — correctly.
    pub fn load_readonly() -> Self {
        let Some(path) = Self::config_path() else {
            return Self::default();
        };
        let Ok(content) = fs::read_to_string(&path) else {
            return Self::default();
        };
        serde_json::from_str::<AppConfig>(&content).unwrap_or_default()
    }

    fn load_from_path(path: &Path) -> Self {
        // From the existence check to the write-back: see `CONFIG_FILE_LOCK`.
        let lock = lock_config_file();
        if path.exists() {
            let content = match fs::read_to_string(path) {
                Ok(content) => content,
                Err(error) => {
                    // Reading failed (locked file, permissions, ...): keep the
                    // file untouched so the DPAPI blobs inside stay recoverable.
                    eprintln!(
                        "Failed to read config {}: {error}; using defaults without overwriting",
                        path.display()
                    );
                    return Self::default();
                }
            };
            match serde_json::from_str::<AppConfig>(&content) {
                Ok(mut cfg) => {
                    cfg.migrate();
                    cfg.write_locked(path, &lock);
                    return cfg;
                }
                Err(error) => {
                    eprintln!(
                        "Failed to parse config {}: {error}; quarantining the corrupt file",
                        path.display()
                    );
                    if !Self::quarantine_corrupt_config(path) {
                        // Could not move the corrupt file aside: do NOT
                        // overwrite it, so the encrypted keys can be recovered.
                        return Self::default();
                    }
                }
            }
        }
        let default_cfg = Self::default();
        default_cfg.write_locked(path, &lock);
        default_cfg
    }

    fn migrate(&mut self) {
        if self.config_version < 1 {
            for model in default_opencode_models() {
                if !self.enabled_opencode_models.contains(&model) {
                    self.enabled_opencode_models.push(model);
                }
            }
            self.config_version = 1;
        }
        if self.config_version < 2 {
            for model in Self::default().enabled_gemini_models {
                if !self.enabled_gemini_models.contains(&model) {
                    self.enabled_gemini_models.push(model);
                }
            }
            for model in default_opencode_models() {
                if !self.enabled_opencode_models.contains(&model) {
                    self.enabled_opencode_models.push(model);
                }
            }
            self.enabled_gemini_models.retain(|model| {
                model != "gemini-3.1-flash-lite-preview" && model != "gemini-3-pro-preview"
            });
            self.config_version = 2;
        }
        self.migrate_google_accounts();
        if self.config_version < 4 {
            self.enabled_opencode_models = default_opencode_models();
            self.config_version = 4;
        }
        if self.config_version < 5 {
            self.enabled_gemini_models = default_gemini_models();
            self.enabled_opencode_models
                .retain(|model| model != "opencode/big-pickle");
            self.config_version = 5;
        }
        self.migrate_opencode_accounts();
        if self.config_version < 6 {
            self.config_version = 6;
        }
        if self.config_version < 7 {
            // Seed the known-model list with everything currently enabled
            // plus the built-in catalog, so catalog sync can tell a brand-new
            // upstream model from one the user deliberately switched off.
            for model in self
                .enabled_opencode_models
                .iter()
                .cloned()
                .chain(default_known_opencode_models())
            {
                if model.starts_with("opencode/") && !self.known_opencode_models.contains(&model) {
                    self.known_opencode_models.push(model);
                }
            }
            self.config_version = 7;
        }
        if self.config_version < 8 {
            self.migrate_proxies(&runtime_home_dir());
        }
        if self.config_version < 9 {
            self.migrate_enable_all_known_opencode_models();
        }
        if self.config_version < 10 {
            self.migrate_universal_free_model();
        }
        if self.config_version < 11 {
            self.migrate_current_gemini_models();
        }
        if self.config_version < 12 {
            self.migrate_reset_usage_counter(&runtime_home_dir());
        }
        if self.config_version < 13 {
            // v13 only ADDS `custom_providers`, which serde already defaults to
            // `[]`. The bump exists so the file records which schema wrote it;
            // there is deliberately nothing to move, because moving a live
            // DPAPI blob is how a key gets lost (I19).
            self.config_version = 13;
        }
        self.ensure_known_ide_keys();
    }

    /// Every IDE Delegator knows about must have a key here. `apply_ide_hooks`
    /// iterates `ide_states`, so an IDE added after the user's config was
    /// written would never even be asked to strip a stale block on pause.
    ///
    /// Deliberately NOT gated on `config_version`: inserting a missing key
    /// without touching an existing one is idempotent, and G73 is the lesson
    /// that a step guarded only by the version number can still run twice.
    /// A new row therefore starts switched OFF, exactly like a fresh install —
    /// enabling it stays the user's click.
    fn ensure_known_ide_keys(&mut self) {
        for (name, state) in default_ide_states() {
            self.ide_states.entry(name).or_insert(state);
        }
    }

    /// v11→v12 (0.7): the usage log starts over.
    ///
    /// Before 0.7 «Сэкономлено» reported gross throughput of the free models and
    /// nothing marked benchmark traffic, so every historical line is either
    /// measured against a different definition or is a benchmark run nobody can
    /// identify after the fact (`bench` simply did not exist as a field). Adding
    /// the new figures on top of that history would produce one number that
    /// silently mixes two meanings.
    ///
    /// Nothing is moved or deleted: a CUT-OFF is written to
    /// `<RT>\usage-counted-from.txt` and the core stops counting anything older.
    ///
    /// The first design renamed the log aside, and that was wrong twice over.
    /// It lost data — `migrate()` is reachable from THREE `AppConfig::load()`
    /// sites (`gui/app.rs` twice, `gui/background.rs` once) across two threads,
    /// two loaders both read a v11 file before either wrote v12, the migration
    /// ran twice, and the second run deleted the first run's archive: 180 KB of
    /// the owner's history, unrecoverable. And it broke routing — `usage.jsonl`
    /// is ALSO where `Get-ModelHealth` learns which models are slow, so an empty
    /// log left every model looking untested and the strength floor spent 92 s
    /// timing out on the strongest id it could find.
    ///
    /// A timestamp fixes both: the counter starts at zero, the router keeps
    /// every latency sample, and a migration that runs twice writes the same
    /// kind of file twice instead of destroying anything.
    fn migrate_reset_usage_counter(&mut self, runtime_home: &Path) {
        if self.config_version >= 12 {
            return;
        }
        let marker = runtime_home.join("usage-counted-from.txt");
        // Never re-stamp: a second (racing) migration must not move the cut-off
        // forward and silently discard whatever was counted in between.
        if !marker.exists() {
            let now = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|elapsed| elapsed.as_secs())
                .unwrap_or(0);
            if let Err(error) = std::fs::write(&marker, unix_to_iso8601(now)) {
                eprintln!("Could not write {}: {error}", marker.display());
            }
        }
        self.config_version = 12;
    }

    /// v10→v11 (owner request 2026-08-13): the newest Gemini generations join
    /// the enabled set.
    ///
    /// Only the three `-latest` aliases used to be enabled, so an explicitly
    /// versioned model could never be chosen — including `gemini-3.7-flash`,
    /// which the owner measured as stronger than what `pro-latest` resolves to.
    /// Additive only: a model the user unchecked is not re-enabled, because
    /// this runs once.
    fn migrate_current_gemini_models(&mut self) {
        if self.config_version >= 11 {
            return;
        }
        for model in default_gemini_models() {
            if !self.enabled_gemini_models.contains(&model) {
                self.enabled_gemini_models.push(model);
            }
        }
        self.config_version = 11;
    }

    /// v9→v10 (owner request 2026-08-13): the universal free model is always
    /// enabled.
    ///
    /// `openrouter/openrouter/free` routes to whatever free model OpenRouter
    /// has available, so it keeps answering when every metered model is out of
    /// quota — which is exactly the state the owner hit mid-benchmark. It was
    /// invisible until now because the Zen catalog sync only keeps ids matching
    /// `^opencode/…`, and the runtime allowlist then refused it
    /// («Requested model … is not enabled in the Delegator GUI»).
    ///
    /// Safe to add once and leave: `sync_opencode_catalog` never prunes
    /// `openrouter/*`, so a later catalog refresh cannot drop it, and a user who
    /// unchecks it keeps it unchecked.
    fn migrate_universal_free_model(&mut self) {
        if self.config_version >= 10 {
            return;
        }
        // Deliberately NOT added to `known_opencode_models`: that list is the
        // Zen catalog's memory and must stay `opencode/*` only — a test guards
        // it. `sync_opencode_catalog` never prunes `openrouter/*`, so being
        // absent from `known` cannot cost it its place in `enabled`.
        if !self
            .enabled_opencode_models
            .iter()
            .any(|model| model == UNIVERSAL_FREE_MODEL)
        {
            self.enabled_opencode_models
                .push(UNIVERSAL_FREE_MODEL.to_string());
        }
        self.config_version = 10;
    }

    /// v8→v9 (owner request 2026-08-11): every free Zen model the app knows
    /// about ships ENABLED, `opencode/big-pickle` included — it used to be
    /// seeded known-but-disabled on purpose.
    ///
    /// This is a ONE-TIME reset, not a per-sync force-enable: afterwards a
    /// model the user unchecks stays unchecked, because `sync_opencode_catalog`
    /// only auto-enables ids missing from `known_opencode_models`.
    fn migrate_enable_all_known_opencode_models(&mut self) {
        if self.config_version >= 9 {
            return;
        }
        let candidates: Vec<String> = self
            .known_opencode_models
            .iter()
            .cloned()
            .chain(default_known_opencode_models())
            .filter(|model| model.starts_with("opencode/"))
            .collect();
        for model in candidates {
            if !self.known_opencode_models.contains(&model) {
                self.known_opencode_models.push(model.clone());
            }
            if !self.enabled_opencode_models.contains(&model) {
                self.enabled_opencode_models.push(model);
            }
        }
        self.config_version = 9;
    }

    /// True when the background `opencode upgrade` is due (never ran, ran more
    /// than 24 h ago, or the stored stamp lies in the future — a clock that
    /// moved backwards must not disable updates forever).
    pub fn opencode_upgrade_due(&self, now_unix: u64) -> bool {
        match now_unix.checked_sub(self.opencode_upgrade_checked_at) {
            Some(elapsed) => elapsed >= OPENCODE_UPGRADE_INTERVAL_SECS,
            None => true,
        }
    }

    /// Records an upgrade ATTEMPT (success or not) so a failing CLI cannot
    /// make every GUI start spawn another 10-minute npm job.
    pub fn mark_opencode_upgrade_attempt(&mut self, now_unix: u64) {
        self.opencode_upgrade_checked_at = now_unix;
        self.save();
    }

    /// True when the daily provider catalog refresh is due. Same shape as
    /// `opencode_upgrade_due`, including the clock-went-backwards arm: a stamp
    /// in the future must not disable refreshes forever.
    ///
    /// Due only while some provider has a usable key. A round with nothing to
    /// ask returns before it stamps, so a keyless or switched-off provider —
    /// the state every provider is in between «Добавить провайдера» and
    /// «Добавить ключ» — used to be due on EVERY poller tick: config.json
    /// rewritten every two minutes and the status line replaced by an empty
    /// «Провайдеры обновлены» report.
    pub fn provider_catalog_refresh_due(&self, now_unix: u64) -> bool {
        if !self
            .custom_providers
            .iter()
            .any(CustomProvider::has_usable_key)
        {
            return false;
        }
        match now_unix.checked_sub(self.provider_catalog_refreshed_at) {
            Some(elapsed) => elapsed >= PROVIDER_CATALOG_INTERVAL_SECS,
            None => true,
        }
    }

    /// Records the ATTEMPT, not the success — a provider that is permanently
    /// unreachable must not make every GUI start fire another probe round.
    pub fn mark_provider_catalog_refresh(&mut self, now_unix: u64) {
        self.provider_catalog_refreshed_at = now_unix;
        self.save();
    }

    /// Adds discovered ids to `known_models` and NOTHING else.
    ///
    /// This is I8 in one method: discovery may widen the list the user chooses
    /// from, but only the user ticks a box. A model that appears here shows up
    /// unticked, which is also what tells a brand-new upstream model apart from
    /// one that was deliberately switched off. Returns whether anything changed.
    pub fn add_known_provider_models(&mut self, provider_id: &str, ids: &[String]) -> bool {
        let changed = self.apply_known_provider_models(provider_id, ids);
        if changed {
            self.save();
        }
        changed
    }

    /// The mutation without the write, so the I8 rule above is testable
    /// (`save` targets the real config path). Returns whether anything changed.
    fn apply_known_provider_models(&mut self, provider_id: &str, ids: &[String]) -> bool {
        let Some(provider) = self.custom_provider_mut(provider_id) else {
            return false;
        };
        let mut changed = false;
        for id in ids {
            let id = id.trim();
            if id.is_empty() || provider.known_models.iter().any(|known| known == id) {
                continue;
            }
            provider.known_models.push(id.to_string());
            changed = true;
        }
        changed
    }

    /// v7→v8 (DEV_CONTRACTS §7a): adopt the runtime's legacy `<RT>\proxy.json`
    /// as the single entry «Прокси 1». The legacy file stays on disk; once the
    /// `proxies` key exists in config.json the runtime ignores the legacy file.
    fn migrate_proxies(&mut self, runtime_home: &Path) {
        if self.config_version >= 8 {
            return;
        }
        if self.proxies.is_empty() {
            if let Some(entry) = load_legacy_proxy(&runtime_home.join("proxy.json")) {
                self.proxies.push(entry);
            }
        }
        self.config_version = 8;
    }

    /// Reconciles the Zen (`opencode/*`) part of the catalog with the ids a
    /// LIVE `opencode models` run just returned. Must never be called after
    /// the built-in fallback: pruning is only valid against a real listing.
    /// New upstream models are enabled by default; models the user disabled
    /// stay disabled; `openrouter/*` entries are never touched.
    /// Returns true when the enabled/known lists changed.
    pub fn sync_opencode_catalog(&mut self, discovered: &[String]) -> bool {
        let is_zen = |id: &str| id.starts_with("opencode/");
        if !discovered.iter().any(|id| is_zen(id)) {
            // A live listing always has at least one Zen id; an empty set
            // here would wipe the user's whole opencode/* selection.
            return false;
        }

        // A provider the user added to their own OpenCode config counts the same
        // as a new Zen alias: seen for the first time → enabled, and remembered
        // so a later uncheck is never undone. `openrouter/*` stays out of
        // `known_*` — that catalog is 335 models we do not want to track.
        let trackable =
            |id: &String| is_zen(id) || crate::models_service::is_custom_provider_model(id);
        let mut changed = false;
        for id in discovered.iter().filter(|id| trackable(id)) {
            if !self.known_opencode_models.contains(id) {
                self.known_opencode_models.push(id.clone());
                if !self.enabled_opencode_models.contains(id) {
                    self.enabled_opencode_models.push(id.clone());
                }
                changed = true;
            }
        }

        // Prune Zen models that vanished upstream (e.g. a *-free alias
        // retired by an OpenCode update); keep every non-Zen entry.
        let keep = |id: &String| !is_zen(id) || discovered.contains(id);
        let len_before = self.enabled_opencode_models.len() + self.known_opencode_models.len();
        self.enabled_opencode_models.retain(keep);
        self.known_opencode_models.retain(keep);
        let len_after = self.enabled_opencode_models.len() + self.known_opencode_models.len();
        if len_after != len_before {
            changed = true;
        }

        changed
    }

    /// Moves an unreadable config aside as `config.json.corrupt-<unix-ts>` so
    /// the DPAPI-encrypted keys inside remain recoverable. Returns true when
    /// the file was moved and the path is free for a fresh config.
    fn quarantine_corrupt_config(path: &Path) -> bool {
        let unix_ts = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|elapsed| elapsed.as_secs())
            .unwrap_or(0);
        let file_name = path
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| "config.json".to_string());
        let backup = path.with_file_name(format!("{file_name}.corrupt-{unix_ts}"));
        match fs::rename(path, &backup) {
            Ok(()) => {
                eprintln!("Corrupt config preserved as {}", backup.display());
                true
            }
            Err(error) => {
                eprintln!(
                    "Failed to preserve corrupt config as {}: {error}",
                    backup.display()
                );
                false
            }
        }
    }

    pub fn save(&self) {
        if let Some(path) = Self::config_path() {
            self.save_to_path(&path);
        }
    }

    /// Imports need a visible failure and must preserve the previous file.
    pub(crate) fn save_checked(&self) -> Result<(), String> {
        let path = Self::config_path().ok_or("Не удалось найти папку настроек.")?;
        let _lock = lock_config_file();
        let json = serde_json::to_vec_pretty(self)
            .map_err(|_| "Не удалось подготовить настройки к сохранению.")?;
        let name = path.file_name().ok_or("Некорректный путь настроек.")?;
        let tmp = path.with_file_name(format!("{}.tmp", name.to_string_lossy()));
        if fs::write(&tmp, json).is_err() {
            let _ = fs::remove_file(&tmp);
            return Err("Не удалось записать настройки. Импорт отменён.".into());
        }
        if fs::rename(&tmp, &path).is_err() {
            let _ = fs::remove_file(&tmp);
            return Err("Не удалось сохранить настройки. Импорт отменён.".into());
        }
        Ok(())
    }

    fn save_to_path(&self, path: &Path) {
        let lock = lock_config_file();
        self.write_locked(path, &lock);
    }

    /// The save itself. `_lock` is the caller's `CONFIG_FILE_LOCK` guard, so
    /// this can neither run unlocked nor lock a second time.
    fn write_locked(&self, path: &Path, _lock: &MutexGuard<'static, ()>) {
        let json = match serde_json::to_string_pretty(self) {
            Ok(json) => json,
            Err(error) => {
                eprintln!("Failed to serialize config: {error}");
                return;
            }
        };
        let file_name = path
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| "config.json".to_string());
        let tmp = path.with_file_name(format!("{file_name}.tmp"));
        if let Err(error) = fs::write(&tmp, json.as_bytes()) {
            eprintln!(
                "Failed to write config temp file {}: {error}",
                tmp.display()
            );
            return;
        }
        // Same-volume rename is atomic on NTFS and replaces the target; if the
        // rename still fails (e.g. the target is locked), remove the target
        // once and retry so we never leave a half-written config.json behind.
        if fs::rename(&tmp, path).is_err() {
            let _ = fs::remove_file(path);
            if let Err(error) = fs::rename(&tmp, path) {
                eprintln!("Failed to save config {}: {error}", path.display());
                let _ = fs::remove_file(&tmp);
            }
        }
    }

    fn migrate_google_accounts(&mut self) {
        if self.config_version < 3 {
            if self.google_accounts.is_empty() && !self.google_api_key_enc.is_empty() {
                self.google_accounts.push(GoogleApiAccount {
                    id: "google-migrated".to_string(),
                    label: "Google account 1".to_string(),
                    api_key_enc: std::mem::take(&mut self.google_api_key_enc),
                    enabled: true,
                });
            }
            self.config_version = 3;
        }
    }

    fn migrate_opencode_accounts(&mut self) {
        if self.opencode_api_key_enc.is_empty() {
            return;
        }
        let encrypted = std::mem::take(&mut self.opencode_api_key_enc);
        if !self
            .opencode_accounts
            .iter()
            .any(|account| account.api_key_enc == encrypted)
        {
            self.opencode_accounts.push(OpenCodeApiAccount {
                id: "opencode-migrated".to_string(),
                label: "OpenCode account 1".to_string(),
                api_key_enc: encrypted,
                enabled: true,
            });
        }
    }

    pub fn first_enabled_google_api_key(&self) -> String {
        self.google_accounts
            .iter()
            .find(|account| account.enabled)
            .and_then(|account| decrypt_string(&account.api_key_enc).ok())
            .unwrap_or_default()
    }

    pub fn add_google_account(&mut self, label: &str, key: &str) -> Result<(), String> {
        let label = label.trim();
        let key = key.trim();
        if label.is_empty() || key.is_empty() {
            return Err("Укажите название и API-ключ Google".to_string());
        }

        self.google_accounts.push(GoogleApiAccount {
            id: new_account_id("google")?,
            label: label.to_string(),
            api_key_enc: encrypt_string(key)?,
            enabled: true,
        });
        self.save();
        Ok(())
    }

    pub fn update_google_account(
        &mut self,
        id: &str,
        label: &str,
        new_key: Option<&str>,
        enabled: bool,
    ) -> Result<(), String> {
        let account = self
            .google_accounts
            .iter_mut()
            .find(|account| account.id == id)
            .ok_or_else(|| "Google-аккаунт не найден".to_string())?;
        let label = label.trim();
        if label.is_empty() {
            return Err("Укажите название Google-аккаунта".to_string());
        }
        account.label = label.to_string();
        account.enabled = enabled;
        if let Some(key) = new_key.map(str::trim).filter(|key| !key.is_empty()) {
            account.api_key_enc = encrypt_string(key)?;
        }
        self.save();
        Ok(())
    }

    pub fn remove_google_account(&mut self, id: &str) {
        self.google_accounts.retain(|account| account.id != id);
        self.save();
    }

    pub fn first_enabled_opencode_api_key(&self) -> String {
        self.opencode_accounts
            .iter()
            .find(|account| account.enabled)
            .and_then(|account| decrypt_string(&account.api_key_enc).ok())
            .unwrap_or_default()
    }

    pub fn add_opencode_account(&mut self, label: &str, key: &str) -> Result<(), String> {
        let label = label.trim();
        let key = key.trim();
        if label.is_empty() || key.is_empty() {
            return Err("Укажите название и API-ключ OpenCode/OpenRouter".to_string());
        }
        self.opencode_accounts.push(OpenCodeApiAccount {
            id: new_account_id("opencode")?,
            label: label.to_string(),
            api_key_enc: encrypt_string(key)?,
            enabled: true,
        });
        self.save();
        Ok(())
    }

    pub fn update_opencode_account(
        &mut self,
        id: &str,
        label: &str,
        new_key: Option<&str>,
        enabled: bool,
    ) -> Result<(), String> {
        let account = self
            .opencode_accounts
            .iter_mut()
            .find(|account| account.id == id)
            .ok_or_else(|| "Аккаунт OpenCode/OpenRouter не найден".to_string())?;
        let label = label.trim();
        if label.is_empty() {
            return Err("Укажите название аккаунта OpenCode/OpenRouter".to_string());
        }
        account.label = label.to_string();
        account.enabled = enabled;
        if let Some(key) = new_key.map(str::trim).filter(|key| !key.is_empty()) {
            account.api_key_enc = encrypt_string(key)?;
        }
        self.save();
        Ok(())
    }

    pub fn remove_opencode_account(&mut self, id: &str) {
        self.opencode_accounts.retain(|account| account.id != id);
        self.save();
    }

    // ── User-added OpenAI-compatible providers (config v13) ──────────────────

    pub fn custom_provider(&self, id: &str) -> Option<&CustomProvider> {
        self.custom_providers.iter().find(|p| p.id == id)
    }

    fn custom_provider_mut(&mut self, id: &str) -> Option<&mut CustomProvider> {
        self.custom_providers.iter_mut().find(|p| p.id == id)
    }

    /// Adds a provider. `models` seeds BOTH lists: a provider the user chose to
    /// add is one whose models they want, and an empty pool would make the new
    /// row look broken. Later catalog runs may only extend `known_models`.
    pub fn add_custom_provider(
        &mut self,
        id: &str,
        label: &str,
        base_url: &str,
        models: &[String],
    ) -> Result<(), String> {
        let provider = validated_custom_provider(id, label, base_url, models)?;
        if self.custom_provider(&provider.id).is_some() {
            return Err(format!("Провайдер «{}» уже добавлен", provider.id));
        }
        self.custom_providers.push(provider);
        self.save();
        Ok(())
    }

    /// Adds a preset with its FREE models enabled and the whole list known, so
    /// the paid ones can be ticked by hand.
    pub fn add_preset_provider(&mut self, preset: &ProviderPreset) -> Result<(), String> {
        let enabled: Vec<String> = preset
            .default_models()
            .iter()
            .map(|m| m.to_string())
            .collect();
        let mut provider =
            validated_custom_provider(preset.id, preset.label, preset.base_url, &enabled)?;
        if self.custom_provider(&provider.id).is_some() {
            return Err(format!("Провайдер «{}» уже добавлен", provider.id));
        }
        provider.known_models = preset.models.iter().map(|m| m.to_string()).collect();
        self.custom_providers.push(provider);
        self.save();
        Ok(())
    }

    pub fn remove_custom_provider(&mut self, id: &str) {
        self.custom_providers.retain(|provider| provider.id != id);
        self.save();
    }

    pub fn set_custom_provider_enabled(&mut self, id: &str, enabled: bool) {
        if let Some(provider) = self.custom_provider_mut(id) {
            provider.enabled = enabled;
            self.save();
        }
    }

    pub fn add_provider_account(
        &mut self,
        provider_id: &str,
        label: &str,
        key: &str,
    ) -> Result<(), String> {
        let label = label.trim();
        let key = key.trim();
        if label.is_empty() || key.is_empty() {
            return Err("Укажите название и API-ключ".to_string());
        }
        let id = new_account_id(provider_id)?;
        let api_key_enc = encrypt_string(key)?;
        let provider = self
            .custom_provider_mut(provider_id)
            .ok_or_else(|| "Провайдер не найден".to_string())?;
        provider.accounts.push(ProviderApiAccount {
            id,
            label: label.to_string(),
            api_key_enc,
            enabled: true,
        });
        self.save();
        Ok(())
    }

    pub fn update_provider_account(
        &mut self,
        provider_id: &str,
        account_id: &str,
        label: &str,
        new_key: Option<&str>,
        enabled: bool,
    ) -> Result<(), String> {
        let label = label.trim();
        if label.is_empty() {
            return Err("Укажите название аккаунта".to_string());
        }
        // Encrypt BEFORE borrowing the provider: a DPAPI failure must not leave
        // the account half-updated with a new label and the old key.
        let api_key_enc = match new_key.map(str::trim).filter(|key| !key.is_empty()) {
            Some(key) => Some(encrypt_string(key)?),
            None => None,
        };
        let account = self
            .custom_provider_mut(provider_id)
            .ok_or_else(|| "Провайдер не найден".to_string())?
            .accounts
            .iter_mut()
            .find(|account| account.id == account_id)
            .ok_or_else(|| "Аккаунт не найден".to_string())?;
        account.label = label.to_string();
        account.enabled = enabled;
        if let Some(encrypted) = api_key_enc {
            account.api_key_enc = encrypted;
        }
        self.save();
        Ok(())
    }

    pub fn remove_provider_account(&mut self, provider_id: &str, account_id: &str) {
        if let Some(provider) = self.custom_provider_mut(provider_id) {
            provider.accounts.retain(|account| account.id != account_id);
            self.save();
        }
    }

    /// Plaintext key of the first enabled account, for the GUI's own provider
    /// traffic (the catalog refresh and the probes, §12a). The PowerShell
    /// runtime decrypts its own — this is not a second key store, it is the
    /// same DPAPI blob read by the other process that needs it.
    pub fn first_enabled_provider_api_key(&self, provider_id: &str) -> String {
        self.custom_provider(provider_id)
            .into_iter()
            .flat_map(|provider| provider.accounts.iter())
            .find(|account| account.enabled)
            .and_then(|account| decrypt_string(&account.api_key_enc).ok())
            .unwrap_or_default()
    }

    pub fn set_provider_model_enabled(&mut self, provider_id: &str, model: &str, enabled: bool) {
        if self.apply_provider_model_enabled(provider_id, model, enabled) {
            self.save();
        }
    }

    /// The mutation without the write, so the rule is testable (`save` targets
    /// the real config path). Returns whether anything changed.
    fn apply_provider_model_enabled(
        &mut self,
        provider_id: &str,
        model: &str,
        enabled: bool,
    ) -> bool {
        let Some(provider) = self.custom_provider_mut(provider_id) else {
            return false;
        };
        let mut changed = false;
        if !provider.known_models.iter().any(|known| known == model) {
            provider.known_models.push(model.to_string());
            changed = true;
        }
        let already = provider.enabled_models.iter().any(|m| m == model);
        if enabled && !already {
            provider.enabled_models.push(model.to_string());
            changed = true;
        } else if !enabled && already {
            provider.enabled_models.retain(|m| m != model);
            changed = true;
        }
        changed
    }

    /// Every enabled model of every enabled provider, already prefixed
    /// `<provider>/<model>` — the exact ids the runtime allowlist compares
    /// against. A provider with no usable key contributes nothing: an id in the
    /// pool that can only ever answer `401` costs a whole rung of the ladder.
    pub fn enabled_custom_provider_models(&self) -> Vec<String> {
        self.custom_providers
            .iter()
            .filter(|provider| provider.has_usable_key())
            .flat_map(|provider| {
                provider
                    .enabled_models
                    .iter()
                    .map(move |model| format!("{}/{model}", provider.id))
            })
            .collect()
    }

    /// Validated add path for a fully specified proxy. The «Прокси» tab adds
    /// blank rows via `add_empty_proxy` and edits them in place instead.
    #[allow(dead_code)]
    pub fn add_proxy(&mut self, label: &str, url: &str) -> Result<(), String> {
        let entry = validated_proxy_entry(label, url)?;
        self.proxies.push(entry);
        self.save();
        Ok(())
    }

    /// Appends a blank enabled entry «Прокси N» for in-place editing in the
    /// GUI; the URL is validated visually there and by the runtime on use.
    pub fn add_empty_proxy(&mut self) {
        let number = self.proxies.len() + 1;
        self.proxies.push(ProxyEntry {
            id: new_account_id("proxy").unwrap_or_else(|_| format!("proxy-n{number}")),
            label: format!("Прокси {number}"),
            url: String::new(),
            enabled: true,
            use_for_gemini: true,
            use_for_opencode: true,
        });
        self.save();
    }

    pub fn remove_proxy(&mut self, id: &str) {
        self.proxies.retain(|proxy| proxy.id != id);
        self.save();
    }

    /// DEV_CONTRACTS §7a rule 2, config list only: the first entry in list
    /// order with `enabled=true`, a non-empty url and the per-provider flag
    /// wins. Provider is `"gemini"` or `"opencode"`; anything else → None.
    pub fn configured_proxy_for(&self, provider: &str) -> Option<String> {
        self.proxies
            .iter()
            .find(|proxy| {
                proxy.enabled
                    && !proxy.url.trim().is_empty()
                    && match provider {
                        "gemini" => proxy.use_for_gemini,
                        "opencode" => proxy.use_for_opencode,
                        _ => false,
                    }
            })
            .map(|proxy| proxy.url.trim().to_string())
    }

    /// Full §7a resolution as the runtime performs it: env `DELEGATOR_PROXY`
    /// (`off` → direct everywhere, any url → that url for all providers)
    /// takes precedence over the config list.
    pub fn effective_proxy_for(&self, provider: &str) -> Option<String> {
        if let Some(env_value) = std::env::var_os("DELEGATOR_PROXY") {
            let env_value = env_value.to_string_lossy().trim().to_string();
            if !env_value.is_empty() {
                if env_value.eq_ignore_ascii_case("off") {
                    return None;
                }
                return Some(env_value);
            }
        }
        self.configured_proxy_for(provider)
    }
}

/// Builds a provider row or says why it cannot exist. Split out of
/// `add_custom_provider` for the same reason as `validated_proxy_entry`: the
/// adder saves to the real config path, so the rules can only be tested here.
pub(crate) fn validated_custom_provider(
    id: &str,
    label: &str,
    base_url: &str,
    models: &[String],
) -> Result<CustomProvider, String> {
    let id = id.trim().to_ascii_lowercase();
    let label = label.trim();
    let base_url = base_url.trim().trim_end_matches('/');
    if !is_valid_provider_id(&id) {
        return Err(
            "Идентификатор провайдера: латиница в нижнем регистре, цифры, - _ .".to_string(),
        );
    }
    // The prefix is a namespace shared with the built-in backends, so a
    // provider called `opencode` or `gemini` would silently capture their model
    // ids in the runtime's split-on-first-slash. `openrouter` is not reserved:
    // its own key lives in the custom provider, which the runtime tries first.
    if matches!(id.as_str(), "opencode" | "gemini" | "google") {
        return Err(format!(
            "Идентификатор «{id}» уже занят встроенным бэкендом"
        ));
    }
    if !base_url.starts_with("http://") && !base_url.starts_with("https://") {
        return Err("Адрес API должен начинаться с http:// или https://".to_string());
    }
    let models: Vec<String> = models
        .iter()
        .map(|model| model.trim().to_string())
        .filter(|model| !model.is_empty())
        .collect();
    Ok(CustomProvider {
        label: if label.is_empty() {
            id.clone()
        } else {
            label.to_string()
        },
        id,
        base_url: base_url.to_string(),
        enabled: true,
        accounts: Vec::new(),
        known_models: models.clone(),
        enabled_models: models,
    })
}

fn validated_proxy_entry(label: &str, url: &str) -> Result<ProxyEntry, String> {
    let label = label.trim();
    let url = url.trim();
    if url.is_empty() {
        return Err("Укажите URL прокси".to_string());
    }
    if !is_supported_proxy_url(url) {
        return Err(
            "URL прокси должен начинаться с http://, https://, socks5:// или socks5h://"
                .to_string(),
        );
    }
    Ok(ProxyEntry {
        id: new_account_id("proxy")?,
        label: if label.is_empty() {
            "Прокси".to_string()
        } else {
            label.to_string()
        },
        url: url.to_string(),
        enabled: true,
        use_for_gemini: true,
        use_for_opencode: true,
    })
}

/// Shape of the pre-v8 runtime file `<RT>\proxy.json`
/// (`{"enabled":true,"url":...,"gemini":true,"opencode":true}`).
#[derive(Deserialize)]
struct LegacyProxyFile {
    #[serde(default = "default_true")]
    enabled: bool,
    #[serde(default)]
    url: String,
    #[serde(default = "default_true")]
    gemini: bool,
    #[serde(default = "default_true")]
    opencode: bool,
}

/// Reads the legacy runtime proxy file; None when absent or unparseable
/// (a corrupt legacy file must not block the config migration).
fn load_legacy_proxy(path: &Path) -> Option<ProxyEntry> {
    let content = fs::read_to_string(path).ok()?;
    let legacy: LegacyProxyFile = serde_json::from_str(&content).ok()?;
    Some(ProxyEntry {
        id: new_account_id("proxy").unwrap_or_else(|_| "proxy-migrated".to_string()),
        label: "Прокси 1".to_string(),
        url: legacy.url,
        enabled: legacy.enabled,
        use_for_gemini: legacy.gemini,
        use_for_opencode: legacy.opencode,
    })
}

/// `%DELEGATOR_RUNTIME_HOME%` else `%LOCALAPPDATA%\DelegatorWin\runtime` —
/// mirrors the runtime's `<RT>` resolution (DEV_CONTRACTS §2.1).
pub fn runtime_home_dir() -> PathBuf {
    if let Some(overridden) = std::env::var_os("DELEGATOR_RUNTIME_HOME") {
        if !overridden.is_empty() {
            return PathBuf::from(overridden);
        }
    }
    crate::platform::data_root().join("runtime")
}

pub(crate) fn new_account_id(prefix: &str) -> Result<String, String> {
    let unique_suffix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_nanos();
    Ok(format!("{prefix}-{unique_suffix}"))
}

fn default_ide_states() -> HashMap<String, bool> {
    let mut default_ides = HashMap::new();
    default_ides.insert("Antigravity".to_string(), false);
    default_ides.insert("Codex".to_string(), false);
    default_ides.insert("OpenCode".to_string(), false);
    default_ides.insert("Cursor".to_string(), false);
    default_ides.insert("Claude".to_string(), false);
    default_ides.insert("VS Code".to_string(), false);
    default_ides.insert("VSCodium".to_string(), false);
    default_ides
}

fn default_gemini_models() -> Vec<String> {
    [
        // Newest generation first: the owner measured `gemini-3.7-flash` as
        // stronger than what `gemini-pro-latest` resolves to today (3.1 Pro),
        // and the reviewer picks the strongest ENABLED model.
        "gemini-3.7-flash",
        "gemini-3.6-flash",
        "gemini-3.5-flash",
        "gemini-pro-latest",
        "gemini-flash-latest",
        "gemini-flash-lite-latest",
    ]
    .into_iter()
    .map(str::to_string)
    .collect()
}

/// Built-in Zen lineup, used until the first live `opencode models` run.
/// Since config v9 EVERY entry ships enabled, `opencode/big-pickle` included.
fn default_opencode_models() -> Vec<String> {
    [
        // A FRESH config is created at the current `config_version`, so it runs
        // no migrations at all — the universal free route has to be in the
        // defaults or a new install would never get it. Found the hard way:
        // config v10 with the model missing.
        UNIVERSAL_FREE_MODEL,
        "opencode/big-pickle",
        "opencode/deepseek-v4-flash-free",
        "opencode/laguna-s-2.1-free",
        "opencode/ling-3.0-flash-free",
        "opencode/mimo-v2.5-free",
        "opencode/nemotron-3-ultra-free",
        "opencode/north-mini-code-free",
    ]
    .into_iter()
    .map(str::to_string)
    .collect()
}

/// The full built-in Zen catalog. Since v9 it is identical to the enabled
/// defaults — nothing ships known-but-disabled anymore.
fn default_known_opencode_models() -> Vec<String> {
    // `known_*` is the Zen catalog's memory and stays `opencode/*` only, or
    // `sync_opencode_catalog` starts reasoning about ids it does not own.
    default_opencode_models()
        .into_iter()
        .filter(|model| model.starts_with("opencode/"))
        .collect()
}

/// Fixtures shared with other modules' unit tests. `gui::app` has to build a
/// provider row to assert what the «API» tab offers, and duplicating the shape
/// there is how the two drift.
#[cfg(test)]
pub mod tests_support {
    use super::{CustomProvider, ProviderApiAccount};

    pub fn provider(id: &str, label: &str) -> CustomProvider {
        CustomProvider {
            id: id.to_string(),
            label: label.to_string(),
            base_url: "https://api.example.com/v1".to_string(),
            enabled: true,
            accounts: Vec::new(),
            enabled_models: Vec::new(),
            known_models: Vec::new(),
        }
    }

    pub fn account(id: &str, enabled: bool) -> ProviderApiAccount {
        ProviderApiAccount {
            id: id.to_string(),
            label: id.to_string(),
            api_key_enc: "opaque-dpapi-blob".to_string(),
            enabled,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_enable_current_opencode_free_models() {
        let config = AppConfig::default();
        assert_eq!(config.config_version, 13);
        assert!(config.proxies.is_empty());
        assert_eq!(config.enabled_opencode_models, default_opencode_models());
        // Since v9 every known free Zen model ships enabled, big-pickle too.
        assert!(config
            .enabled_opencode_models
            .contains(&"opencode/big-pickle".to_string()));
        // `known_*` is Zen-only; `enabled_*` also carries the universal free route.
        assert!(config
            .enabled_opencode_models
            .contains(&UNIVERSAL_FREE_MODEL.to_string()));
        assert!(!config
            .known_opencode_models
            .iter()
            .any(|model| model.starts_with("openrouter/")));
        assert_eq!(
            config.known_opencode_models,
            default_known_opencode_models()
        );
        assert_eq!(config.enabled_gemini_models, default_gemini_models());
        assert_eq!(config.opencode_upgrade_checked_at, 0);
    }

    #[test]
    fn legacy_google_key_migrates_without_decryption() {
        let mut config = AppConfig::default();
        config.config_version = 2;
        config.google_api_key_enc = "opaque-dpapi-data".to_string();
        config.migrate_google_accounts();
        assert_eq!(config.config_version, 3);
        assert!(config.google_api_key_enc.is_empty());
        assert_eq!(config.google_accounts.len(), 1);
        assert_eq!(config.google_accounts[0].api_key_enc, "opaque-dpapi-data");
    }

    #[test]
    fn legacy_opencode_key_migrates_without_decryption() {
        let mut config = AppConfig::default();
        config.opencode_api_key_enc = "opaque-opencode-dpapi-data".to_string();
        config.migrate_opencode_accounts();
        assert!(config.opencode_api_key_enc.is_empty());
        assert_eq!(config.opencode_accounts.len(), 1);
        assert_eq!(
            config.opencode_accounts[0].api_key_enc,
            "opaque-opencode-dpapi-data"
        );
    }

    fn temp_config_path(tag: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock before unix epoch")
            .as_nanos();
        let dir = std::env::temp_dir().join(format!(
            "delegator-config-test-{tag}-{}-{nanos}",
            std::process::id()
        ));
        fs::create_dir_all(&dir).expect("create temp config dir");
        dir.join("config.json")
    }

    fn cleanup(path: &Path) {
        if let Some(dir) = path.parent() {
            let _ = fs::remove_dir_all(dir);
        }
    }

    /// Compares model lists by content: migration order depends on the config
    /// version the file came from, the SET of models does not.
    fn sorted(models: &[String]) -> Vec<String> {
        let mut sorted = models.to_vec();
        sorted.sort();
        sorted
    }

    #[test]
    fn config_missing_fields_deserializes_with_defaults() {
        let cfg: AppConfig = serde_json::from_str("{}").expect("empty object must deserialize");
        assert_eq!(cfg.enabled_gemini_models, default_gemini_models());
        assert_eq!(cfg.enabled_opencode_models, default_opencode_models());
        assert_eq!(cfg.ide_states, default_ide_states());
        assert!(cfg.delegator_enabled);
    }

    #[test]
    fn config_with_missing_fields_loads_and_migrates() {
        let path = temp_config_path("migrate");
        // A legacy config predating enabled_* / ide_states / delegator_enabled,
        // with an encrypted account that must survive the load. The `proxies`
        // entry keeps the v8 migration off this machine's real proxy.json and
        // doubles as a serde-defaults check for ProxyEntry booleans.
        let legacy = r#"{
            "config_version": 0,
            "google_accounts": [
                {"id": "g1", "label": "Main", "api_key_enc": "opaque-dpapi-blob"}
            ],
            "proxies": [
                {"id": "p1", "label": "Прокси 1", "url": "http://192.168.0.148:8080"}
            ]
        }"#;
        fs::write(&path, legacy).expect("write legacy config");

        let cfg = AppConfig::load_from_path(&path);
        assert_eq!(cfg.config_version, 13);
        assert_eq!(cfg.google_accounts.len(), 1);
        assert_eq!(cfg.google_accounts[0].api_key_enc, "opaque-dpapi-blob");
        assert!(cfg.google_accounts[0].enabled);
        assert_eq!(cfg.enabled_gemini_models, default_gemini_models());
        // The chained migrations end with the full built-in Zen set enabled
        // (v5 dropped big-pickle, v9 put it back), plus the universal free
        // route v10 adds. Order is history-dependent.
        // `default_opencode_models()` already carries the universal free route
        // (a fresh config runs no migrations, so it has to be in the defaults).
        assert_eq!(
            sorted(&cfg.enabled_opencode_models),
            sorted(&default_opencode_models())
        );
        assert!(cfg
            .enabled_opencode_models
            .contains(&UNIVERSAL_FREE_MODEL.to_string()));
        assert_eq!(
            sorted(&cfg.known_opencode_models),
            sorted(&default_known_opencode_models())
        );
        assert!(cfg.delegator_enabled);
        assert!(!cfg.ide_states.is_empty());
        assert_eq!(cfg.proxies.len(), 1);
        assert!(cfg.proxies[0].enabled);
        assert!(cfg.proxies[0].use_for_gemini);
        assert!(cfg.proxies[0].use_for_opencode);

        // The migrated config is persisted and loads back cleanly.
        let reloaded = AppConfig::load_from_path(&path);
        assert_eq!(reloaded.config_version, 13);
        assert_eq!(reloaded.google_accounts[0].api_key_enc, "opaque-dpapi-blob");
        assert_eq!(reloaded.proxies.len(), 1);
        cleanup(&path);
    }

    #[test]
    fn corrupt_config_is_quarantined_not_overwritten() {
        let path = temp_config_path("corrupt");
        let garbage = "{ this is definitely not json";
        fs::write(&path, garbage).expect("write corrupt config");

        let cfg = AppConfig::load_from_path(&path);
        assert_eq!(cfg.config_version, 13);
        assert!(cfg.google_accounts.is_empty());

        let dir = path.parent().expect("temp dir");
        let backup = fs::read_dir(dir)
            .expect("read temp dir")
            .filter_map(Result::ok)
            .find(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with("config.json.corrupt-")
            })
            .expect("corrupt config must be preserved with a corrupt-<ts> suffix");
        let preserved = fs::read_to_string(backup.path()).expect("read preserved config");
        assert_eq!(preserved, garbage);

        // A fresh default config took the original path.
        let fresh = fs::read_to_string(&path).expect("read fresh config");
        let fresh: AppConfig = serde_json::from_str(&fresh).expect("fresh config parses");
        assert_eq!(fresh.config_version, 13);
        cleanup(&path);
    }

    #[test]
    fn atomic_save_replaces_existing_config_and_leaves_no_temp_file() {
        let path = temp_config_path("atomic");
        let mut cfg = AppConfig::default();
        cfg.save_to_path(&path);
        assert!(path.exists());

        cfg.google_accounts.push(GoogleApiAccount {
            id: "g-atomic".to_string(),
            label: "Atomic".to_string(),
            api_key_enc: "blob".to_string(),
            enabled: true,
        });
        cfg.save_to_path(&path);

        let stored = fs::read_to_string(&path).expect("read saved config");
        let stored: AppConfig = serde_json::from_str(&stored).expect("saved config parses");
        assert_eq!(stored.google_accounts.len(), 1);
        assert_eq!(stored.google_accounts[0].id, "g-atomic");

        let dir = path.parent().expect("temp dir");
        let leftover_tmp = fs::read_dir(dir)
            .expect("read temp dir")
            .filter_map(Result::ok)
            .any(|entry| entry.file_name().to_string_lossy().ends_with(".tmp"));
        assert!(!leftover_tmp, "no temp file must remain after save");
        cleanup(&path);
    }

    fn config_with_account(id: &str) -> AppConfig {
        let mut config = AppConfig::default();
        config.google_accounts.push(GoogleApiAccount {
            id: id.to_string(),
            label: id.to_string(),
            api_key_enc: "opaque-dpapi-blob".to_string(),
            enabled: true,
        });
        config
    }

    /// Every writer in the process — the GUI thread, the tray toggle, the
    /// provider round on a tokio worker — saves through the same
    /// `config.json.tmp`. Unserialized, one save renames the tmp another save
    /// is about to rename, the loser's fallback removes config.json and its
    /// retry fails: the file is gone and the DPAPI keys with it (G112).
    ///
    /// One save per writer per round, released together, and the file is read
    /// only after every writer has returned: a later save in the same round
    /// would recreate a deleted file before anyone looked.
    #[test]
    fn concurrent_saves_never_delete_or_tear_config_json() {
        const WRITERS: usize = 4;
        const ROUNDS: usize = 300;
        let path = temp_config_path("concurrent-saves");
        let writers: Vec<AppConfig> = (0..WRITERS)
            .map(|writer| config_with_account(&format!("writer-{writer}")))
            .collect();
        // From the very instances the threads save: `ide_states` is a HashMap,
        // and only the same instance serializes to the same bytes.
        let whole: Vec<String> = writers
            .iter()
            .map(|config| serde_json::to_string_pretty(config).expect("serialize writer config"))
            .collect();

        for round in 0..ROUNDS {
            let start = std::sync::Barrier::new(WRITERS);
            std::thread::scope(|scope| {
                for config in &writers {
                    let (start, path) = (&start, &path);
                    scope.spawn(move || {
                        start.wait();
                        config.save_to_path(path);
                    });
                }
            });
            let stored = fs::read_to_string(&path)
                .unwrap_or_else(|error| panic!("round {round}: config.json is gone: {error}"));
            if let Err(error) = serde_json::from_str::<AppConfig>(&stored) {
                panic!("round {round}: config.json no longer parses: {error}");
            }
            assert!(
                whole.contains(&stored),
                "round {round}: config.json parses but is no single writer's config"
            );
        }
        cleanup(&path);
    }

    /// A load writes back what it read. A save landing between that read and
    /// that write is overwritten with the OLDER copy — a background
    /// `AppConfig::load()` undoing a tick the GUI just saved, G112 in
    /// miniature. So the lock spans the whole load, not only its write.
    #[test]
    fn a_load_never_writes_back_a_copy_older_than_a_concurrent_save() {
        const ROUNDS: usize = 300;
        let path = temp_config_path("load-vs-save");
        let older = config_with_account("older");
        let newer = config_with_account("newer");

        for round in 0..ROUNDS {
            older.save_to_path(&path);
            let start = std::sync::Barrier::new(2);
            std::thread::scope(|scope| {
                scope.spawn(|| {
                    start.wait();
                    let _ = AppConfig::load_from_path(&path);
                });
                scope.spawn(|| {
                    start.wait();
                    newer.save_to_path(&path);
                });
            });
            let stored = fs::read_to_string(&path)
                .unwrap_or_else(|error| panic!("round {round}: config.json is gone: {error}"));
            let stored: AppConfig = serde_json::from_str(&stored).unwrap_or_else(|error| {
                panic!("round {round}: config.json no longer parses: {error}")
            });
            assert_eq!(
                stored
                    .google_accounts
                    .first()
                    .map(|account| account.id.as_str()),
                Some("newer"),
                "round {round}: a load wrote back the copy it read before a concurrent save"
            );
        }
        cleanup(&path);
    }

    #[test]
    fn migration_v6_seeds_known_models_and_v9_enables_every_one_of_them() {
        let mut config = AppConfig::default();
        config.config_version = 6;
        config.known_opencode_models.clear();
        config.enabled_opencode_models = vec![
            "opencode/deepseek-v4-flash-free".to_string(),
            "opencode/custom-user-free".to_string(),
            "openrouter/qwen/qwen-2.5:free".to_string(),
        ];
        // Non-empty proxies keep the chained v8 step off this machine's real
        // legacy proxy.json (the import itself is covered by dedicated tests).
        config.proxies = vec![test_proxy("p-keep", "http://one:8080", true, true, true)];

        config.migrate();

        // migrate() chains through v7/v8 up to the current version 9.
        assert_eq!(config.config_version, 13);
        assert_eq!(config.proxies.len(), 1);
        // v7 seeded known = enabled opencode/* ∪ built-in catalog; v9 then
        // enabled every one of them, the user's own alias included.
        for model in default_known_opencode_models()
            .into_iter()
            .chain(["opencode/custom-user-free".to_string()])
        {
            assert!(config.known_opencode_models.contains(&model), "{model}");
            assert!(config.enabled_opencode_models.contains(&model), "{model}");
        }
        // big-pickle is no longer held back (this is what v9 changes).
        assert!(config
            .enabled_opencode_models
            .contains(&"opencode/big-pickle".to_string()));
        // openrouter/* ids stay enabled and never enter the known Zen list.
        assert!(config
            .enabled_opencode_models
            .contains(&"openrouter/qwen/qwen-2.5:free".to_string()));
        assert!(!config
            .known_opencode_models
            .iter()
            .any(|model| model.starts_with("openrouter/")));
        // No duplicates crept in while both lists were merged.
        let mut unique = config.enabled_opencode_models.clone();
        unique.sort();
        unique.dedup();
        assert_eq!(unique.len(), config.enabled_opencode_models.len());
    }

    #[test]
    fn the_newest_gemini_generations_are_enabled() {
        // Only the three `-latest` aliases used to ship enabled, so an
        // explicitly versioned model could never be picked — including
        // `gemini-3.7-flash`, measured stronger than what `pro-latest`
        // resolves to. Both the defaults and the migration must cover it.
        assert!(default_gemini_models().contains(&"gemini-3.7-flash".to_string()));
        assert!(AppConfig::default()
            .enabled_gemini_models
            .contains(&"gemini-3.7-flash".to_string()));

        let mut config = AppConfig {
            config_version: 10,
            enabled_gemini_models: vec!["gemini-flash-latest".to_string()],
            ..AppConfig::default()
        };
        config.config_version = 10;
        config.migrate_current_gemini_models();
        // This step alone lands on 11; the 0.7 usage reset takes it to 12.
        assert_eq!(config.config_version, 11);
        assert!(config
            .enabled_gemini_models
            .contains(&"gemini-3.7-flash".to_string()));
        // Additive only, and idempotent.
        config.config_version = 10;
        config.migrate_current_gemini_models();
        assert_eq!(
            config
                .enabled_gemini_models
                .iter()
                .filter(|model| *model == "gemini-3.7-flash")
                .count(),
            1
        );
    }

    #[test]
    fn a_custom_provider_is_auto_enabled_once_and_stays_unchecked_after() {
        // The owner added AgentRouter to their OpenCode config; it must appear
        // and be usable without hand-editing anything — but an uncheck must
        // survive the next sync, exactly like a Zen alias.
        let mut config = AppConfig::default();
        config.enabled_opencode_models.clear();
        config.known_opencode_models.clear();

        let discovered = vec![
            "opencode/big-pickle".to_string(),
            "agentrouter/claude-opus-5".to_string(),
        ];
        assert!(config.sync_opencode_catalog(&discovered));
        assert!(config
            .enabled_opencode_models
            .contains(&"agentrouter/claude-opus-5".to_string()));

        // User unchecks it; a later sync must NOT bring it back.
        config
            .enabled_opencode_models
            .retain(|id| id != "agentrouter/claude-opus-5");
        config.sync_opencode_catalog(&discovered);
        assert!(!config
            .enabled_opencode_models
            .contains(&"agentrouter/claude-opus-5".to_string()));

        // And a custom model is never pruned for being absent from a Zen listing.
        config
            .enabled_opencode_models
            .push("agentrouter/claude-opus-5".to_string());
        config.sync_opencode_catalog(&["opencode/big-pickle".to_string()]);
        assert!(config
            .enabled_opencode_models
            .contains(&"agentrouter/claude-opus-5".to_string()));
    }

    #[test]
    fn a_fresh_config_already_has_the_universal_free_route() {
        // A brand-new config is created AT the current version, so it runs no
        // migrations at all. Found the hard way: config v10 on a fresh file with
        // the model missing, because only the v9→v10 path added it.
        let config = AppConfig::default();
        assert_eq!(config.config_version, 13);
        assert!(config
            .enabled_opencode_models
            .contains(&UNIVERSAL_FREE_MODEL.to_string()));
    }

    #[test]
    fn migration_v9_to_v10_enables_the_universal_free_route() {
        // The owner hit a quota outage mid-benchmark: every metered model was
        // limited and Delegator simply stopped. `openrouter/openrouter/free`
        // routes to whatever free model is available and keeps answering — but
        // the runtime allowlist refused it until it was ENABLED here.
        let mut config = AppConfig {
            config_version: 9,
            enabled_opencode_models: vec!["opencode/big-pickle".to_string()],
            known_opencode_models: vec!["opencode/big-pickle".to_string()],
            ..AppConfig::default()
        };
        config.config_version = 9;
        config.migrate_universal_free_model();

        assert_eq!(config.config_version, 10);
        assert!(config
            .enabled_opencode_models
            .contains(&UNIVERSAL_FREE_MODEL.to_string()));
        // `known_opencode_models` is the Zen catalog's memory and stays
        // `opencode/*` only, or sync_opencode_catalog starts reasoning about
        // ids it does not own.
        assert!(!config
            .known_opencode_models
            .iter()
            .any(|model| model.starts_with("openrouter/")));

        // Idempotent: a second pass must not duplicate the entry.
        config.config_version = 9;
        config.migrate_universal_free_model();
        assert_eq!(
            config
                .enabled_opencode_models
                .iter()
                .filter(|model| *model == UNIVERSAL_FREE_MODEL)
                .count(),
            1
        );
    }

    #[test]
    fn migration_v8_to_v9_enables_all_known_including_big_pickle() {
        let mut config = AppConfig::default();
        config.config_version = 8;
        // A real v8 config from this machine: big-pickle known-but-disabled,
        // plus a Zen alias the built-in catalog does not contain.
        config.known_opencode_models = vec![
            "opencode/big-pickle".to_string(),
            "opencode/nemotron-3-ultra-free".to_string(),
            "opencode/longcat-2.0-free".to_string(),
        ];
        config.enabled_opencode_models = vec![
            "opencode/nemotron-3-ultra-free".to_string(),
            "openrouter/qwen/qwen-2.5:free".to_string(),
        ];

        config.migrate();

        assert_eq!(config.config_version, 13);
        for model in [
            "opencode/big-pickle",
            "opencode/nemotron-3-ultra-free",
            "opencode/longcat-2.0-free",
        ] {
            assert!(
                config.enabled_opencode_models.contains(&model.to_string()),
                "{model}"
            );
        }
        // The built-in catalog is folded in as well.
        for model in default_known_opencode_models() {
            assert!(config.enabled_opencode_models.contains(&model), "{model}");
            assert!(config.known_opencode_models.contains(&model), "{model}");
        }
        // openrouter/* is untouched by the Zen migration.
        assert!(config
            .enabled_opencode_models
            .contains(&"openrouter/qwen/qwen-2.5:free".to_string()));
        // Re-running is a no-op (the version gate already passed).
        let enabled_after_first = config.enabled_opencode_models.clone();
        config.migrate_enable_all_known_opencode_models();
        assert_eq!(config.enabled_opencode_models, enabled_after_first);
    }

    #[test]
    fn sync_adds_new_prunes_stale_and_preserves_user_choices() {
        let mut config = AppConfig::default();
        config
            .enabled_opencode_models
            .push("openrouter/qwen/qwen-2.5:free".to_string());
        // The user unchecked big-pickle in the GUI AFTER the v9 reset: it stays
        // known, so sync must never switch it back on.
        config
            .enabled_opencode_models
            .retain(|model| model != "opencode/big-pickle");

        // The live CLI listing from opencode v1.18.15: big-pickle still
        // there, ling-3.0-flash-free gone, two brand-new free models.
        let discovered: Vec<String> = [
            "opencode/big-pickle",
            "opencode/deepseek-v4-flash-free",
            "opencode/laguna-s-2.1-free",
            "opencode/ling-3.0-tiny-free",
            "opencode/longcat-2.0-free",
            "opencode/mimo-v2.5-free",
            "opencode/nemotron-3-ultra-free",
            "opencode/north-mini-code-free",
        ]
        .into_iter()
        .map(str::to_string)
        .collect();

        assert!(config.sync_opencode_catalog(&discovered));

        // New free models are auto-enabled and remembered.
        for new_model in ["opencode/ling-3.0-tiny-free", "opencode/longcat-2.0-free"] {
            assert!(config
                .enabled_opencode_models
                .contains(&new_model.to_string()));
            assert!(config
                .known_opencode_models
                .contains(&new_model.to_string()));
        }
        // The retired alias is pruned everywhere.
        assert!(!config
            .enabled_opencode_models
            .contains(&"opencode/ling-3.0-flash-free".to_string()));
        assert!(!config
            .known_opencode_models
            .contains(&"opencode/ling-3.0-flash-free".to_string()));
        // The user-unchecked model stays known but NOT enabled.
        assert!(!config
            .enabled_opencode_models
            .contains(&"opencode/big-pickle".to_string()));
        assert!(config
            .known_opencode_models
            .contains(&"opencode/big-pickle".to_string()));
        // openrouter/* selection is never touched.
        assert!(config
            .enabled_opencode_models
            .contains(&"openrouter/qwen/qwen-2.5:free".to_string()));

        // Re-running against the same listing is a no-op, and the unchecked
        // model is still unchecked after the second sync.
        assert!(!config.sync_opencode_catalog(&discovered));
        assert!(!config
            .enabled_opencode_models
            .contains(&"opencode/big-pickle".to_string()));
    }

    #[test]
    fn opencode_upgrade_is_due_once_per_day() {
        let mut config = AppConfig::default();
        let now = 1_800_000_000u64;
        // Never checked → due immediately.
        assert!(config.opencode_upgrade_due(now));

        config.opencode_upgrade_checked_at = now;
        assert!(!config.opencode_upgrade_due(now));
        assert!(!config.opencode_upgrade_due(now + OPENCODE_UPGRADE_INTERVAL_SECS - 1));
        assert!(config.opencode_upgrade_due(now + OPENCODE_UPGRADE_INTERVAL_SECS));

        // A stamp in the future (clock moved back) must not block updates.
        config.opencode_upgrade_checked_at = now + 10_000;
        assert!(config.opencode_upgrade_due(now));
    }

    fn test_proxy(id: &str, url: &str, enabled: bool, gemini: bool, opencode: bool) -> ProxyEntry {
        ProxyEntry {
            id: id.to_string(),
            label: id.to_string(),
            url: url.to_string(),
            enabled,
            use_for_gemini: gemini,
            use_for_opencode: opencode,
        }
    }

    /// Serializes access to process-global env vars across the test threads
    /// and restores the previous value on drop, so no test ever leaks state
    /// onto the machine or another test.
    struct EnvGuard {
        key: &'static str,
        previous: Option<std::ffi::OsString>,
        _lock: std::sync::MutexGuard<'static, ()>,
    }

    impl EnvGuard {
        fn set(key: &'static str, value: &str) -> Self {
            static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
            let lock = LOCK
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let previous = std::env::var_os(key);
            std::env::set_var(key, value);
            Self {
                key,
                previous,
                _lock: lock,
            }
        }
    }

    impl Drop for EnvGuard {
        fn drop(&mut self) {
            match &self.previous {
                Some(value) => std::env::set_var(self.key, value),
                None => std::env::remove_var(self.key),
            }
        }
    }

    #[test]
    fn proxy_entry_serde_defaults_and_roundtrip() {
        // Missing booleans default to true (contract: enabled/use_for_* = true).
        let entry: ProxyEntry = serde_json::from_str(
            r#"{"id":"p1","label":"Прокси 1","url":"socks5://10.0.0.5:1080"}"#,
        )
        .expect("minimal proxy entry parses");
        assert!(entry.enabled);
        assert!(entry.use_for_gemini);
        assert!(entry.use_for_opencode);

        // Explicit false values survive a roundtrip.
        let mut entry = entry;
        entry.enabled = false;
        entry.use_for_gemini = false;
        let json = serde_json::to_string(&entry).expect("proxy entry serializes");
        let back: ProxyEntry = serde_json::from_str(&json).expect("roundtrip parses");
        assert!(!back.enabled);
        assert!(!back.use_for_gemini);
        assert!(back.use_for_opencode);
        assert_eq!(back.url, "socks5://10.0.0.5:1080");

        // The proxies key is ALWAYS serialized, even when empty: its presence
        // is what makes config.json authoritative over the legacy proxy.json.
        let config_json =
            serde_json::to_string(&AppConfig::default()).expect("default config serializes");
        assert!(config_json.contains("\"proxies\""));
    }

    /// v11→v12 (0.7). Pre-0.7 lines measured «сэкономлено» as gross throughput
    /// and carried no `bench` flag, so they cannot be mixed into the new
    /// figures. The counter therefore starts at a CUT-OFF — and the log itself
    /// is left alone, because `Get-ModelHealth` reads the same file to learn
    /// which models are slow.
    #[test]
    fn migration_v11_to_v12_stamps_a_cut_off_and_leaves_the_log_alone() {
        let config_path = temp_config_path("usage-reset");
        let runtime_home = config_path.parent().expect("temp dir").to_path_buf();
        let log = runtime_home.join("usage.jsonl");
        fs::write(
            &log,
            "{\"ts\":\"2026-08-01T00:00:00Z\"}
",
        )
        .expect("write usage log");

        let mut config = AppConfig {
            config_version: 11,
            ..AppConfig::default()
        };
        config.migrate_reset_usage_counter(&runtime_home);

        assert_eq!(config.config_version, 12);
        assert!(
            log.exists(),
            "the log carries the health history and must survive"
        );
        let marker = runtime_home.join("usage-counted-from.txt");
        let stamp = fs::read_to_string(&marker).expect("read cut-off");
        assert!(stamp.ends_with('Z') && stamp.starts_with("20"), "{stamp}");

        // THE REGRESSION. `migrate()` is reachable from three `AppConfig::load()`
        // call sites across two threads, so two loaders can both read a v11 file
        // before either writes v12 and the migration runs TWICE. The first
        // design renamed the log aside and deleted any previous archive, and the
        // second run destroyed the first run's history for good — 180 KB, gone.
        // A second run must now be inert.
        let mut stale = AppConfig {
            config_version: 11,
            ..AppConfig::default()
        };
        stale.migrate_reset_usage_counter(&runtime_home);
        assert_eq!(stale.config_version, 12);
        assert_eq!(
            fs::read_to_string(&marker).expect("re-read cut-off"),
            stamp,
            "a racing second migration must not move the cut-off forward"
        );
        assert!(log.exists(), "and must still not touch the log");

        let _ = fs::remove_dir_all(&runtime_home);
    }

    /// A fresh install has nothing to stamp against and must not fail over it —
    /// the «fresh config runs NO migrations» trap in reverse.
    #[test]
    fn the_usage_reset_is_a_no_op_on_a_fresh_config() {
        let config_path = temp_config_path("usage-reset-empty");
        let runtime_home = config_path.parent().expect("temp dir").to_path_buf();

        let mut config = AppConfig {
            config_version: 11,
            ..AppConfig::default()
        };
        config.migrate_reset_usage_counter(&runtime_home);

        assert_eq!(config.config_version, 12);
        assert!(runtime_home.join("usage-counted-from.txt").exists());
        // And a brand-new config is already past it, so nothing runs at all.
        assert_eq!(AppConfig::default().config_version, 13);

        let _ = fs::remove_dir_all(&runtime_home);
    }

    /// The cut-off is written by hand (no date crate), so it has to be right.
    #[test]
    fn unix_seconds_render_as_iso8601() {
        assert_eq!(unix_to_iso8601(0), "1970-01-01T00:00:00Z");
        assert_eq!(unix_to_iso8601(1_000_000_000), "2001-09-09T01:46:40Z");
        // A leap day, which is where a hand-rolled calendar usually breaks.
        assert_eq!(unix_to_iso8601(1_709_164_800), "2024-02-29T00:00:00Z");
        assert_eq!(unix_to_iso8601(1_787_308_800), "2026-08-21T10:40:00Z");
    }

    #[test]
    fn migration_v7_to_v8_imports_legacy_proxy_file() {
        let config_path = temp_config_path("proxy-import");
        let runtime_home = config_path.parent().expect("temp dir").to_path_buf();
        fs::write(
            runtime_home.join("proxy.json"),
            r#"{"enabled":true,"url":"http://192.168.0.148:8080","gemini":false}"#,
        )
        .expect("write legacy proxy.json");

        let mut config = AppConfig::default();
        config.config_version = 7;
        config.migrate_proxies(&runtime_home);

        assert_eq!(config.config_version, 8);
        assert_eq!(config.proxies.len(), 1);
        let imported = &config.proxies[0];
        assert!(imported.id.starts_with("proxy-"));
        assert_eq!(imported.label, "Прокси 1");
        assert_eq!(imported.url, "http://192.168.0.148:8080");
        assert!(imported.enabled);
        assert!(!imported.use_for_gemini);
        // The legacy file has no "opencode" field → defaults to true.
        assert!(imported.use_for_opencode);

        // Re-running is a no-op and the legacy file is left on disk.
        config.migrate_proxies(&runtime_home);
        assert_eq!(config.proxies.len(), 1);
        assert!(runtime_home.join("proxy.json").exists());
        cleanup(&config_path);
    }

    #[test]
    fn migration_v7_to_v8_without_or_corrupt_legacy_file_yields_empty_list() {
        // No legacy file at all.
        let config_path = temp_config_path("proxy-absent");
        let runtime_home = config_path.parent().expect("temp dir").to_path_buf();
        let mut config = AppConfig::default();
        config.config_version = 7;
        config.migrate_proxies(&runtime_home);
        assert_eq!(config.config_version, 8);
        assert!(config.proxies.is_empty());
        cleanup(&config_path);

        // A corrupt legacy file must not block the migration.
        let config_path = temp_config_path("proxy-corrupt");
        let runtime_home = config_path.parent().expect("temp dir").to_path_buf();
        fs::write(runtime_home.join("proxy.json"), "{ not json").expect("write corrupt file");
        let mut config = AppConfig::default();
        config.config_version = 7;
        config.migrate_proxies(&runtime_home);
        assert_eq!(config.config_version, 8);
        assert!(config.proxies.is_empty());
        cleanup(&config_path);
    }

    #[test]
    fn proxy_resolution_follows_contract_order() {
        let mut config = AppConfig::default();
        config.proxies = vec![
            // Enabled but empty url → never matches.
            test_proxy("p-empty", "   ", true, true, true),
            // First enabled match for opencode; gemini flag off.
            test_proxy("p1", "http://one:8080", true, false, true),
            // Would match gemini but is disabled.
            test_proxy("p2", "http://two:8080", false, true, true),
            // First enabled gemini match, later in the list.
            test_proxy("p3", "socks5://three:1080", true, true, true),
        ];

        assert_eq!(
            config.configured_proxy_for("opencode").as_deref(),
            Some("http://one:8080")
        );
        assert_eq!(
            config.configured_proxy_for("gemini").as_deref(),
            Some("socks5://three:1080")
        );
        assert_eq!(config.configured_proxy_for("unknown"), None);

        config.proxies.clear();
        assert_eq!(config.configured_proxy_for("gemini"), None);
        assert_eq!(config.configured_proxy_for("opencode"), None);
    }

    #[test]
    fn effective_proxy_honors_delegator_proxy_env() {
        let guard = EnvGuard::set("DELEGATOR_PROXY", "http://env-proxy:9999");
        let mut config = AppConfig::default();
        config.proxies = vec![test_proxy("p1", "http://one:8080", true, true, true)];

        // Any env url wins for ALL providers.
        assert_eq!(
            config.effective_proxy_for("gemini").as_deref(),
            Some("http://env-proxy:9999")
        );
        assert_eq!(
            config.effective_proxy_for("opencode").as_deref(),
            Some("http://env-proxy:9999")
        );

        // `off` disables the proxy everywhere, even with enabled entries.
        std::env::set_var("DELEGATOR_PROXY", "off");
        assert_eq!(config.effective_proxy_for("gemini"), None);
        assert_eq!(config.effective_proxy_for("opencode"), None);

        // Without the env var the config list rules (guard still holds the lock).
        std::env::remove_var("DELEGATOR_PROXY");
        assert_eq!(
            config.effective_proxy_for("gemini").as_deref(),
            Some("http://one:8080")
        );
        drop(guard);
    }

    #[test]
    fn runtime_home_respects_env_override() {
        let guard = EnvGuard::set("DELEGATOR_RUNTIME_HOME", r"C:\temp\rt-override");
        assert_eq!(runtime_home_dir(), PathBuf::from(r"C:\temp\rt-override"));
        drop(guard);
    }

    #[test]
    fn proxy_url_validation_rejects_unsupported_schemes() {
        // Error paths return before anything is added or saved.
        let mut config = AppConfig::default();
        assert!(config.add_proxy("Прокси", "").is_err());
        assert!(config.add_proxy("Прокси", "ftp://host:21").is_err());
        assert!(config.add_proxy("Прокси", "host:8080").is_err());
        assert!(config.add_proxy("Прокси", "socks5://").is_err());
        assert!(config.proxies.is_empty());

        // Success path, without touching the real config file.
        let entry = validated_proxy_entry("  Мой прокси  ", " https://proxy:3128 ")
            .expect("valid proxy entry");
        assert!(entry.id.starts_with("proxy-"));
        assert_eq!(entry.label, "Мой прокси");
        assert_eq!(entry.url, "https://proxy:3128");
        assert!(entry.enabled && entry.use_for_gemini && entry.use_for_opencode);

        for url in [
            "http://h:1",
            "https://h:1",
            "socks5://h:1",
            "socks5h://h:1",
            "SOCKS5://H:1",
        ] {
            assert!(is_supported_proxy_url(url), "{url} must be supported");
        }
        for url in ["", "socks5://", "ftp://h:1", "h:1"] {
            assert!(!is_supported_proxy_url(url), "{url} must be rejected");
        }
    }

    fn provider_with_models(id: &str, models: &[&str]) -> CustomProvider {
        validated_custom_provider(
            id,
            "",
            "https://api.example.com/v1",
            &models.iter().map(|m| m.to_string()).collect::<Vec<_>>(),
        )
        .expect("valid provider")
    }

    fn enabled_account() -> ProviderApiAccount {
        ProviderApiAccount {
            id: "acc-1".to_string(),
            label: "Ключ 1".to_string(),
            api_key_enc: "opaque-dpapi-blob".to_string(),
            enabled: true,
        }
    }

    #[test]
    fn a_provider_id_may_never_shadow_a_builtin_backend() {
        // `<provider>/<model>` is one namespace: a provider called `opencode`
        // would capture every Zen id in the runtime's split-on-first-slash.
        // `openrouter` is NOT here: it is the OpenRouter.ai preset, whose own key
        // the runtime tries before the built-in route.
        for taken in ["opencode", "gemini", "google", "OpenCode"] {
            let error = validated_custom_provider(taken, "X", "https://h/v1", &[])
                .expect_err("builtin prefix must be refused");
            assert!(error.contains("встроенным"), "{taken}: {error}");
        }
        for bad in ["", "b ai", "b/ai", "провайдер", "b:ai"] {
            assert!(
                validated_custom_provider(bad, "X", "https://h/v1", &[]).is_err(),
                "{bad} must be refused"
            );
        }
        for bad_url in ["", "api.b.ai/v1", "ftp://h/v1"] {
            assert!(
                validated_custom_provider("bai", "B.AI", bad_url, &[]).is_err(),
                "{bad_url} must be refused"
            );
        }

        let provider = validated_custom_provider(
            "  BAI ",
            " B.AI ",
            " https://api.b.ai/v1/ ",
            &["hy3".to_string(), "  ".to_string()],
        )
        .expect("valid provider");
        assert_eq!(provider.id, "bai");
        assert_eq!(provider.label, "B.AI");
        // The trailing slash is stripped so the runtime can append
        // `/chat/completions` without producing a `//`.
        assert_eq!(provider.base_url, "https://api.b.ai/v1");
        assert_eq!(provider.enabled_models, vec!["hy3".to_string()]);
        assert_eq!(provider.known_models, vec!["hy3".to_string()]);
        assert!(provider.accounts.is_empty());
    }

    /// Every model a preset ships must have its OWN row in `model-ratings.json`
    /// — a number, or an explicit `unrated`.
    ///
    /// This is G101 turned into a check. The table is matched by longest
    /// substring, so a model with no row of its own silently inherits the score
    /// of any shorter row it contains: `glm-5.3-flash` took the 150 of
    /// `glm-5.3` and landed in the deep tier. A preset is the one place where
    /// WE choose the ids, so this is also the one place the rule can be
    /// enforced mechanically. Adding a preset now forces a sourcing decision:
    /// find the number, or say `unrated` and mean it.
    #[test]
    fn every_preset_model_has_a_rating_row_of_its_own() {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("scripts")
            .join("model-ratings.json");
        let text = fs::read_to_string(&path).expect("model-ratings.json must be readable");
        let table: serde_json::Value =
            serde_json::from_str(text.trim_start_matches('\u{feff}')).expect("valid json");
        let matches: Vec<String> = table["models"]
            .as_array()
            .expect("models array")
            .iter()
            .filter_map(|row| row["match"].as_str())
            .map(|row| row.to_ascii_lowercase())
            .collect();

        for preset in PROVIDER_PRESETS {
            for model in preset.models {
                let id = model.to_ascii_lowercase();
                assert!(
                    matches.iter().any(|row| row == &id),
                    "{}/{model} has no row in model-ratings.json, so its score comes from \
                     whichever shorter row happens to be a substring of it (G101). Add a row \
                     with a sourced dpr, or `\"dpr\": null, \"confidence\": \"unrated\"`.",
                    preset.id
                );
            }
        }
    }

    #[test]
    fn every_preset_is_addable_and_none_collides_with_a_builtin() {
        for preset in PROVIDER_PRESETS {
            let models: Vec<String> = preset.models.iter().map(|m| m.to_string()).collect();
            let provider =
                validated_custom_provider(preset.id, preset.label, preset.base_url, &models)
                    .unwrap_or_else(|error| panic!("preset {} rejected: {error}", preset.id));
            assert_eq!(provider.id, preset.id);
            assert!(!provider.enabled_models.is_empty());
        }
    }

    #[test]
    fn only_a_provider_with_a_usable_key_contributes_models_to_the_pool() {
        // An id in the pool that can only ever answer 401 costs a whole rung of
        // the ladder, so a keyless or switched-off provider contributes nothing.
        let mut config = AppConfig::default();
        let mut with_key = provider_with_models("bai", &["hy3", "mimo-v2.5"]);
        with_key.accounts.push(enabled_account());
        let keyless = provider_with_models("tokenrouter", &["z-ai/glm-5.3-free"]);
        let mut disabled_key = provider_with_models("third", &["m"]);
        disabled_key.accounts.push(ProviderApiAccount {
            enabled: false,
            ..enabled_account()
        });
        let mut switched_off = provider_with_models("fourth", &["m"]);
        switched_off.accounts.push(enabled_account());
        switched_off.enabled = false;
        config.custom_providers = vec![with_key, keyless, disabled_key, switched_off];

        assert_eq!(
            config.enabled_custom_provider_models(),
            vec!["bai/hy3".to_string(), "bai/mimo-v2.5".to_string()]
        );
    }

    #[test]
    fn toggling_a_model_records_it_as_known_even_when_switched_off() {
        // `known_models` is the catalog's memory: it must remember a model the
        // user deliberately disabled, or the next sync would re-enable it.
        let mut config = AppConfig::default();
        config.custom_providers = vec![provider_with_models("bai", &["hy3"])];

        assert!(config.apply_provider_model_enabled("bai", "qwen3.8-flash", false));
        let provider = config.custom_provider("bai").expect("provider");
        assert!(provider.known_models.contains(&"qwen3.8-flash".to_string()));
        assert!(!provider
            .enabled_models
            .contains(&"qwen3.8-flash".to_string()));

        assert!(config.apply_provider_model_enabled("bai", "qwen3.8-flash", true));
        assert!(config
            .custom_provider("bai")
            .expect("provider")
            .enabled_models
            .contains(&"qwen3.8-flash".to_string()));
        // Idempotent: a repeated toggle must not dirty the file.
        assert!(!config.apply_provider_model_enabled("bai", "qwen3.8-flash", true));
        assert!(!config.apply_provider_model_enabled("nope", "hy3", true));
    }

    #[test]
    fn migration_v12_to_v13_adds_providers_without_touching_the_keys() {
        // v13 only ADDS a field. The DPAPI blobs are opaque here on purpose:
        // the test asserts they come back byte-identical, which is the whole
        // point of not moving them (I19).
        let dir = std::env::temp_dir().join(format!("delegator-cfg-v13-{}", unix_now()));
        fs::create_dir_all(&dir).expect("temp dir");
        let path = dir.join("config.json");
        fs::write(
            &path,
            r#"{
                "config_version": 12,
                "google_accounts": [
                    {"id": "g1", "label": "Main", "api_key_enc": "opaque-google-blob"}
                ],
                "opencode_accounts": [
                    {"id": "o1", "label": "OR", "api_key_enc": "opaque-openrouter-blob"}
                ]
            }"#,
        )
        .expect("write config");

        let cfg = AppConfig::load_from_path(&path);
        assert_eq!(cfg.config_version, 13);
        assert!(cfg.custom_providers.is_empty());
        assert_eq!(cfg.google_accounts[0].api_key_enc, "opaque-google-blob");
        assert_eq!(
            cfg.opencode_accounts[0].api_key_enc,
            "opaque-openrouter-blob"
        );

        let reloaded = AppConfig::load_from_path(&path);
        assert_eq!(reloaded.config_version, 13);
        assert_eq!(
            reloaded.google_accounts[0].api_key_enc,
            "opaque-google-blob"
        );

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn discovery_widens_the_list_to_choose_from_and_never_ticks_a_box() {
        // I8 in one test. A model the provider started serving appears in the
        // list UNTICKED; that is also what tells a brand-new upstream model
        // apart from one the user deliberately switched off.
        let mut config = AppConfig::default();
        config.custom_providers = vec![provider_with_models("bai", &["hy3"])];

        assert!(config.apply_known_provider_models(
            "bai",
            &[
                "hy3".to_string(), // already known — no change
                "glm-5.3-flash".to_string(),
                "  ".to_string(), // blank ids are not models
                "qwen3.8-flash".to_string(),
            ],
        ));
        let provider = config.custom_provider("bai").expect("provider");
        assert_eq!(
            provider.known_models,
            vec![
                "hy3".to_string(),
                "glm-5.3-flash".to_string(),
                "qwen3.8-flash".to_string()
            ]
        );
        // The decisive assertion: nothing new became enabled.
        assert_eq!(provider.enabled_models, vec!["hy3".to_string()]);

        // Idempotent, and an unknown provider is not an error.
        assert!(!config.apply_known_provider_models("bai", &["hy3".to_string()]));
        assert!(!config.apply_known_provider_models("nope", &["x".to_string()]));
    }

    #[test]
    fn the_daily_round_is_due_only_when_there_is_something_to_ask() {
        let now = 2_000_000u64;

        // No providers, nothing to refresh — and firing anyway would mean a
        // probe round on every start for every user who has none.
        let mut config = AppConfig::default();
        assert!(!config.provider_catalog_refresh_due(now));

        // Providers nothing can be asked with. A round for one returns before
        // it stamps, so "due" here meant a round on every poller tick.
        let keyless = provider_with_models("bai", &["hy3"]);
        let mut disabled_key = provider_with_models("bai", &["hy3"]);
        disabled_key.accounts.push(ProviderApiAccount {
            enabled: false,
            ..enabled_account()
        });
        let mut switched_off = provider_with_models("bai", &["hy3"]);
        switched_off.accounts.push(enabled_account());
        switched_off.enabled = false;
        for provider in [keyless, disabled_key, switched_off] {
            config.custom_providers = vec![provider];
            assert!(!config.provider_catalog_refresh_due(now));
        }

        let mut with_key = provider_with_models("bai", &["hy3"]);
        with_key.accounts.push(enabled_account());
        config.custom_providers = vec![with_key];
        // Never refreshed: due immediately.
        assert!(config.provider_catalog_refresh_due(now));

        config.provider_catalog_refreshed_at = now;
        assert!(!config.provider_catalog_refresh_due(now + PROVIDER_CATALOG_INTERVAL_SECS - 1));
        assert!(config.provider_catalog_refresh_due(now + PROVIDER_CATALOG_INTERVAL_SECS));

        // A stamp in the future is a clock that moved backwards, not a reason
        // to stop refreshing forever.
        config.provider_catalog_refreshed_at = now + 10_000;
        assert!(config.provider_catalog_refresh_due(now));
    }

    #[test]
    fn sync_refuses_listings_without_zen_ids() {
        // A fallback/hiccup result (no opencode/* ids at all) must never
        // prune the user's selection — call sites also gate on the live
        // discovery flag, this is the defense-in-depth for that contract.
        let mut config = AppConfig::default();
        let enabled_before = config.enabled_opencode_models.clone();
        let known_before = config.known_opencode_models.clone();

        assert!(!config.sync_opencode_catalog(&[]));
        assert!(!config.sync_opencode_catalog(&["openrouter/only/entry".to_string()]));

        assert_eq!(config.enabled_opencode_models, enabled_before);
        assert_eq!(config.known_opencode_models, known_before);
    }
}
