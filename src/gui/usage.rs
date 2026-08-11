use serde::Deserialize;
use std::time::Duration;

const USAGE_URL: &str = "http://127.0.0.1:1380/api/usage";

/// Shape of GET /api/usage?days=N (DEV_CONTRACTS §3). Every field is optional
/// or defaulted so a partial or evolving core response still renders.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct UsageReport {
    pub days: u32,
    pub today: UsageTotals,
    pub daily: Vec<UsageDay>,
    pub by_model: Vec<UsageModelRow>,
    pub saved_tokens_total: Option<u64>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct UsageTotals {
    pub requests: Option<u64>,
    pub prompt_tokens: Option<u64>,
    pub completion_tokens: Option<u64>,
    pub total_tokens: Option<u64>,
    pub cost: Option<f64>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct UsageDay {
    pub date: String,
    pub requests: Option<u64>,
    pub total_tokens: Option<u64>,
    pub cost: Option<f64>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct UsageModelRow {
    pub model: String,
    pub provider: String,
    pub requests: Option<u64>,
    pub prompt_tokens: Option<u64>,
    pub completion_tokens: Option<u64>,
    pub total_tokens: Option<u64>,
    pub cost: Option<f64>,
}

/// Fetches usage aggregates from the local core. Error strings are
/// user-facing Russian (they end up in the «Статистика» tab).
pub async fn fetch_usage(days: u32) -> Result<UsageReport, String> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        .build()
        .map_err(|error| format!("не удалось создать HTTP-клиент ({error})"))?;
    let response = client
        .get(format!("{USAGE_URL}?days={days}"))
        .send()
        .await
        .map_err(|_| "ядро Delegator не отвечает".to_string())?;
    if !response.status().is_success() {
        return Err(format!(
            "ядро Delegator вернуло ошибку HTTP {}",
            response.status().as_u16()
        ));
    }
    response
        .json::<UsageReport>()
        .await
        .map_err(|_| "не удалось разобрать ответ ядра".to_string())
}

/// "12345" -> "12 345"; None -> "—" (the value was not reported).
pub fn format_count(value: Option<u64>) -> String {
    match value {
        Some(value) => group_digits(value),
        None => "—".to_string(),
    }
}

fn group_digits(value: u64) -> String {
    let digits: Vec<char> = value.to_string().chars().collect();
    let mut grouped = String::with_capacity(digits.len() + digits.len() / 3);
    for (index, digit) in digits.iter().enumerate() {
        if index > 0 && (digits.len() - index) % 3 == 0 {
            grouped.push(' ');
        }
        grouped.push(*digit);
    }
    grouped
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn usage_report_parses_contract_shape() {
        let json = r#"{
            "days": 7,
            "today": {"requests": 12, "promptTokens": 1000, "completionTokens": 2000,
                      "totalTokens": 3000, "cost": 0.0,
                      "byProvider": {"gemini": {"requests": 8, "totalTokens": 2100}},
                      "byClient": {"core": {"requests": 4, "totalTokens": 900}}},
            "daily": [{"date": "2026-08-10", "requests": 12, "totalTokens": 3000, "cost": 0.0}],
            "byModel": [{"model": "gemini-flash-latest", "provider": "gemini", "requests": 9,
                         "promptTokens": 800, "completionTokens": 1500, "totalTokens": 2300,
                         "cost": 0.0}],
            "savedTokensTotal": 123456
        }"#;
        let report: UsageReport = serde_json::from_str(json).expect("contract shape parses");
        assert_eq!(report.days, 7);
        assert_eq!(report.today.requests, Some(12));
        assert_eq!(report.today.total_tokens, Some(3000));
        assert_eq!(report.daily.len(), 1);
        assert_eq!(report.daily[0].date, "2026-08-10");
        assert_eq!(report.by_model.len(), 1);
        assert_eq!(report.by_model[0].model, "gemini-flash-latest");
        assert_eq!(report.by_model[0].total_tokens, Some(2300));
        assert_eq!(report.saved_tokens_total, Some(123456));
    }

    #[test]
    fn usage_report_tolerates_missing_and_null_fields() {
        let report: UsageReport =
            serde_json::from_str(r#"{"today":{"requests":null},"byModel":[{"model":"m"}]}"#)
                .expect("partial shape parses");
        assert_eq!(report.today.requests, None);
        assert_eq!(report.by_model.len(), 1);
        assert_eq!(report.by_model[0].provider, "");
        assert_eq!(report.saved_tokens_total, None);

        let empty: UsageReport = serde_json::from_str("{}").expect("empty object parses");
        assert!(empty.daily.is_empty());
        assert!(empty.by_model.is_empty());
    }

    #[test]
    fn format_count_groups_digits_and_marks_missing_values() {
        assert_eq!(format_count(Some(0)), "0");
        assert_eq!(format_count(Some(999)), "999");
        assert_eq!(format_count(Some(1000)), "1 000");
        assert_eq!(format_count(Some(1234567)), "1 234 567");
        assert_eq!(format_count(None), "—");
    }
}
