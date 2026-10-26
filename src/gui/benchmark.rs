//! «Бенчмарк» tab: the newest coding-benchmark grade per mode.
//!
//! The GUI never runs the benchmark — the IDE agent does, on `-benchmark` /
//! `-benchmark delegator`, and leaves `<RT>\coding-bench\results\*__v1.5__grade.json`
//! behind. Here we only read those files (no network, no core) plus the
//! `<RT>\benchmark-active.json` flag that exists while a run is in flight.
//! Every field is optional: a malformed file must never panic the window.

use serde::Deserialize;
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

/// An active-flag older than this is a leftover of a crashed run, not a run.
const ACTIVE_MAX_AGE: Duration = Duration::from_secs(6 * 3600);
const GRADE_SUFFIX: &str = "__grade.json";
/// A results dir can only grow; never parse more than this many newest files.
const MAX_FILES_TRIED: usize = 40;

#[derive(Debug, Clone, Default, Deserialize, PartialEq)]
#[serde(default)]
pub struct TaskScore {
    pub score: f64,
    pub max: f64,
    pub note: String,
}

#[derive(Debug, Clone, Default, Deserialize, PartialEq)]
#[serde(default)]
pub struct GradeTasks {
    pub routing: TaskScore,
    pub compress: TaskScore,
    pub sat: TaskScore,
}

#[derive(Debug, Clone, Default, Deserialize, PartialEq)]
#[serde(default)]
pub struct DelegationStats {
    pub calls: u64,
    pub ok: u64,
    pub web_calls: u64,
    pub models: HashMap<String, u64>,
}

impl DelegationStats {
    /// Models by call count, most used first (ties by name, so it is stable).
    pub fn top_models(&self, limit: usize) -> Vec<(&str, u64)> {
        let mut models: Vec<(&str, u64)> =
            self.models.iter().map(|(k, v)| (k.as_str(), *v)).collect();
        models.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(b.0)));
        models.truncate(limit);
        models
    }
}

#[derive(Debug, Clone, Default, Deserialize, PartialEq)]
#[serde(default)]
pub struct Grade {
    pub run: String,
    pub model: String,
    pub mode: String,
    pub bench_version: String,
    pub total: f64,
    pub minutes: Option<f64>,
    pub calibration_error: Option<f64>,
    pub graded_at: String,
    pub tasks: GradeTasks,
    pub delegation: Option<DelegationStats>,
    /// Parsed but ignored: the arms are always separate chats.
    pub isolation: Option<String>,
    pub session: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize, PartialEq)]
