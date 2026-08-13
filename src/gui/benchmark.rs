//! «Бенчмарк» tab: the last benchmark result and its export.
//!
//! The GUI never runs the benchmark itself — that is driven from the IDE chat
//! by `-benchmark`, because only the IDE can make the user's own model answer.
//! Here we read what the core stored (DEV_CONTRACTS §10) and offer the two
//! export formats to the Desktop.

use serde::Deserialize;
use std::time::Duration;

const LAST_URL: &str = "http://127.0.0.1:1380/api/benchmark/last";
const STATUS_URL: &str = "http://127.0.0.1:1380/api/benchmark/status";
const EXPORT_URL: &str = "http://127.0.0.1:1380/api/benchmark/export";

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct BenchmarkEnvelope {
    pub benchmark_version: String,
    pub report: Option<BenchmarkReport>,
}

/// Live state of a run in flight (GET /api/benchmark/status). `active` is None
/// between runs — the benchmark is driven from the IDE chat, not from here.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct StatusEnvelope {
    pub benchmark_version: String,
    pub active: Option<RunStatus>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RunStatus {
    pub run_id: String,
    pub mode: String,
    pub model_label: String,
    pub tasks_total: u32,
    pub answered_model: u32,
    pub answered_delegator: u32,
    pub current_task: u32,
    pub current_title: String,
    pub stage: String,
    pub elapsed_sec: u64,
    pub idle_sec: u64,
}

impl RunStatus {
    /// 0.0..1.0 over both arms, so the bar does not jump backwards when the
    /// Delegator arm lags one task behind the model arm.
    pub fn fraction(&self) -> f32 {
        if self.tasks_total == 0 {
            return 0.0;
        }
        let arms = if self.mode == "compare" { 2 } else { 1 };
        let done = self.answered_model
            + if arms == 2 {
                self.answered_delegator
            } else {
                0
            };
        (done as f32 / (self.tasks_total * arms) as f32).clamp(0.0, 1.0)
    }

    /// What the user reads while waiting.
    pub fn line(&self) -> String {
        let task = if self.current_task == 0 {
            "подготовка".to_string()
        } else {
            format!("задача {} из {}", self.current_task, self.tasks_total)
        };
        let stage = match self.stage.as_str() {
            "waiting" => "ждём ответ вашей модели",
            "model-answer" => "ответ модели принят",
            "delegator" => "Delegator решает ту же задачу",
            "finished" => "подводим итоги",
            _ => "выполняется",
        };
        format!("{task} · {stage} · {}", format_duration(self.elapsed_sec))
    }
}

