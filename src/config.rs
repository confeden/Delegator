use crate::crypto::{decrypt_string, encrypt_string};
use directories::ProjectDirs;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
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
    /// Outbound proxies (DEV_CONTRACTS §7a). Always serialized — the mere
    /// presence of the key (even `[]`) makes it authoritative for the
    /// runtime, which then stops consulting the legacy `<RT>\proxy.json`.
    #[serde(default)]
    pub proxies: Vec<ProxyEntry>,
    /// Unix seconds of the last automatic `opencode upgrade` attempt
    /// (0 = never). Keeps the background CLI update to once per 24 h.
    #[serde(default)]
    pub opencode_upgrade_checked_at: u64,
    #[serde(default = "default_ide_states")]
    pub ide_states: HashMap<String, bool>,
    #[serde(default = "default_true")]
    pub delegator_enabled: bool,
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            config_version: 12,
            google_api_key_enc: String::new(),
            google_accounts: Vec::new(),
            opencode_api_key_enc: String::new(),
            opencode_accounts: Vec::new(),
            enabled_gemini_models: default_gemini_models(),
            enabled_opencode_models: default_opencode_models(),
            known_opencode_models: default_known_opencode_models(),
            proxies: Vec::new(),
            opencode_upgrade_checked_at: 0,
            ide_states: default_ide_states(),
            delegator_enabled: true,
        }
    }
}

/// OpenRouter's "auto free" route: it picks whatever free model is available,
/// so it answers when every metered model is rate-limited. The last rung of
/// every fallback ladder, and the reason a quota outage no longer means
/// "Delegator stopped working".
pub const UNIVERSAL_FREE_MODEL: &str = "openrouter/openrouter/free";

impl AppConfig {
    fn config_path() -> Option<PathBuf> {
        let proj_dirs = ProjectDirs::from("com", "Delegator", "DelegatorWin")?;
        let config_dir = proj_dirs.config_dir();
        fs::create_dir_all(config_dir).ok()?;
        Some(config_dir.join("config.json"))
    }

    pub fn load() -> Self {
        match Self::config_path() {
            Some(path) => Self::load_from_path(&path),
            None => Self::default(),
        }
    }

    fn load_from_path(path: &Path) -> Self {
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
                    cfg.save_to_path(path);
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
        default_cfg.save_to_path(path);
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

    fn save_to_path(&self, path: &Path) {
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
    std::env::var_os("LOCALAPPDATA")
        .or_else(|| std::env::var_os("APPDATA"))
        .map(PathBuf::from)
        .unwrap_or_default()
        .join("DelegatorWin")
        .join("runtime")
}

fn new_account_id(prefix: &str) -> Result<String, String> {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_enable_current_opencode_free_models() {
        let config = AppConfig::default();
        assert_eq!(config.config_version, 12);
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
        assert_eq!(cfg.config_version, 12);
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
        assert_eq!(reloaded.config_version, 12);
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
        assert_eq!(cfg.config_version, 12);
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
        assert_eq!(fresh.config_version, 12);
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
        assert_eq!(config.config_version, 12);
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
        assert_eq!(config.config_version, 12);
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

        assert_eq!(config.config_version, 12);
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
        assert_eq!(AppConfig::default().config_version, 12);

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