#[serde(default)]
pub struct ActiveRun {
    pub run: String,
    pub mode: String,
    pub model: String,
    pub started: String,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct BenchmarkView {
    pub native: Option<Grade>,
    pub delegator: Option<Grade>,
    pub active: Option<ActiveRun>,
}

impl BenchmarkView {
    /// delegator − native, only when both grades are for the same model.
    pub fn difference_line(&self) -> Option<String> {
        let (native, delegator) = (self.native.as_ref()?, self.delegator.as_ref()?);
        if native.model.trim().to_lowercase() != delegator.model.trim().to_lowercase() {
            return Some(format!(
                "Разные модели ({} и {}) — разницу считать нельзя.",
                or_dash(&native.model),
                or_dash(&delegator.model)
            ));
        }
        let diff = delegator.total - native.total;
        Some(format!(
            "Разница (Delegator − без делегирования): {}{} баллов",
            if diff > 0.0 { "+" } else { "" },
            format_points(diff)
        ))
    }
}

fn or_dash(text: &str) -> &str {
    if text.trim().is_empty() {
        "—"
    } else {
        text
    }
}

/// 4.0 → «4», 4.25 → «4.3».
pub fn format_points(value: f64) -> String {
    let rounded = (value * 10.0).round() / 10.0;
    if (rounded - rounded.round()).abs() < 1e-9 {
        format!("{}", rounded.round() as i64)
    } else {
        format!("{rounded:.1}")
    }
}

pub fn results_dir(rt: &Path) -> PathBuf {
    rt.join("coding-bench").join("results")
}

/// Grade files in `results\`, `results\<dir>\` and `results\<dir>\<dir>\`
/// (the real layout is `<model-slug>\<arm>\`; the flat one is still read).
fn collect_grade_files(results: &Path) -> Vec<(SystemTime, PathBuf)> {
    fn scan(dir: &Path, depth: u8, out: &mut Vec<(SystemTime, PathBuf)>) {
        for entry in fs::read_dir(dir).into_iter().flatten().flatten() {
            let path = entry.path();
            let Ok(meta) = entry.metadata() else {
                continue;
            };
            if meta.is_dir() {
                if depth < 2 {
                    scan(&path, depth + 1, out);
                }
            } else if entry.file_name().to_string_lossy().ends_with(GRADE_SUFFIX) {
                if let Ok(modified) = meta.modified() {
                    out.push((modified, path));
                }
            }
        }
    }
    let mut files = Vec::new();
    scan(results, 0, &mut files);
    files.sort_by(|a, b| b.0.cmp(&a.0));
    files
}

/// Newest parseable grade per arm (by file mtime) plus the active flag. The arm
/// is the JSON `mode`, else the name of the parent folder.
pub fn load(rt: &Path) -> BenchmarkView {
    let mut view = BenchmarkView::default();
    for (_, path) in collect_grade_files(&results_dir(rt))
        .into_iter()
        .take(MAX_FILES_TRIED)
    {
        if view.native.is_some() && view.delegator.is_some() {
            break;
        }
        let Some(mut grade) = fs::read(&path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Grade>(strip_bom(&bytes)).ok())
        else {
            continue;
        };
        if grade.mode.is_empty() {
            grade.mode = path
                .parent()
                .and_then(|dir| dir.file_name())
                .map(|name| name.to_string_lossy().to_lowercase())
                .unwrap_or_default();
        }
        match grade.mode.as_str() {
            "native" if view.native.is_none() => view.native = Some(grade),
            "delegator" if view.delegator.is_none() => view.delegator = Some(grade),
            _ => {}
        }
    }
    view.active = load_active_flag(rt);
    view
}

fn strip_bom(bytes: &[u8]) -> &[u8] {
    bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(bytes)
}

/// Just the in-flight flag â€” one `stat`, for the tab pulse while another tab is open.
pub fn load_active_flag(rt: &Path) -> Option<ActiveRun> {
    load_active(&rt.join("benchmark-active.json"))
}

fn load_active(path: &Path) -> Option<ActiveRun> {
    let modified = fs::metadata(path).ok()?.modified().ok()?;
    // A clock set backwards gives Err: treat that as fresh, not as stale.
    let age = SystemTime::now()
        .duration_since(modified)
        .unwrap_or_default();
    if age >= ACTIVE_MAX_AGE {
        return None;
    }
    let run = fs::read(path)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<ActiveRun>(strip_bom(&bytes)).ok())
        .unwrap_or_default();
    Some(run)
}

/// How long one breath of the «Бенчмарк» tab highlight takes.
pub const PULSE_PERIOD_SEC: f64 = 1.8;

