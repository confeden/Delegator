use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::process::Stdio;
use std::time::Duration;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelInfo {
    pub id: String,
    pub name: String,
    pub is_free: bool,
    pub provider: String,
}

/// Where the `opencode/*` part of the catalog came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OpenCodeCatalogSource {
    /// Ids were discovered by a successful `opencode models` run.
    LiveCli,
    /// The CLI was missing, timed out, or returned nothing usable; the
    /// built-in catalog was used instead.
    Fallback,
}

#[derive(Debug, Clone)]
pub struct OpenCodeCatalog {
    pub models: Vec<ModelInfo>,
    pub source: OpenCodeCatalogSource,
}

impl OpenCodeCatalog {
    /// Zen ids that are safe to reconcile into the config. Returns None for
    /// a fallback catalog: pruning against the built-in list after a CLI
    /// hiccup would silently drop the user's model selection.
    pub fn zen_ids_for_sync(&self) -> Option<Vec<String>> {
        match self.source {
            OpenCodeCatalogSource::LiveCli => Some(
                self.models
                    .iter()
                    .filter(|model| {
                        model.id.starts_with("opencode/") || is_custom_provider_model(&model.id)
                    })
                    .map(|model| model.id.clone())
                    .collect(),
            ),
            OpenCodeCatalogSource::Fallback => None,
        }
    }
}

#[derive(Debug, Deserialize)]
struct GeminiModelsResponse {
    models: Option<Vec<GeminiModelItem>>,
    #[serde(rename = "nextPageToken")]
    next_page_token: Option<String>,
}

