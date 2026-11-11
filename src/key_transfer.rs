//! Portable clipboard format. Never copy Keychain references or DPAPI blobs:
//! the recipient stores each secret again with its own platform crypto.
use crate::config::{
    new_account_id, validated_custom_provider, AppConfig, CustomProvider, GoogleApiAccount,
    OpenCodeApiAccount, ProviderApiAccount,
};
use crate::crypto::{decrypt_string, encrypt_string};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

const HEADER: &str = "DELEGATOR-API-KEYS/1\n";
const MAX_BYTES: usize = 1024 * 1024;

// Deliberately no Debug: these values contain plaintext credentials.
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Bundle {
    google: Vec<Key>,
    opencode: Vec<Key>,
    providers: Vec<Provider>,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Key {
    label: String,
    key: String,
    enabled: bool,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Provider {
    id: String,
    label: String,
    base_url: String,
    enabled: bool,
    models: Vec<String>,
    keys: Vec<Key>,
}

pub fn export(config: &AppConfig) -> Result<String, String> {
    export_with(config, decrypt_string)
}

pub fn import(config: &mut AppConfig, text: &str) -> Result<usize, String> {
    import_with(config, text, decrypt_string, encrypt_string)
}

fn export_with(
    config: &AppConfig,
    decrypt: impl Fn(&str) -> Result<String, String>,
) -> Result<String, String> {
    let key = |label: &str, encrypted: &str, enabled| {
        let secret = decrypt(encrypted)
            .map_err(|_| "Не удалось прочитать один из ключей. Перенос отменён.".to_string())?;
        if secret.trim().is_empty() {
            return Err("Обнаружен пустой сохранённый ключ. Перенос отменён.".into());
        }
        Ok(Key {
            label: label.to_owned(),
            key: secret,
            enabled,
        })
    };
    let bundle = Bundle {
        google: config
            .google_accounts
            .iter()
            .map(|a| key(&a.label, &a.api_key_enc, a.enabled))
            .collect::<Result<_, _>>()?,
        opencode: config
            .opencode_accounts
            .iter()
            .map(|a| key(&a.label, &a.api_key_enc, a.enabled))
            .collect::<Result<_, _>>()?,
        providers: config
            .custom_providers
            .iter()
            .filter(|p| !p.accounts.is_empty())
            .map(|p| {
                Ok(Provider {
                    id: p.id.clone(),
                    label: p.label.clone(),
                    base_url: p.base_url.clone(),
                    enabled: p.enabled,
                    models: p.enabled_models.clone(),
                    keys: p
                        .accounts
                        .iter()
                        .map(|a| key(&a.label, &a.api_key_enc, a.enabled))
                        .collect::<Result<_, String>>()?,
                })
            })
            .collect::<Result<_, String>>()?,
    };
    if bundle.google.len()
        + bundle.opencode.len()
        + bundle.providers.iter().map(|p| p.keys.len()).sum::<usize>()
        == 0
    {
        return Err("Нет сохранённых API-ключей для переноса.".into());
    }
    let json = serde_json::to_string(&bundle)
        .map_err(|_| "Не удалось подготовить ключи к переносу.".to_string())?;
    if HEADER.len() + json.len() > MAX_BYTES {
        return Err("Слишком много данных для переноса через буфер обмена.".into());
    }
    Ok(format!("{HEADER}{json}"))
}

fn import_with(
    config: &mut AppConfig,
    text: &str,
    decrypt: impl Fn(&str) -> Result<String, String>,
    encrypt: impl Fn(&str) -> Result<String, String>,
) -> Result<usize, String> {
    if text.len() > MAX_BYTES {
        return Err("Пакет ключей превышает 1 МБ.".into());
    }
    let json = text
        .trim()
        .strip_prefix(HEADER.trim_end())
        .and_then(|rest| {
            rest.strip_prefix("\r\n")
                .or_else(|| rest.strip_prefix('\n'))
        })
        .ok_or("Вставьте пакет ключей Delegator версии 1.")?;
    // Parser diagnostics may quote input, so never expose them to UI/logs.
    let bundle: Bundle = serde_json::from_str(json)
        .map_err(|_| "Некорректный пакет ключей Delegator.".to_string())?;
    let mut ids = HashSet::new();
    for p in &bundle.providers {
        validated_custom_provider(&p.id, &p.label, &p.base_url, &p.models)?;
        if p.id != p.id.trim().to_ascii_lowercase() || !ids.insert(&p.id) {
            return Err("Повторный или некорректный идентификатор провайдера.".into());
        }
        let url = reqwest::Url::parse(&p.base_url)
            .map_err(|_| "Некорректный адрес API в пакете.".to_string())?;
        if url.host_str().is_none()
            || !url.username().is_empty()
            || url.password().is_some()
            || url.query().is_some()
            || url.fragment().is_some()
        {
            return Err("Некорректный адрес API в пакете.".into());
        }
        if let Some(existing) = config.custom_provider(&p.id) {
            if existing.base_url.trim_end_matches('/') != p.base_url.trim_end_matches('/') {
                return Err("Адрес существующего провайдера отличается. Импорт отменён.".into());
            }
        }
    }
    let keys = bundle
        .google
        .iter()
        .chain(&bundle.opencode)
        .chain(bundle.providers.iter().flat_map(|p| &p.keys));
    for k in keys {
        if k.label.trim().is_empty()
            || k.key.trim().is_empty()
            || k.key.trim().chars().any(char::is_whitespace)
        {
            return Err("В пакете есть пустое название или некорректный API-ключ.".into());
        }
    }

    // Work on a clone: malformed input or a crypto failure must not leave a
    // half-imported configuration. Existing account settings always win.
    let mut next = config.clone();
    let mut count = 0;
    let prepare = |keys: Vec<Key>,
                   stored: Vec<&str>,
                   prefix: &str|
     -> Result<Vec<(String, Key, String)>, String> {
        let mut known = HashSet::new();
        for reference in stored {
            known.insert(decrypt(reference).map_err(|_| {
                "Не удалось прочитать существующий ключ. Импорт отменён.".to_string()
            })?);
        }
        let mut result = Vec::new();
        for mut k in keys {
            k.key = k.key.trim().to_string();
            k.label = k.label.trim().to_string();
            if known.insert(k.key.clone()) {
                let encrypted = encrypt(&k.key)
                    .map_err(|_| "Не удалось сохранить ключ в хранилище устройства.".to_string())?;
                result.push((new_account_id(prefix)?, k, encrypted));
            }
        }
        Ok(result)
    };
    for (id, k, api_key_enc) in prepare(
        bundle.google,
        next.google_accounts
            .iter()
            .map(|a| a.api_key_enc.as_str())
            .collect(),
        "google",
    )? {
        next.google_accounts.push(GoogleApiAccount {
            id,
            label: k.label,
            api_key_enc,
            enabled: k.enabled,
        });
        count += 1;
    }
    for (id, k, api_key_enc) in prepare(
        bundle.opencode,
        next.opencode_accounts
            .iter()
            .map(|a| a.api_key_enc.as_str())
            .collect(),
        "opencode",
    )? {
        next.opencode_accounts.push(OpenCodeApiAccount {
            id,
            label: k.label,
            api_key_enc,
            enabled: k.enabled,
        });
        count += 1;
    }
    for p in bundle.providers {
        if next.custom_provider(&p.id).is_none() {
            let mut provider: CustomProvider =
                validated_custom_provider(&p.id, &p.label, &p.base_url, &p.models)?;
            provider.enabled = p.enabled;
            next.custom_providers.push(provider);
        }
        let provider = next
            .custom_providers
            .iter_mut()
            .find(|v| v.id == p.id)
            .unwrap();
        for (id, k, api_key_enc) in prepare(
            p.keys,
            provider
                .accounts
                .iter()
                .map(|a| a.api_key_enc.as_str())
                .collect(),
            &p.id,
        )? {
            provider.accounts.push(ProviderApiAccount {
                id,
                label: k.label,
                api_key_enc,
                enabled: k.enabled,
            });
            count += 1;
        }
    }
    *config = next;
    Ok(count)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn encrypt(s: &str) -> Result<String, String> {
        Ok(format!("local:{s}"))
    }
    fn decrypt(s: &str) -> Result<String, String> {
        s.strip_prefix("local:")
            .map(str::to_owned)
            .ok_or("unreadable".into())
    }
    fn source() -> AppConfig {
        let mut config = AppConfig::default();
        config.google_accounts.push(GoogleApiAccount {
            id: "old-google".into(),
            label: "Рабочий".into(),
            api_key_enc: encrypt("google-test-secret").unwrap(),
            enabled: false,
        });
        config.opencode_accounts.push(OpenCodeApiAccount {
            id: "old-opencode".into(),
            label: "Router".into(),
            api_key_enc: encrypt("router-test-secret").unwrap(),
            enabled: true,
        });
        let mut provider = validated_custom_provider(
            "example",
            "Example",
            "https://example.com/v1",
            &["model-1".into()],
        )
        .unwrap();
        provider.enabled = false;
        provider.accounts.push(ProviderApiAccount {
            id: "old-custom".into(),
            label: "Custom".into(),
            api_key_enc: encrypt("custom-test-secret").unwrap(),
            enabled: true,
        });
        config.custom_providers.push(provider);
        config
    }
    fn snapshot(c: &AppConfig) -> String {
        serde_json::to_string(c).unwrap()
    }

    #[test]
    fn portable_roundtrip_reencrypts_all_key_kinds_and_preserves_disabled_state() {
        let text = export_with(&source(), decrypt).unwrap();
        assert!(!text.contains("local:"));
        assert!(!text.contains("old-google"));
        let mut target = AppConfig::default();
        let count = import_with(&mut target, &text, decrypt, |s| {
            Ok(format!("device-two:{s}"))
        })
        .unwrap();
        assert_eq!(count, 3);
        assert_eq!(target.google_accounts[0].label, "Рабочий");
        assert!(!target.google_accounts[0].enabled);
        assert_ne!(target.google_accounts[0].id, "old-google");
        assert_eq!(
            target.google_accounts[0].api_key_enc,
            "device-two:google-test-secret"
        );
        assert_eq!(
            target.opencode_accounts[0].api_key_enc,
            "device-two:router-test-secret"
        );
        let p = target.custom_provider("example").unwrap();
        assert!(!p.enabled);
        assert_eq!(p.enabled_models, ["model-1"]);
        assert_eq!(p.accounts[0].api_key_enc, "device-two:custom-test-secret");
    }

    #[test]
    fn repeated_import_skips_duplicates_and_keeps_existing_settings() {
        let text = export_with(&source(), decrypt).unwrap();
        let mut target = AppConfig::default();
        assert_eq!(
            import_with(&mut target, &text, decrypt, encrypt).unwrap(),
            3
        );
        target.google_accounts[0].label = "Local name".into();
        target.google_accounts[0].enabled = true;
        let p = target
            .custom_providers
            .iter_mut()
            .find(|p| p.id == "example")
            .unwrap();
        p.enabled_models.clear();
        p.enabled = true;
        let before = snapshot(&target);
        assert_eq!(
            import_with(&mut target, &text, decrypt, encrypt).unwrap(),
            0
        );
        assert_eq!(snapshot(&target), before);
    }

    #[test]
    fn invalid_packages_do_not_modify_config_or_expose_input() {
        let good = export_with(&source(), decrypt).unwrap();
        let invalid = [
            "secret-that-must-not-appear-in-errors".to_string(),
            good.replace("/1\n", "/2\n"),
            good.replace("google-test-secret", ""),
            good.replace("https://example.com/v1", "file:///etc/passwd"),
            good.replace(
                "https://example.com/v1",
                "https://user:secret@example.com/v1",
            ),
            format!("{HEADER}{{\"key\":\"secret-that-must-not-appear-in-errors\"}}"),
            "x".repeat(MAX_BYTES + 1),
        ];
        for text in invalid {
            let mut target = AppConfig::default();
            let before = snapshot(&target);
            let error = import_with(&mut target, &text, decrypt, encrypt).unwrap_err();
            assert!(!error.contains("secret-that-must-not"));
            assert_eq!(snapshot(&target), before);
        }
    }

    #[test]
    fn provider_endpoint_conflict_aborts_before_storing_secrets() {
        let text = export_with(&source(), decrypt).unwrap();
        let mut target = source();
        target
            .custom_providers
            .iter_mut()
            .find(|p| p.id == "example")
            .unwrap()
            .base_url = "https://other.example/v1".into();
        let before = snapshot(&target);
        assert!(import_with(&mut target, &text, decrypt, |_| panic!("must not encrypt")).is_err());
        assert_eq!(snapshot(&target), before);
    }

    #[test]
    fn crypto_failure_does_not_partially_import_or_leak_secret() {
        let text = export_with(&source(), decrypt).unwrap();
        let mut target = AppConfig::default();
        let before = snapshot(&target);
        let error = import_with(&mut target, &text, decrypt, |s| {
            if s == "custom-test-secret" {
                Err(s.into())
            } else {
                encrypt(s)
            }
        })
        .unwrap_err();
        assert!(!error.contains("custom-test-secret"));
        assert_eq!(snapshot(&target), before);
        assert!(export_with(&source(), |_| Err("secret".into())).is_err());
    }

    #[test]
    fn windows_clipboard_line_endings_are_accepted() {
        let text = export_with(&source(), decrypt)
            .unwrap()
            .replace('\n', "\r\n");
        let mut target = AppConfig::default();
        assert_eq!(
            import_with(&mut target, &text, decrypt, encrypt).unwrap(),
            3
        );
    }

    #[test]
    fn empty_export_is_reported() {
        assert!(export_with(&AppConfig::default(), decrypt).is_err());
    }
}