/// 0.0..1.0, a smooth breath for the tab highlight while a run is in flight.
///
/// A cosine, not a sawtooth: its derivative is zero at both ends of the period,
/// so the fade has no visible seam where it restarts.
pub fn pulse_alpha(time: f64, period_sec: f64) -> f32 {
    if period_sec <= 0.0 {
        return 1.0;
    }
    let phase = (time / period_sec).rem_euclid(1.0);
    (0.5 - 0.5 * (phase * std::f64::consts::TAU).cos()) as f32
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU32, Ordering};

    static COUNTER: AtomicU32 = AtomicU32::new(0);

    fn temp_rt() -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "delegator-bench-test-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::SeqCst)
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(results_dir(&dir)).unwrap();
        dir
    }

    fn write_aged(path: &Path, body: &str, age_secs: u64) {
        fs::write(path, body).unwrap();
        let file = fs::OpenOptions::new().write(true).open(path).unwrap();
        file.set_modified(SystemTime::now() - Duration::from_secs(age_secs))
            .unwrap();
    }

    fn grade_json(run: &str, mode: &str, model: &str, total: f64) -> String {
        format!(
            r#"{{"run":"{run}","model":"{model}","mode":"{mode}","bench_version":"1.5",
            "total":{total},"minutes":12.5,"calibration_error":null,"graded_at":"2026-10-15T10:00:00",
            "tasks":{{"routing":{{"score":20,"max":30,"note":"n"}},"compress":{{"score":10,"max":30,"note":""}},
            "sat":{{"score":5,"max":40,"note":"","detail":{{"big":[1,2,3]}}}}}},
            "delegation":null}}"#
        )
    }

    #[test]
    fn picks_newest_per_mode() {
        let rt = temp_rt();
        let dir = results_dir(&rt);
        write_aged(
            &dir.join("a__v1.5__grade.json"),
            &grade_json("a", "native", "M", 40.0),
            300,
        );
        write_aged(
            &dir.join("b__v1.5__grade.json"),
            &grade_json("b", "native", "M", 50.0),
            100,
        );
        write_aged(
            &dir.join("c__v1.5__grade.json"),
            &grade_json("c", "delegator", "M", 60.0),
            200,
        );
        let view = load(&rt);
        assert_eq!(view.native.as_ref().unwrap().run, "b");
        assert_eq!(view.delegator.as_ref().unwrap().run, "c");
        assert_eq!(view.native.as_ref().unwrap().tasks.sat.max, 40.0);
        assert!(view.active.is_none());
        let _ = fs::remove_dir_all(rt);
    }

    #[test]
    fn reads_model_arm_layout_and_flat_layout() {
        let rt = temp_rt();
        let dir = results_dir(&rt);
        for sub in ["m-a/native", "m-a/delegator", "m-b/native", "m-b/delegator"] {
            fs::create_dir_all(dir.join(sub)).unwrap();
        }
        // Arm taken from the folder when the JSON has no `mode`.
        let no_mode = grade_json("x", "", "B", 70.0).replace(r#""mode":"","#, "");
        let g = |n: &str, mode: &str, m: &str, total: f64| grade_json(n, mode, m, total);
        write_aged(
            &dir.join("m-a/native/a__v1.5__grade.json"),
            &g("a", "native", "A", 10.0),
            500,
        );
        write_aged(
            &dir.join("m-b/native/b__v1.5__grade.json"),
            &g("b", "native", "B", 20.0),
            100,
        );
        write_aged(
            &dir.join("m-a/delegator/c__v1.5__grade.json"),
            &g("c", "delegator", "A", 30.0),
            300,
        );
        write_aged(&dir.join("m-b/delegator/d__v1.5__grade.json"), &no_mode, 50);
        write_aged(&dir.join("SUMMARY_v1.5.md"), "ignored", 1);
        let view = load(&rt);
        assert_eq!(view.native.as_ref().unwrap().run, "b");
        assert_eq!(view.delegator.as_ref().unwrap().run, "x");
        assert_eq!(view.delegator.as_ref().unwrap().mode, "delegator");

        // The old flat layout is still read.
        let flat = temp_rt();
        write_aged(
            &results_dir(&flat).join("f__v1.5__grade.json"),
            &g("f", "native", "M", 1.0),
            5,
        );
        assert_eq!(load(&flat).native.unwrap().run, "f");
        let _ = fs::remove_dir_all(rt);
        let _ = fs::remove_dir_all(flat);
    }

    #[test]
    fn isolation_and_session_fields_are_tolerated() {
        let rt = temp_rt();
        let body = grade_json("i", "native", "M", 5.0).replacen(
            "{",
            r#"{"isolation":"separate-chat","session":null,"#,
            1,
        );
        write_aged(&results_dir(&rt).join("i__v1.5__grade.json"), &body, 5);
        let view = load(&rt);
        assert_eq!(view.native.as_ref().unwrap().run, "i");
        assert_eq!(
            view.native.unwrap().isolation.as_deref(),
            Some("separate-chat")
        );
        let _ = fs::remove_dir_all(rt);
    }

    #[test]
    fn tolerates_malformed_and_missing() {
        let rt = temp_rt();
        let dir = results_dir(&rt);
        write_aged(
            &dir.join("old__v1.5__grade.json"),
            &grade_json("old", "native", "M", 30.0),
            500,
        );
        write_aged(&dir.join("bad__v1.5__grade.json"), "{not json", 10);
        write_aged(
            &dir.join("odd__v1.5__grade.json"),
            r#"{"mode":"native","tasks":5}"#,
            20,
        );
        let view = load(&rt);
        // The unparseable newer files are skipped; the older valid one wins.
        assert_eq!(view.native.as_ref().unwrap().run, "old");
        assert!(view.delegator.is_none());

        let empty = std::env::temp_dir().join("delegator-bench-test-no-such-dir-xyz");
        assert_eq!(load(&empty), BenchmarkView::default());
        let _ = fs::remove_dir_all(rt);
    }

    #[test]
    fn active_flag_respects_age_and_tolerates_garbage() {
        let rt = temp_rt();
        let flag = rt.join("benchmark-active.json");
        write_aged(
            &flag,
            r#"{"run":"r1","mode":"delegator","model":"M","started":"x"}"#,
            60,
        );
        let active = load(&rt).active.unwrap();
        assert_eq!(
            (active.run.as_str(), active.mode.as_str()),
            ("r1", "delegator")
        );

        write_aged(&flag, "garbage", 60);
        assert_eq!(load(&rt).active, Some(ActiveRun::default()));

        write_aged(&flag, "{}", 7 * 3600);
        assert!(load(&rt).active.is_none());
        let _ = fs::remove_dir_all(rt);
    }

    #[test]
    fn difference_only_for_same_model() {
        let grade = |model: &str, total: f64| Grade {
            model: model.into(),
            total,
            ..Grade::default()
        };
        let same = BenchmarkView {
            native: Some(grade("GPT-5", 40.0)),
            delegator: Some(grade(" gpt-5 ", 52.5)),
            active: None,
        };
        let line = same.difference_line().unwrap();
        assert!(line.contains("+12.5"), "{line}");

        let worse = BenchmarkView {
            native: Some(grade("m", 50.0)),
            delegator: Some(grade("M", 45.0)),
            active: None,
        };
        assert!(worse.difference_line().unwrap().contains("-5"));

        let other = BenchmarkView {
            native: Some(grade("a", 1.0)),
            delegator: Some(grade("b", 2.0)),
            active: None,
        };
        assert!(other.difference_line().unwrap().contains("Разные модели"));

        let one = BenchmarkView {
            native: Some(grade("a", 1.0)),
            ..BenchmarkView::default()
        };
        assert!(one.difference_line().is_none());
    }

    #[test]
    fn top_models_sorted() {
        let stats = DelegationStats {
            models: HashMap::from([("b".into(), 2), ("a".into(), 2), ("c".into(), 9)]),
            ..DelegationStats::default()
        };
        assert_eq!(stats.top_models(2), vec![("c", 9), ("a", 2)]);
    }

    #[test]
    fn pulse_is_a_smooth_breath() {
        assert!(pulse_alpha(0.0, 1.8).abs() < 1e-6);
        assert!((pulse_alpha(0.9, 1.8) - 1.0).abs() < 1e-6);
        assert_eq!(pulse_alpha(1.0, 0.0), 1.0);
    }

    #[test]
    fn format_points_trims() {
        assert_eq!(format_points(4.0), "4");
        assert_eq!(format_points(4.25), "4.3");
    }
}