#[derive(Debug, Deserialize)]
struct GeminiModelItem {
    name: String,
    #[serde(rename = "displayName")]
    display_name: Option<String>,
    #[serde(rename = "supportedGenerationMethods", default)]
    supported_generation_methods: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct OpenRouterModelsResponse {
    data: Option<Vec<OpenRouterModelItem>>,
}

#[derive(Debug, Deserialize)]
struct OpenRouterModelItem {
    id: String,
    name: Option<String>,
    pricing: Option<OpenRouterPricing>,
}

#[derive(Debug, Deserialize)]
struct OpenRouterPricing {
    prompt: Option<String>,
    completion: Option<String>,
}

/// Last-known Zen free lineup, used only when `opencode models` cannot be
/// run; the live CLI listing is the source of truth.
const OPENCODE_FREE_MODELS: [(&str, &str); 7] = [
    ("opencode/big-pickle", "Big Pickle"),
    ("opencode/deepseek-v4-flash-free", "DeepSeek V4 Flash Free"),
    ("opencode/laguna-s-2.1-free", "Laguna S 2.1 Free"),
    ("opencode/ling-3.0-flash-free", "Ling-3.0-flash Free"),
    ("opencode/mimo-v2.5-free", "MiMo V2.5 Free"),
    ("opencode/nemotron-3-ultra-free", "Nemotron 3 Ultra Free"),
    ("opencode/north-mini-code-free", "North Mini Code Free"),
];

#[cfg(target_os = "windows")]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;
const OPENCODE_CLI_TIMEOUT: Duration = Duration::from_secs(15);

/// Text-capable Gemini models worth delegating to, newest generation first.
///
/// The `-latest` aliases alone were too narrow: `gemini-3.7-flash` exists and
/// the owner measured it as stronger than what `gemini-pro-latest` currently
/// resolves to (3.1 Pro). Image / TTS / live-audio / customtools variants are
/// deliberately absent — they cannot answer a delegation.
const GEMINI_DELEGATE_MODELS: [(&str, &str); 9] = [
    ("gemini-3.7-flash", "Gemini 3.7 Flash"),
    ("gemini-3.6-flash", "Gemini 3.6 Flash"),
    ("gemini-3.5-flash", "Gemini 3.5 Flash"),
    ("gemini-3.1-pro-preview", "Gemini 3.1 Pro (preview)"),
    ("gemini-3.5-flash-lite", "Gemini 3.5 Flash-Lite"),
    ("gemini-3.1-flash-lite", "Gemini 3.1 Flash-Lite"),
    ("gemini-pro-latest", "Gemini Pro Latest"),
    ("gemini-flash-latest", "Gemini Flash Latest"),
    ("gemini-flash-lite-latest", "Gemini Flash-Lite Latest"),
];

fn builtin_opencode_models() -> Vec<ModelInfo> {
    OPENCODE_FREE_MODELS
        .iter()
        .map(|(id, name)| ModelInfo {
            id: (*id).to_string(),
            name: (*name).to_string(),
            is_free: true,
            provider: "OpenCode Zen".into(),
        })
        .collect()
}

/// Human-readable name for a Zen id: the curated name when we have one,
/// otherwise a title-cased form of the slug (e.g. "opencode/longcat-2.0-free"
/// becomes "Longcat 2.0 Free").
fn opencode_display_name(id: &str) -> String {
    if let Some((_, name)) = OPENCODE_FREE_MODELS.iter().find(|(known, _)| *known == id) {
        return (*name).to_string();
    }
    // A custom provider keeps its full id: «agentrouter/claude-opus-5» is what
    // the user typed into their OpenCode config and what they will look for.
    if is_custom_provider_model(id) {
        return id.to_string();
    }
    let slug = id.strip_prefix("opencode/").unwrap_or(id);
    slug.split(['-', '_'])
        .filter(|part| !part.is_empty())
        .map(|part| {
            let mut chars = part.chars();
            match chars.next() {
                Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
                None => String::new(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// Keeps trimmed lines that are exactly an `opencode/<alias>` id; everything
/// else the CLI prints (google/* ids, local gguf paths, banners) is noise.
/// Providers OpenCode ships with. Their catalogs are either enormous (335
/// `openrouter/*` entries) or reachable elsewhere in Delegator (the Gemini
/// tab), so they are not listed here wholesale. **Anything NOT on this list is
/// a provider the user added to their own OpenCode config** — the whole reason
/// they added it is to use it, so it is discovered and shown first.
const BUILT_IN_PROVIDERS: [&str; 5] = [
    "opencode",
    "openrouter",
    "google",
    "google-vertex",
    "google-vertex-anthropic",
];

/// True for `agentrouter/claude-opus-5` and friends: a provider the user
/// configured themselves.
pub fn is_custom_provider_model(id: &str) -> bool {
    match id.split_once('/') {
        Some((provider, rest)) => {
            !provider.is_empty() && !rest.is_empty() && !BUILT_IN_PROVIDERS.contains(&provider)
        }
        None => false,
    }
}

fn is_clean_model_id(id: &str, allow_slashes: bool) -> bool {
    !id.is_empty()
        && id.chars().all(|c| {
            c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-') || (allow_slashes && c == '/')
        })
}

/// Ids from `opencode models` worth offering: the Zen aliases, the universal
/// free route, and every model of a provider the user added themselves.
///
/// Keeping ONLY `opencode/*` is why `agentrouter/claude-opus-5` was invisible
/// in the app after the owner configured it.
fn parse_opencode_zen_ids(stdout: &str) -> Vec<String> {
    let mut ids: Vec<String> = Vec::new();
    for line in stdout.lines() {
        let id = line.trim();
        let keep = if let Some(alias) = id.strip_prefix("opencode/") {
            is_clean_model_id(alias, false)
        } else if id == crate::config::UNIVERSAL_FREE_MODEL {
            true
        } else if is_custom_provider_model(id) {
            id.split_once('/').is_some_and(|(provider, rest)| {
                is_clean_model_id(provider, false) && is_clean_model_id(rest, true)
            })
        } else {
            false
        };
        if keep && !ids.iter().any(|existing| existing == id) {
            ids.push(id.to_string());
        }
    }
    ids
}

/// Runs `opencode models` and returns the Zen ids it lists, or None on any
/// failure (CLI not installed, spawn error, timeout, non-zero exit, no
/// usable ids) so the caller falls back to the built-in catalog.
async fn discover_opencode_zen_ids() -> Option<Vec<String>> {
    let cli = crate::dependency_service::find_opencode_cli()?;
    let mut command = tokio::process::Command::new(&cli);
    command
        .arg("models")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    #[cfg(target_os = "windows")]
    command.creation_flags(CREATE_NO_WINDOW);

    let output = match tokio::time::timeout(OPENCODE_CLI_TIMEOUT, command.output()).await {
        Ok(Ok(output)) => output,
        Ok(Err(error)) => {
            eprintln!("Failed to run `opencode models`: {error}");
            return None;
        }
        Err(_) => {
            eprintln!(
                "`opencode models` timed out after {}s",
                OPENCODE_CLI_TIMEOUT.as_secs()
            );
            return None;
        }
    };
    if !output.status.success() {
        eprintln!("`opencode models` exited with {}", output.status);
        return None;
    }

    let ids = parse_opencode_zen_ids(&String::from_utf8_lossy(&output.stdout));
    if ids.is_empty() {
        eprintln!("`opencode models` listed no opencode/* ids; using built-in catalog");
        return None;
    }
    Some(ids)
}

fn builtin_gemini_models() -> Vec<ModelInfo> {
    GEMINI_DELEGATE_MODELS
        .iter()
        .map(|(id, name)| ModelInfo {
            id: (*id).to_string(),
            name: (*name).to_string(),
            is_free: false,
            provider: "Google AI".into(),
        })
        .collect()
}

fn is_delegate_compatible_gemini_model(id: &str, methods: &[String]) -> bool {
    let id = id.to_ascii_lowercase();
    if !GEMINI_DELEGATE_MODELS
        .iter()
        .any(|(allowed_id, _)| *allowed_id == id)
        || !methods
            .iter()
            .any(|method| method.eq_ignore_ascii_case("generateContent"))
    {
        return false;
    }

    // These families require Live, media, embedding, agent, or another
    // specialized protocol instead of an ordinary Delegator text request.
    const SPECIALIZED_MARKERS: [&str; 11] = [
        "embedding",
        "image",
        "tts",
        "live",
        "native-audio",
        "robotics",
        "computer-use",
        "deep-research",
        "omni",
        "aqa",
        "vision",
    ];

    !SPECIALIZED_MARKERS.iter().any(|marker| id.contains(marker))
}

pub async fn fetch_gemini_models(api_key: &str) -> Result<Vec<ModelInfo>, String> {
    if api_key.trim().is_empty() {
        return Ok(builtin_gemini_models());
    }

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(12))
        .build()
        .map_err(|e| e.to_string())?;
    let mut result = builtin_gemini_models();
    let mut seen: HashSet<String> = result.iter().map(|model| model.id.clone()).collect();
    let mut page_token: Option<String> = None;

    loop {
        let mut request = client
            .get("https://generativelanguage.googleapis.com/v1beta/models")
            .header("x-goog-api-key", api_key.trim())
            .query(&[("pageSize", "1000")]);
        if let Some(token) = page_token.as_deref() {
            request = request.query(&[("pageToken", token)]);
        }

        let resp = request
            .send()
            .await
            .map_err(|_| "Gemini catalog unavailable".to_string());
        let resp = match resp {
            Ok(resp) => resp,
            Err(_) => return Ok(builtin_gemini_models()),
        };
        if !resp.status().is_success() {
            // The API can be region-restricted even when Gemini CLI OAuth is
            // usable. Keep the control panel configurable with the official
            // delegate-compatible fallback catalog.
            return Ok(builtin_gemini_models());
        }

        let body: GeminiModelsResponse = match resp.json().await {
            Ok(body) => body,
            Err(_) => return Ok(builtin_gemini_models()),
        };

        for m in body.models.unwrap_or_default() {
            let clean_id = m
                .name
                .strip_prefix("models/")
                .unwrap_or(&m.name)
                .to_string();
            if !seen.insert(clean_id.clone())
                || !is_delegate_compatible_gemini_model(&clean_id, &m.supported_generation_methods)
            {
                continue;
            }
            let display = m.display_name.unwrap_or_else(|| clean_id.clone());
            result.push(ModelInfo {
                id: clean_id,
                name: display,
                is_free: false,
                provider: "Google AI".into(),
            });
        }

        page_token = body.next_page_token.filter(|token| !token.is_empty());
        if page_token.is_none() {
            break;
        }
    }

    result.sort_by(|a, b| a.id.cmp(&b.id));

    Ok(result)
}

pub async fn fetch_opencode_models(api_key: &str) -> Result<OpenCodeCatalog, String> {
    // The Zen lineup changes with OpenCode CLI updates, so ask the CLI first
    // and only fall back to the built-in snapshot when it cannot answer.
    let (mut result, source) = match discover_opencode_zen_ids().await {
        Some(ids) => {
            let models = ids
                .iter()
                .map(|id| ModelInfo {
                    id: id.clone(),
                    name: opencode_display_name(id),
                    // A model from the user's own provider is NOT a free Zen
                    // alias: it bills against whatever account they configured,
                    // and the list must not claim otherwise.
                    is_free: !is_custom_provider_model(id),
                    provider: if is_custom_provider_model(id) {
                        id.split_once('/')
                            .map(|(provider, _)| provider.to_string())
                            .unwrap_or_else(|| "свой провайдер".to_string())
                    } else {
                        "OpenCode Zen".into()
                    },
                })
                .collect();
            (models, OpenCodeCatalogSource::LiveCli)
        }
        None => (builtin_opencode_models(), OpenCodeCatalogSource::Fallback),
    };

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(8))
        .build()
        .map_err(|e| e.to_string())?;

    let mut req = client.get("https://openrouter.ai/api/v1/models");
    if !api_key.trim().is_empty() {
        req = req.header("Authorization", format!("Bearer {}", api_key));
    }

    let resp = match req.send().await {
        Ok(resp) => resp,
        Err(_) => {
            return Ok(OpenCodeCatalog {
                models: result,
                source,
            })
        }
    };

    if !resp.status().is_success() {
        return Ok(OpenCodeCatalog {
            models: result,
            source,
        });
    }

    let body: OpenRouterModelsResponse = match resp.json().await {
        Ok(body) => body,
        Err(_) => {
            return Ok(OpenCodeCatalog {
                models: result,
                source,
            })
        }
    };

    let mut seen: HashSet<String> = result.iter().map(|model| model.id.clone()).collect();
    if let Some(models) = body.data {
        for m in models {
            let routed_id = format!("openrouter/{}", m.id);
            if !seen.insert(routed_id.clone()) {
                continue;
            }
            let is_free = if let Some(p) = &m.pricing {
                let prompt_p = p.prompt.as_deref().unwrap_or("1");
                let completion_p = p.completion.as_deref().unwrap_or("1");
                (is_zero_price(prompt_p) && is_zero_price(completion_p)) || m.id.ends_with(":free")
            } else {
                m.id.ends_with(":free")
            };

            let name = m.name.unwrap_or_else(|| m.id.clone());
            result.push(ModelInfo {
                id: routed_id,
                name,
                is_free,
                provider: "OpenRouter/OpenCode".into(),
            });
        }
    }

    // Sort free models first
    result.sort_by(|a, b| b.is_free.cmp(&a.is_free));

    Ok(OpenCodeCatalog {
        models: result,
        source,
    })
}

fn is_zero_price(value: &str) -> bool {
    value.parse::<f64>().is_ok_and(|price| price == 0.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builtin_opencode_models_match_current_free_aliases() {
        let models = builtin_opencode_models();
        assert_eq!(models.len(), 7);
        assert!(models.iter().all(|model| model.is_free));
        assert!(models.iter().any(|model| model.id == "opencode/big-pickle"));
        assert!(models
            .iter()
            .any(|model| model.id == "opencode/ling-3.0-flash-free"));
    }

    #[test]
    fn gemini_filter_keeps_text_delegates_and_rejects_specialized_models() {
        let generate = vec!["generateContent".to_string()];
        assert!(is_delegate_compatible_gemini_model(
            "gemini-flash-latest",
            &generate
        ));
        // Since 0.5.14 the allowlist carries explicit generations too: the
        // owner measured `gemini-3.7-flash` as stronger than what
        // `gemini-pro-latest` resolves to, and a model that cannot be listed
        // can never be chosen as the reviewer.
        assert!(is_delegate_compatible_gemini_model(
            "gemini-3.7-flash",
            &generate
        ));
        assert!(is_delegate_compatible_gemini_model(
            "gemini-3.6-flash",
            &generate
        ));
        // An id nobody vetted still does not pass — the list is an allowlist.
        assert!(!is_delegate_compatible_gemini_model(
            "gemini-4.0-experimental",
            &generate
        ));
        // Specialized protocols stay out even when the id looks ordinary.
        assert!(!is_delegate_compatible_gemini_model(
            "gemini-3.1-flash-image",
            &generate
        ));
        assert!(!is_delegate_compatible_gemini_model(
            "gemini-embedding-001",
            &["embedContent".to_string()]
        ));
    }

    #[test]
    fn zero_price_accepts_numeric_zero_only() {
        assert!(is_zero_price("0"));
        assert!(is_zero_price("0.0"));
        assert!(!is_zero_price("0.000001"));
        assert!(!is_zero_price("free"));
    }

    #[test]
    fn parser_keeps_zen_ids_and_drops_cli_noise() {
        // Real `opencode models` sample (CLI v1.18.15) with the noise the
        // command also prints: other providers, local gguf paths, banners.
        let stdout = "\
Available models:
opencode/big-pickle
opencode/deepseek-v4-flash-free
opencode/laguna-s-2.1-free
opencode/ling-3.0-tiny-free
opencode/longcat-2.0-free
opencode/mimo-v2.5-free
opencode/nemotron-3-ultra-free
opencode/north-mini-code-free
google/gemini-flash-latest
C:\\models\\local-llama.gguf
opencode/
opencode/bad id with spaces
opencode/deepseek-v4-flash-free
";
        let ids = parse_opencode_zen_ids(stdout);
        assert_eq!(
            ids,
            vec![
                "opencode/big-pickle",
                "opencode/deepseek-v4-flash-free",
                "opencode/laguna-s-2.1-free",
                "opencode/ling-3.0-tiny-free",
                "opencode/longcat-2.0-free",
                "opencode/mimo-v2.5-free",
                "opencode/nemotron-3-ultra-free",
                "opencode/north-mini-code-free",
            ]
        );
    }

    #[test]
    fn custom_providers_are_discovered_and_labelled() {
        // The owner added AgentRouter to their OpenCode config and could not
        // find it in Delegator: the parser kept `opencode/*` only.
        let stdout = concat!(
            "opencode/big-pickle
",
            "agentrouter/claude-opus-5
",
            "agentrouter-openai/gpt-5.6-sol
",
            "openrouter/openrouter/free
",
            "openrouter/google/gemma-4-31b-it:free
",
            "google/gemini-3.7-flash
",
            "not a model line
"
        );
        let ids = parse_opencode_zen_ids(stdout);
        assert!(ids.contains(&"agentrouter/claude-opus-5".to_string()));
        assert!(ids.contains(&"agentrouter-openai/gpt-5.6-sol".to_string()));
        assert!(ids.contains(&"opencode/big-pickle".to_string()));
        assert!(ids.contains(&crate::config::UNIVERSAL_FREE_MODEL.to_string()));
        // The 335-model OpenRouter catalog and Google (its own tab) stay out.
        assert!(!ids
            .iter()
            .any(|id| id.starts_with("openrouter/google/") || id.starts_with("google/")));

        assert!(is_custom_provider_model("agentrouter/claude-opus-5"));
        assert!(!is_custom_provider_model("opencode/big-pickle"));
        assert!(!is_custom_provider_model(
            crate::config::UNIVERSAL_FREE_MODEL
        ));
        assert!(!is_custom_provider_model("gemini-3.7-flash"));
        // The full id is the display name: it is what the user typed.
        assert_eq!(
            opencode_display_name("agentrouter/claude-opus-5"),
            "agentrouter/claude-opus-5"
        );
    }

    #[test]
    fn display_names_prefer_curated_then_title_case_the_slug() {
        assert_eq!(
            opencode_display_name("opencode/deepseek-v4-flash-free"),
            "DeepSeek V4 Flash Free"
        );
        assert_eq!(
            opencode_display_name("opencode/ling-3.0-tiny-free"),
            "Ling 3.0 Tiny Free"
        );
        assert_eq!(
            opencode_display_name("opencode/longcat-2.0-free"),
            "Longcat 2.0 Free"
        );
    }

    #[test]
    fn fallback_catalog_never_offers_ids_for_sync() {
        let fallback = OpenCodeCatalog {
            models: builtin_opencode_models(),
            source: OpenCodeCatalogSource::Fallback,
        };
        assert!(fallback.zen_ids_for_sync().is_none());

        let live = OpenCodeCatalog {
            models: builtin_opencode_models(),
            source: OpenCodeCatalogSource::LiveCli,
        };
        let ids = live.zen_ids_for_sync().expect("live catalog offers ids");
        assert_eq!(ids.len(), 7);
        assert!(ids.iter().all(|id| id.starts_with("opencode/")));
    }

    /// Runs the REAL `opencode models` on this machine and prints what the tab
    /// will show. Ignored in CI; `cargo test -- --ignored --nocapture`.
    #[tokio::test]
    #[ignore]
    async fn live_cli_lists_what_this_machine_offers() {
        let catalog = fetch_opencode_models("").await.expect("catalog");
        println!(
            "source: {:?}, models: {}",
            catalog.source,
            catalog.models.len()
        );
        for model in &catalog.models {
            println!(
                "  {:<40} free={} provider={}",
                model.id, model.is_free, model.provider
            );
        }
    }

    #[tokio::test]
    #[ignore = "requires the OpenCode CLI on PATH; run with `cargo test -- --ignored`"]
    async fn live_cli_discovery_lists_zen_models() {
        let ids = discover_opencode_zen_ids()
            .await
            .expect("OpenCode CLI must be installed and answer `opencode models`");
        assert!(!ids.is_empty());
        assert!(ids.iter().all(|id| id.starts_with("opencode/")));
    }
}