/// 95 -> «1 мин 35 с».
pub fn format_duration(seconds: u64) -> String {
    if seconds < 60 {
        return format!("{seconds} с");
    }
    format!("{} мин {} с", seconds / 60, seconds % 60)
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct BenchmarkReport {
    pub benchmark_version: String,
    pub delegator_version: String,
    pub mode: String,
    pub model_label: String,
    pub finished_at: String,
    pub seed: i64,
    pub max_points: u32,
    pub tasks: Vec<BenchmarkTask>,
    pub totals: BenchmarkTotals,
    pub counts: Option<BenchmarkCounts>,
    /// Score per level and per category — the answer to «где отставание».
    pub profile: Option<BenchmarkProfile>,
    /// The paired test and how much evidence a proof would still need.
    pub stats: Option<BenchmarkStats>,
    pub verdict: String,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct BenchmarkTask {
    pub index: u32,
    pub title: String,
    pub level: String,
    pub points: u32,
    pub model: Option<ArmResult>,
    pub delegator: Option<ArmResult>,
    pub winner: String,
}

/// One arm's result on one task. Since 1.3 the score is the share of the task's
/// named constraints the answer satisfied, so `points` is fractional.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ArmResult {
    pub passed: bool,
    pub points: f64,
    pub max_points: u32,
    pub score: f64,
    pub checks_passed: u32,
    pub checks_total: u32,
    pub checks: Vec<CheckResult>,
    pub note: String,
}

impl ArmResult {
    /// «2.3/3 (7/9)» — points plus the constraints they came from.
    pub fn cell(&self, max_points: u32) -> String {
        if self.checks_total == 0 {
            return format!("{}/{max_points}", format_points(self.points));
        }
        format!(
            "{}/{max_points} ({}/{})",
            format_points(self.points),
            self.checks_passed,
            self.checks_total
        )
    }

    /// What the tooltip says: every constraint that was not satisfied, by name.
    pub fn failure_hint(&self) -> String {
        let failed: Vec<String> = self
            .checks
            .iter()
            .filter(|check| !check.ok)
            .map(|check| {
                if check.note.is_empty() {
                    format!("• {}", check.title)
                } else {
                    format!("• {} — {}", check.title, check.note)
                }
            })
            .collect();
        if failed.is_empty() {
            return self.note.clone();
        }
        let shown = failed.len().min(6);
        let mut text = format!("Не пройдено проверок: {}\n", failed.len());
        text.push_str(&failed[..shown].join("\n"));
        if failed.len() > shown {
            text.push_str(&format!("\n… и ещё {}", failed.len() - shown));
        }
        text
    }
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct CheckResult {
    pub id: String,
    pub title: String,
    pub ok: bool,
    pub note: String,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct BenchmarkTotals {
    pub model: Option<f64>,
    pub delegator: Option<f64>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct BenchmarkProfile {
    pub by_level: Vec<ProfileGroup>,
    pub by_category: Vec<ProfileGroup>,
}

impl BenchmarkProfile {
    /// Levels first, then capabilities — both are one row each.
    pub fn rows(&self) -> Vec<&ProfileGroup> {
        self.by_level
            .iter()
            .chain(self.by_category.iter())
            .collect()
    }
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ProfileGroup {
    pub key: String,
    pub label: String,
    pub tasks: u32,
    pub max_points: u32,
    pub model: f64,
    pub delegator: Option<f64>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct BenchmarkStats {
    pub discordant_delegator: u32,
    pub discordant_model: u32,
    pub mcnemar_p: Option<f64>,
    pub min_discordant_for_proof: u32,
    pub text: String,
}

/// How long one breath of the «Бенчмарк» tab highlight takes.
pub const PULSE_PERIOD_SEC: f64 = 1.8;

/// 0.0..1.0, a smooth breath for the tab highlight while a run is in flight.
///
/// A cosine, not a sawtooth: its derivative is zero at both ends of the period,
/// so the fade has no visible seam where it restarts. Pure in `time` so the
/// animation is testable without a window.
pub fn pulse_alpha(time: f64, period_sec: f64) -> f32 {
    if period_sec <= 0.0 {
        return 1.0;
    }
    let phase = (time / period_sec).rem_euclid(1.0);
    (0.5 - 0.5 * (phase * std::f64::consts::TAU).cos()) as f32
}

/// 4.0 → «4», 4.25 → «4.3». Mirrors `engine.format_points`: a shared report must
/// not print 4.249999999 next to the same number rendered in Python.
pub fn format_points(value: f64) -> String {
    let rounded = (value * 10.0).round() / 10.0;
    if (rounded - rounded.round()).abs() < 1e-9 {
        format!("{}", rounded.round() as i64)
    } else {
        format!("{rounded:.1}")
    }
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct BenchmarkCounts {
    pub better: u32,
    pub worse: u32,
    pub same: u32,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct ExportResponse {
    files: std::collections::HashMap<String, String>,
}

impl BenchmarkReport {
    pub fn is_compare(&self) -> bool {
        self.mode == "compare"
    }
}

async fn client() -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .timeout(Duration::from_secs(15))
        .build()
        .map_err(|error| format!("не удалось создать HTTP-клиент ({error})"))
}

pub async fn fetch_last() -> Result<BenchmarkEnvelope, String> {
    let response = client()
        .await?
        .get(LAST_URL)
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
        .json::<BenchmarkEnvelope>()
        .await
        .map_err(|_| "не удалось разобрать ответ ядра".to_string())
}

pub async fn fetch_status() -> Result<Option<RunStatus>, String> {
    let response = client()
        .await?
        .get(STATUS_URL)
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
        .json::<StatusEnvelope>()
        .await
        .map(|envelope| envelope.active)
        .map_err(|_| "не удалось разобрать ответ ядра".to_string())
}

/// Asks the core to write the last report to the Desktop. Returns the paths it
/// created, in the order the caller asked for them.
pub async fn export_last(formats: Vec<&'static str>) -> Result<Vec<String>, String> {
    let response = client()
        .await?
        .post(EXPORT_URL)
        .json(&serde_json::json!({ "formats": formats }))
        .send()
        .await
        .map_err(|_| "ядро Delegator не отвечает".to_string())?;
    if response.status().as_u16() == 404 {
        return Err("бенчмарк ещё не запускался".to_string());
    }
    if !response.status().is_success() {
        return Err(format!(
            "ядро Delegator вернуло ошибку HTTP {}",
            response.status().as_u16()
        ));
    }
    let parsed = response
        .json::<ExportResponse>()
        .await
        .map_err(|_| "не удалось разобрать ответ ядра".to_string())?;
    let mut paths: Vec<String> = formats
        .iter()
        .filter_map(|format| parsed.files.get(*format).cloned())
        .collect();
    if paths.is_empty() {
        paths = parsed.files.values().cloned().collect();
    }
    Ok(paths)
}

/// «fast» → «простая» — the level names are English in the protocol and must
/// stay that way there, but the tab is Russian.
pub fn level_label(level: &str) -> &'static str {
    match level {
        "fast" => "простая",
        "normal" => "средняя",
        "deep" => "сложная",
        _ => "—",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_the_stored_report_shape() {
        let json = r#"{
            "ok": true,
            "benchmarkVersion": "1.3",
            "report": {
                "benchmarkVersion": "1.3",
                "delegatorVersion": "0.5.5",
                "runId": "abc",
                "seed": 42,
                "mode": "compare",
                "modelLabel": "gemini-3.6-flash",
                "finishedAt": "2026-08-13T10:00:00+03:00",
                "maxPoints": 24,
                "tasks": [{"index": 1, "id": "cron-match", "title": "Cron", "level": "deep",
                           "category": "code", "points": 3,
                           "model": {"answered": true, "passed": false, "points": 2.25,
                                     "maxPoints": 3, "score": 0.75, "checksPassed": 6,
                                     "checksTotal": 8, "note": "boom", "elapsedMs": 10,
                                     "checks": [{"id": "case-7", "title": "вход [31]",
                                                 "ok": false, "note": "получено None"},
                                                {"id": "case-8", "title": "вход [1]",
                                                 "ok": false, "note": ""}]},
                           "delegator": {"answered": true, "passed": true, "points": 3,
                                         "maxPoints": 3, "score": 1.0, "checksPassed": 8,
                                         "checksTotal": 8, "note": "", "elapsedMs": 90,
                                         "checks": []},
                           "winner": "delegator"}],
                "totals": {"model": 2.25, "delegator": 3},
                "counts": {"better": 1, "worse": 0, "same": 0},
                "profile": {
                    "byLevel": [{"key": "deep", "label": "сложная", "tasks": 1,
                                 "maxPoints": 3, "model": 2.25, "delegator": 3}],
                    "byCategory": [{"key": "code", "label": "код", "tasks": 1,
                                    "maxPoints": 3, "model": 2.25, "delegator": 3}]
                },
                "stats": {"discordantDelegator": 1, "discordantModel": 0, "mcnemarP": 1.0,
                          "minDiscordantForProof": 6, "alpha": 0.05, "text": "мало данных"},
                "verdict": "итог"
            }
        }"#;
        let envelope: BenchmarkEnvelope = serde_json::from_str(json).expect("shape parses");
        let report = envelope.report.expect("report present");
        assert!(report.is_compare());
        assert_eq!(report.max_points, 24);
        assert_eq!(report.tasks.len(), 1);

        // Partial credit: the score is fractional and carries its constraint count.
        let model = report.tasks[0].model.as_ref().unwrap();
        assert!(!model.passed);
        assert_eq!(model.cell(3), "2.3/3 (6/8)");
        let hint = model.failure_hint();
        assert!(hint.contains("Не пройдено проверок: 2"), "{hint}");
        assert!(hint.contains("вход [31]"), "{hint}");

        assert_eq!(report.totals.model, Some(2.25));
        assert_eq!(report.counts.unwrap().worse, 0);

        let profile = report.profile.expect("profile present");
        assert_eq!(profile.rows().len(), 2);
        assert_eq!(profile.rows()[0].label, "сложная");
        let stats = report.stats.expect("stats present");
        assert_eq!(stats.min_discordant_for_proof, 6);
        assert_eq!(stats.discordant_delegator, 1);
    }

    #[test]
    fn solo_report_has_no_delegator_side() {
        let json = r#"{"report": {"mode": "solo", "totals": {"model": 5, "delegator": null},
                       "counts": null, "stats": null, "tasks": [{"index": 1, "points": 2,
                       "model": {"passed": true, "points": 2}}],
                       "profile": {"byLevel": [{"key": "fast", "label": "простая", "tasks": 1,
                                                "maxPoints": 2, "model": 2, "delegator": null}],
                                   "byCategory": []}}}"#;
        let envelope: BenchmarkEnvelope = serde_json::from_str(json).expect("solo shape parses");
        let report = envelope.report.expect("report present");
        assert!(!report.is_compare());
        assert_eq!(report.totals.delegator, None);
        assert!(report.counts.is_none());
        assert!(report.stats.is_none());
        assert!(report.tasks[0].delegator.is_none());
        assert_eq!(report.profile.unwrap().rows()[0].delegator, None);
    }

    #[test]
    fn a_1_2_report_still_opens_after_the_partial_credit_change() {
        // The stored file survives an upgrade; a missing profile or an integer
        // score must show the old run, not an empty tab.
        let json = r#"{"report": {"benchmarkVersion": "1.2", "mode": "compare", "maxPoints": 24,
                       "tasks": [{"index": 1, "points": 3, "winner": "tie",
                                  "model": {"passed": true, "points": 3, "note": ""},
                                  "delegator": {"passed": true, "points": 3, "note": ""}}],
                       "totals": {"model": 24, "delegator": 24},
                       "counts": {"better": 0, "worse": 0, "same": 12}}}"#;
        let envelope: BenchmarkEnvelope = serde_json::from_str(json).expect("1.2 report parses");
        let report = envelope.report.expect("report present");
        let model = report.tasks[0].model.as_ref().unwrap();
        assert_eq!(model.checks_total, 0);
        assert_eq!(model.cell(3), "3/3", "no constraint counts in a 1.2 report");
        assert!(model.failure_hint().is_empty());
        assert!(report.profile.is_none());
    }

    #[test]
    fn points_print_without_float_noise() {
        assert_eq!(format_points(4.0), "4");
        assert_eq!(format_points(2.25), "2.3");
        assert_eq!(format_points(0.0), "0");
        assert_eq!(format_points(23.999999), "24");
    }

    #[test]
    fn empty_envelope_means_never_run() {
        let envelope: BenchmarkEnvelope =
            serde_json::from_str(r#"{"ok": true, "report": null}"#).expect("empty parses");
        assert!(envelope.report.is_none());
    }

    #[test]
    fn status_envelope_parses_and_reports_progress() {
        let json = r#"{"ok": true, "benchmarkVersion": "1.1", "active": {
            "runId": "abc", "mode": "compare", "modelLabel": "m", "tasksTotal": 12,
            "answeredModel": 5, "answeredDelegator": 4, "currentTask": 5,
            "currentTitle": "Нарезка", "stage": "delegator", "elapsedSec": 95, "idleSec": 3}}"#;
        let envelope: StatusEnvelope = serde_json::from_str(json).expect("status parses");
        let active = envelope.active.expect("run in flight");
        assert_eq!(active.answered_model, 5);
        // 9 of 24 arm-answers done.
        assert!((active.fraction() - 9.0 / 24.0).abs() < 0.001);
        let line = active.line();
        assert!(line.contains("задача 5 из 12"), "{line}");
        assert!(line.contains("Delegator решает"), "{line}");
        assert!(line.contains("1 мин 35 с"), "{line}");
    }

    #[test]
    fn status_is_absent_between_runs() {
        let envelope: StatusEnvelope =
            serde_json::from_str(r#"{"ok": true, "active": null}"#).expect("idle parses");
        assert!(envelope.active.is_none());
    }

    #[test]
    fn solo_progress_counts_one_arm_only() {
        let status = RunStatus {
            mode: "solo".to_string(),
            tasks_total: 12,
            answered_model: 6,
            ..Default::default()
        };
        assert!((status.fraction() - 0.5).abs() < 0.001);
        assert!(status.line().contains("подготовка"));
    }

    #[test]
    fn level_labels_are_translated_and_safe() {
        assert_eq!(level_label("deep"), "сложная");
        assert_eq!(level_label("weird"), "—");
    }

    #[test]
    fn the_pulse_breathes_without_a_seam() {
        // Stays inside the range at every phase, so the colour maths cannot
        // overflow the u8 it is cast to.
        for step in 0..400 {
            let alpha = pulse_alpha(step as f64 * 0.017, PULSE_PERIOD_SEC);
            assert!((0.0..=1.0).contains(&alpha), "phase {step} -> {alpha}");
        }
        // Dim at the start of a period, bright in the middle, and periodic.
        assert!(pulse_alpha(0.0, PULSE_PERIOD_SEC) < 0.01);
        assert!(pulse_alpha(PULSE_PERIOD_SEC / 2.0, PULSE_PERIOD_SEC) > 0.99);
        assert!(
            (pulse_alpha(0.3, PULSE_PERIOD_SEC)
                - pulse_alpha(0.3 + PULSE_PERIOD_SEC * 5.0, PULSE_PERIOD_SEC))
            .abs()
                < 1e-4,
            "the animation must not drift over a ten-minute run"
        );
        // No jump where the period restarts — that is the whole reason it is a
        // cosine and not a sawtooth.
        let before = pulse_alpha(PULSE_PERIOD_SEC - 0.001, PULSE_PERIOD_SEC);
        let after = pulse_alpha(PULSE_PERIOD_SEC + 0.001, PULSE_PERIOD_SEC);
        assert!((before - after).abs() < 0.01, "{before} vs {after}");
    }

    #[test]
    fn a_zero_period_never_divides_by_zero() {
        assert_eq!(pulse_alpha(12.5, 0.0), 1.0);
    }
}
