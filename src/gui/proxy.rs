//! «Прокси» tab support: async connectivity test through a user-configured
//! proxy (DEV_CONTRACTS §7a). The PowerShell runtime does its own proxy
//! resolution; this module only powers the GUI's «Проверить» button.

use std::time::Duration;

const PROXY_TEST_TIMEOUT: Duration = Duration::from_secs(10);
/// Neutral endpoint: any HTTP answer (even 4xx) proves the tunnel works.
const GENERAL_TEST_URL: &str = "https://openrouter.ai/api/v1/models";
/// Google may geo-block a proxy egress that is fine for everyone else, so
/// proxies marked for Gemini get a second, Google-specific probe.
const GOOGLE_TEST_URL: &str = "https://generativelanguage.googleapis.com/v1beta/models";

/// Outcome of the Google-side probe.
#[derive(Debug, Clone)]
pub enum GoogleProbe {
    /// Any HTTP answer without the geo-block marker: the tunnel works
    /// (401/403 without an API key still count — the request got through).
    HttpAnswer(u16),
    /// HTTP error whose body mentions "location" («User location is not
    /// supported», FAILED_PRECONDITION): the tunnel works but Google rejects
    /// the proxy's egress region — Gemini will not work through this proxy.
    GeoBlocked(u16),
    /// Transport-level failure through the proxy.
    Failed(String),
}

#[derive(Debug, Clone)]
pub struct ProxyTestResult {
    /// `ProxyEntry::id` this result belongs to.
    pub id: String,
    /// GET openrouter.ai through the proxy: Ok(status) for ANY HTTP answer,
    /// Err(short Russian message) for transport errors.
    pub general: Result<u16, String>,
    /// Present only when the proxy is marked for Gemini.
    pub google: Option<GoogleProbe>,
}

/// Runs the connectivity test through `proxy_url`. Never panics; every
/// failure is folded into the result so the GUI can render it inline.
pub async fn run_proxy_test(
    id: String,
    proxy_url: String,
    test_google: bool,
    google_api_key: String,
) -> ProxyTestResult {
    let client = match build_proxy_client(&proxy_url) {
        Ok(client) => client,
        Err(error) => {
            return ProxyTestResult {
                id,
                general: Err(error),
                google: None,
            }
        }
    };

    let general = match client.get(GENERAL_TEST_URL).send().await {
        Ok(response) => Ok(response.status().as_u16()),
        Err(error) => Err(short_reqwest_error(&error)),
    };

    let google = if test_google {
        let mut request = client.get(GOOGLE_TEST_URL);
        let google_api_key = google_api_key.trim();
        if !google_api_key.is_empty() {
            // With a key the probe exercises the same auth path the runtime
            // uses; without one Google still answers (403), which is enough
            // to prove the tunnel.
            request = request.header("x-goog-api-key", google_api_key);
        }
        Some(match request.send().await {
            Ok(response) => {
                let status = response.status().as_u16();
                let body = response.text().await.unwrap_or_default();
                classify_google_probe(status, &body)
            }
            Err(error) => GoogleProbe::Failed(short_reqwest_error(&error)),
        })
    } else {
        None
    };

    ProxyTestResult {
        id,
        general,
        google,
    }
}

/// `reqwest::Proxy::all` covers http/https natively and socks5/socks5h via
/// the crate's `socks` feature (enabled in Cargo.toml).
fn build_proxy_client(proxy_url: &str) -> Result<reqwest::Client, String> {
    let proxy = reqwest::Proxy::all(proxy_url)
        .map_err(|error| format!("некорректный URL прокси ({error})"))?;
    reqwest::Client::builder()
        .timeout(PROXY_TEST_TIMEOUT)
        .proxy(proxy)
        .build()
        .map_err(|error| format!("не удалось создать HTTP-клиент ({error})"))
}

/// Heuristic per DEV_CONTRACTS §7a: an HTTP error whose body mentions
/// "location" means the tunnel works but the egress region is rejected.
fn classify_google_probe(status: u16, body: &str) -> GoogleProbe {
    let is_error = !(200..300).contains(&status);
    if is_error && body.to_ascii_lowercase().contains("location") {
        GoogleProbe::GeoBlocked(status)
    } else {
        GoogleProbe::HttpAnswer(status)
    }
}

/// Compact user-facing transport-error text: the root cause only, truncated.
fn short_reqwest_error(error: &reqwest::Error) -> String {
    if error.is_timeout() {
        return format!("таймаут ({} с)", PROXY_TEST_TIMEOUT.as_secs());
    }
    let mut source: &dyn std::error::Error = error;
    while let Some(next) = source.source() {
        source = next;
    }
    truncate_chars(&source.to_string(), 120)
}

fn truncate_chars(text: &str, max_chars: usize) -> String {
    if text.chars().count() <= max_chars {
        return text.to_string();
    }
    let truncated: String = text.chars().take(max_chars).collect();
    format!("{truncated}…")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn google_probe_flags_geo_block_only_on_error_with_location() {
        // The real geo-block shape: 400 FAILED_PRECONDITION.
        assert!(matches!(
            classify_google_probe(
                400,
                r#"{"error":{"message":"User location is not supported for the API use.","status":"FAILED_PRECONDITION"}}"#
            ),
            GoogleProbe::GeoBlocked(400)
        ));
        // A successful answer is never geo-blocked, whatever the body says.
        assert!(matches!(
            classify_google_probe(200, "models list mentioning location"),
            GoogleProbe::HttpAnswer(200)
        ));
        // Key errors through a working tunnel stay plain HTTP answers.
        assert!(matches!(
            classify_google_probe(403, "API key not valid. Please pass a valid API key."),
            GoogleProbe::HttpAnswer(403)
        ));
        assert!(matches!(
            classify_google_probe(400, "Bad Request"),
            GoogleProbe::HttpAnswer(400)
        ));
    }

    #[test]
    fn proxy_client_supports_all_contract_schemes() {
        // socks5/socks5h succeeding here is what guards the reqwest `socks`
        // feature. Unsupported schemes (ftp://, no scheme) are NOT rejected by
        // reqwest 0.12 at build time — the GUI gates the «Проверить» button on
        // `is_supported_proxy_url` instead.
        for url in [
            "http://127.0.0.1:8080",
            "https://127.0.0.1:8080",
            "socks5://127.0.0.1:1080",
            "socks5h://127.0.0.1:1080",
        ] {
            assert!(build_proxy_client(url).is_ok(), "{url} must build");
        }
    }

    #[test]
    fn truncate_keeps_short_text_and_cuts_on_char_boundaries() {
        assert_eq!(truncate_chars("короткий текст", 120), "короткий текст");
        let long = "х".repeat(200);
        let cut = truncate_chars(&long, 120);
        assert_eq!(cut.chars().count(), 121); // 120 + ellipsis
        assert!(cut.ends_with('…'));
    }
}
