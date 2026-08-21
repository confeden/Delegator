//! OpenCode CLI support for the «Модели OpenCode» tab:
//! * strength ordering of the Zen (`opencode/*`) block,
//! * background install of the missing dependencies (winget/npm chain),
//! * background update (`opencode upgrade`),
//! * the manual-download fallback links.
//!
//! Everything here is fire-and-forget: the GUI thread never blocks, results
//! come back through `AppMessage`, and every failure is logged in English and
//! surfaced as a short Russian line in the tab.

use crate::config::runtime_home_dir;
use crate::models_service::ModelInfo;
use serde::Deserialize;
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::OnceLock;
use std::time::Duration;

#[cfg(target_os = "windows")]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// npm cold-installs and OpenCode self-updates can legitimately take minutes
/// on a slow link; the timeout only guards against a wedged child.
const CLI_JOB_TIMEOUT: Duration = Duration::from_secs(600);

/// Strength catalog written by the PowerShell runtime
/// (`update-free-models.ps1`, refreshed inline by `opencode-delegate.ps1`).
const ZEN_CATALOG_FILE: &str = "opencode-zen-catalog.json";

/// `<RT>\opencode-zen-catalog.json`: `{version, updatedAt, models:[{id,strength}]}`.
#[derive(Debug, Deserialize)]
struct ZenCatalogFile {
    /// `version` of the ratings table this cache was built from. Absent in
    /// pre-0.7 catalogs, which is exactly why it defaults to 0 and mismatches.
    #[serde(default, rename = "ratingsVersion")]
    ratings_version: i64,
    #[serde(default)]
    models: Vec<ZenCatalogEntry>,
}

/// `version` of the embedded ratings table. Bump it in model-ratings.json
/// whenever a `dpr` changes, or caches built from the old numbers stay valid.
fn ratings_version() -> i64 {
    static VERSION: OnceLock<i64> = OnceLock::new();
    *VERSION.get_or_init(|| {
        serde_json::from_str::<serde_json::Value>(MODEL_RATINGS_JSON)
            .ok()
            .and_then(|value| value.get("version").and_then(serde_json::Value::as_i64))
            .unwrap_or(0)
    })
}

#[derive(Debug, Deserialize)]
struct ZenCatalogEntry {
    id: String,
    #[serde(default)]
    strength: Option<i32>,
}

/// Reads the runtime's strength catalog. A missing or corrupt file is not an
/// error — the caller then falls back to `zen_strength` per id.
pub fn load_zen_strengths() -> HashMap<String, i32> {
    load_zen_strengths_from(&runtime_home_dir())
}

fn load_zen_strengths_from(runtime_home: &Path) -> HashMap<String, i32> {
    let path = runtime_home.join(ZEN_CATALOG_FILE);
    let Ok(content) = fs::read_to_string(&path) else {
        return HashMap::new();
    };
    match serde_json::from_str::<ZenCatalogFile>(&content) {
        Ok(catalog) => {
            // A cache built from a different ratings table is not "slightly
            // old", it is wrong: the runtime only rewrites it once per 24 h, so
            // an upgrade that changes the scores would otherwise order the tab
            // by yesterday's numbers for a whole day. Reject it and let the
            // embedded table answer instead.
            if catalog.ratings_version != ratings_version() {
                return HashMap::new();
            }
            catalog
                .models
                .into_iter()
                .filter_map(|entry| Some((entry.id, entry.strength?)))
                .collect()
        }
        Err(error) => {
            eprintln!("Failed to parse {}: {error}", path.display());
            HashMap::new()
        }
    }
}

/// The shipped rating table, embedded so the GUI can order models before the
/// runtime has ever written its catalog — and so it can never be missing.
/// The PowerShell runtime reads the very same file from `{app}\runtime\`.
const MODEL_RATINGS_JSON: &str = include_str!("../../scripts/model-ratings.json");

/// DPR handed to a model with no row in the table. NOT zero: an unrated model
/// (a stealth alias, an auto-route, anything released after the snapshot) has to
/// stay reachable — it just must not be trusted with deep work until measured.
pub const UNRATED_DPR: i32 = 100;

/// Tier floors on the DPR scale, mirrored in scripts/opencode-delegate.ps1.
pub const DPR_DEEP: i32 = 130;
pub const DPR_NORMAL: i32 = 100;

/// One Russian line describing what a model may be trusted with, for the tab.
/// A rating of 0 is called out on its own: those models do not write code at
/// all (speech, safety classifiers, embeddings) and must never be delegated to.
pub fn dpr_hint(id: &str) -> String {
    match model_rating(id) {
        None => "Рейтинг неизвестен — модель используется как обычная, \
                 приоритет решает измеренная скорость и надёжность."
            .to_string(),
        Some(0) => "Рейтинг 0: не пишет код вообще (распознавание речи, \
                    классификатор, эмбеддинги). Не делегируйте ей задачи."
            .to_string(),
        Some(dpr) if dpr >= DPR_DEEP => {
            format!("Рейтинг {dpr} — глубокий тир: сложные задачи и проверки.")
        }
        Some(dpr) if dpr >= DPR_NORMAL => {
            format!("Рейтинг {dpr} — обычный тир: рядовые задачи.")
        }
        Some(dpr) => format!("Рейтинг {dpr} — быстрый тир: только простые задачи."),
    }
}

#[derive(Debug, Deserialize)]
struct RatingsFile {
    #[serde(default)]
    models: Vec<RatingRow>,
}

#[derive(Debug, Deserialize)]
struct RatingRow {
    #[serde(rename = "match")]
    pattern: String,
    #[serde(default)]
    dpr: Option<i32>,
}

/// Rows sorted longest-pattern-first, so the FIRST substring hit is already the
/// most specific one (`glm-5.2` before `glm-5`, `gpt-5.4-mini` before `gpt-5`).
fn rating_rows() -> &'static [(String, i32)] {
    static ROWS: OnceLock<Vec<(String, i32)>> = OnceLock::new();
    ROWS.get_or_init(|| {
        let mut rows: Vec<(String, i32)> =
            match serde_json::from_str::<RatingsFile>(MODEL_RATINGS_JSON) {
                Ok(file) => file
                    .models
                    .into_iter()
                    .filter_map(|row| Some((row.pattern.to_ascii_lowercase(), row.dpr?)))
                    .collect(),
                Err(error) => {
                    eprintln!("Failed to parse the embedded model ratings: {error}");
                    Vec::new()
                }
            };
        rows.sort_by(|left, right| right.0.len().cmp(&left.0.len()));
        rows
    })
}

/// DPR (Delegator Programming Rating) of a model id: 0 means it cannot program
/// at all, and the scale has no upper bound. `None` means the model is unrated,
/// which is NOT the same as 0 — see [`UNRATED_DPR`].
///
/// DUPLICATION IS DELIBERATE: the runtime scores in PowerShell, the GUI needs
/// the same order in-process. One of four copies — the others are in
/// scripts/delegator-common.ps1, scripts/opencode-delegate.ps1 and
/// scripts/update-free-models.ps1. Keep them (and ROADMAP) in sync.
pub fn model_rating(id: &str) -> Option<i32> {
    let name = id.to_ascii_lowercase().replace(['_', ' '], "-");
    rating_rows()
        .iter()
        .find(|(pattern, _)| name.contains(pattern.as_str()))
        .map(|(_, dpr)| *dpr)
}

/// Score used for ordering: the runtime catalog wins (it is what the router
/// actually routes by), the shipped table covers every id the catalog lacks —
/// including the case where the runtime has never written the file at all.
fn strength_of(id: &str, catalog: &HashMap<String, i32>) -> i32 {
    catalog
        .get(id)
        .copied()
        .or_else(|| model_rating(id))
        .unwrap_or(UNRATED_DPR)
}

/// Orders the model list for the tab: the `opencode/*` Zen block first, by
/// strength DESC then id, followed by every other entry (`openrouter/*`) in
/// its existing relative order.
pub fn order_opencode_models(
    models: Vec<ModelInfo>,
    catalog: &HashMap<String, i32>,
) -> Vec<ModelInfo> {
    // Owner's order, 2026-08-13: their own providers at the very top, then the
    // universal free route, then the Zen aliases strongest-first, then anything
    // else. A model you added yourself is the one you came to this tab for.
    let (mut custom, others): (Vec<ModelInfo>, Vec<ModelInfo>) = models
        .into_iter()
        .partition(|model| crate::models_service::is_custom_provider_model(&model.id));
    custom.sort_by(|a, b| a.id.cmp(&b.id));

    let (mut free_route, others): (Vec<ModelInfo>, Vec<ModelInfo>) = others
        .into_iter()
        .partition(|model| model.id == crate::config::UNIVERSAL_FREE_MODEL);
    free_route.sort_by(|a, b| a.id.cmp(&b.id));

    let (mut zen, rest): (Vec<ModelInfo>, Vec<ModelInfo>) = others
        .into_iter()
        .partition(|model| model.id.starts_with("opencode/"));
    zen.sort_by(|a, b| {
        strength_of(&b.id, catalog)
            .cmp(&strength_of(&a.id, catalog))
            .then_with(|| a.id.cmp(&b.id))
    });

    custom.extend(free_route);
    custom.extend(zen);
    custom.extend(rest);
    custom
}

/// Which background CLI job produced a result (they share one code path but
/// get different Russian status lines).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CliJob {
    Install,
    Upgrade,
}

/// `Ok(())` on success, `Err(short Russian reason)` otherwise. The full
/// stdout/stderr always goes to the log in English.
pub type CliJobResult = Result<(), String>;

/// Manual fallback when nothing can be installed automatically.
pub const NODEJS_DOWNLOAD_URL: &str = "https://nodejs.org/en/download";
pub const OPENCODE_SITE_URL: &str = "https://opencode.ai";

/// Shown when neither winget nor npm exists, so no chain can even start.
pub const NO_INSTALLER_FOUND: &str = "не найдены winget и npm";

/// One command of the dependency install chain.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InstallStep {
    /// The preferred route: installs the CLI without Node.js at all.
    WingetOpenCode,
    /// Prerequisite of `NpmOpenCode` when npm is missing.
    WingetNodeJs,
    /// The classic route, also the fallback when winget refuses the package.
    NpmOpenCode,
}

impl InstallStep {
    /// The single short Russian line the user sees while the step runs.
    pub fn status_line(self) -> &'static str {
        match self {
            InstallStep::WingetNodeJs => "Устанавливаю Node.js…",
            InstallStep::WingetOpenCode | InstallStep::NpmOpenCode => "Устанавливаю OpenCode CLI…",
        }
    }

    /// Arguments exactly as spawned; the program is located at run time
    /// because PATH may have changed since the previous step.
    pub fn args(self) -> &'static [&'static str] {
        match self {
            InstallStep::WingetOpenCode => &[
                "install",
                "--id",
                "SST.opencode",
                "-e",
                "--silent",
                "--accept-package-agreements",
                "--accept-source-agreements",
            ],
            InstallStep::WingetNodeJs => &[
                "install",
                "--id",
                "OpenJS.NodeJS.LTS",
                "-e",
                "--silent",
                "--accept-package-agreements",
                "--accept-source-agreements",
            ],
            InstallStep::NpmOpenCode => &["install", "-g", "opencode-ai"],
        }
    }

    fn program_name(self) -> &'static str {
        match self {
            InstallStep::WingetOpenCode | InstallStep::WingetNodeJs => "winget",
            InstallStep::NpmOpenCode => "npm",
        }
    }

    /// Node.js is only a prerequisite — succeeding at it does not end the
    /// chain, succeeding at anything else does.
    fn installs_cli(self) -> bool {
        !matches!(self, InstallStep::WingetNodeJs)
    }
}

/// The command line as logged and as spawned (English, for the log only).
pub fn command_line(step: InstallStep) -> String {
    format!("{} {}", step.program_name(), step.args().join(" "))
}

/// Ordered install chain for the tooling found on this machine:
/// * winget → try `SST.opencode` first (no Node.js needed at all);
/// * npm present → `npm install -g opencode-ai` as the fallback;
/// * npm missing but winget present → install Node.js LTS, then npm;
/// * neither → empty, the GUI shows the manual download links instead.
pub fn install_plan(has_winget: bool, has_npm: bool) -> Vec<InstallStep> {
    let mut plan = Vec::new();
    if has_winget {
        plan.push(InstallStep::WingetOpenCode);
    }
    if has_npm {
        plan.push(InstallStep::NpmOpenCode);
    } else if has_winget {
        plan.push(InstallStep::WingetNodeJs);
        plan.push(InstallStep::NpmOpenCode);
    }
    plan
}

/// Runs the chain in the background, reporting the step it is about to start
/// so the tab can keep exactly one status line up to date. Stops at the first
/// step that actually installs the CLI.
pub async fn install_dependencies(
    plan: Vec<InstallStep>,
    report: impl Fn(InstallStep) + Send + 'static,
) -> CliJobResult {
    if plan.is_empty() {
        eprintln!("Neither winget nor npm is available; cannot install the OpenCode CLI");
        return Err(NO_INSTALLER_FOUND.to_string());
    }
    let chain: Vec<String> = plan.iter().map(|step| command_line(*step)).collect();
    println!("Dependency install chain: {}", chain.join(" -> "));

    let mut last_error: Option<String> = None;
    for step in plan {
        report(step);
        match run_install_step(step).await {
            Ok(()) if step.installs_cli() => return Ok(()),
            Ok(()) => {}
            Err(reason) => last_error = Some(reason),
        }
    }
    Err(last_error.unwrap_or_else(|| NO_INSTALLER_FOUND.to_string()))
}

async fn run_install_step(step: InstallStep) -> CliJobResult {
    let program = match step {
        InstallStep::WingetOpenCode | InstallStep::WingetNodeJs => {
            crate::dependency_service::find_winget()
        }
        // Re-resolved on every attempt: a Node.js installed one step ago is
        // not on the running process's PATH, only in %ProgramFiles%\nodejs.
        InstallStep::NpmOpenCode => crate::dependency_service::find_npm(),
    };
    let Some(program) = program else {
        eprintln!("`{}` not found; skipping this step", step.program_name());
        return Err(format!("не найден {}", step.program_name()));
    };
    run_cli_job(&command_line(step), &program, step.args()).await
}

/// Opens a page in the user's browser without flashing a console window.
/// Used only for the two hardcoded fallback links above.
pub fn open_url(url: &str) {
    println!("Opening {url} in the default browser");
    let mut command = std::process::Command::new("cmd");
    command.args(["/c", "start", "", url]);
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    if let Err(error) = command.spawn() {
        eprintln!("Failed to open {url}: {error}");
    }
}

/// `opencode upgrade` in the background: keeps the Zen alias list current, so
/// brand-new free models show up in the tab without user action.
pub async fn upgrade_opencode_cli(cli: PathBuf) -> CliJobResult {
    run_cli_job("opencode upgrade", &cli, &["upgrade"]).await
}

async fn run_cli_job(label: &str, program: &Path, args: &[&str]) -> CliJobResult {
    let mut command = tokio::process::Command::new(program);
    command
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    #[cfg(target_os = "windows")]
    command.creation_flags(CREATE_NO_WINDOW);

    let output = match tokio::time::timeout(CLI_JOB_TIMEOUT, command.output()).await {
        Ok(Ok(output)) => output,
        Ok(Err(error)) => {
            eprintln!("Failed to run `{label}`: {error}");
            return Err("не удалось запустить команду".to_string());
        }
        Err(_) => {
            eprintln!("`{label}` timed out after {}s", CLI_JOB_TIMEOUT.as_secs());
            return Err(format!(
                "превышено время ожидания ({} мин)",
                CLI_JOB_TIMEOUT.as_secs() / 60
            ));
        }
    };

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    if output.status.success() {
        println!("`{label}` finished successfully");
        Ok(())
    } else {
        eprintln!(
            "`{label}` exited with {}\n--- stdout ---\n{}\n--- stderr ---\n{}",
            output.status,
            stdout.trim(),
            stderr.trim()
        );
        Err(short_failure(&stdout, &stderr))
    }
}

/// Last meaningful output line, truncated — enough to tell «нет сети» from
/// «нет прав» without dumping an npm log into the GUI.
fn short_failure(stdout: &str, stderr: &str) -> String {
    let reason = [stderr, stdout]
        .iter()
        .find_map(|stream| {
            stream
                .lines()
                .map(str::trim)
                .filter(|l| !l.is_empty())
                .last()
        })
        .unwrap_or("нет вывода команды");
    truncate_chars(reason, 120)
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
    use std::time::{SystemTime, UNIX_EPOCH};

    /// Zen aliases seen in the wild, with the DPR the shipped table gives them.
    const LIVE_ZEN: [(&str, i32); 8] = [
        ("opencode/muse-spark-1.2-contributor-free", 144),
        ("opencode/deepseek-v4-flash-free", 129),
        ("opencode/hy3-free", 118),
        ("opencode/mimo-v2.5-free", 110),
        ("opencode/laguna-s-2.1-free", 100),
        ("opencode/nemotron-3-ultra-free", 99),
        ("opencode/north-mini-code-free", 70),
        ("opencode/nemotron-3.5-lightning-free", 54),
    ];

    fn model(id: &str) -> ModelInfo {
        ModelInfo {
            id: id.to_string(),
            name: id.to_string(),
            is_free: true,
            provider: "test".into(),
        }
    }

    #[test]
    fn ratings_table_parses_and_covers_the_live_zen_lineup() {
        assert!(
            rating_rows().len() > 150,
            "the embedded table failed to parse: {} rows",
            rating_rows().len()
        );
        for (id, expected) in LIVE_ZEN {
            assert_eq!(model_rating(id), Some(expected), "{id}");
        }
    }

    #[test]
    fn a_row_covers_every_provider_prefix_and_the_longest_match_wins() {
        // One row, every route the same user can reach it by.
        for id in [
            "claude-opus-5",
            "agentrouter/claude-opus-5",
            "aerolink/claude-opus-5",
            "Aerolink/Claude-Opus-5",
        ] {
            assert_eq!(model_rating(id), Some(156), "{id}");
        }
        // Specificity: the longer pattern must win over the shorter prefix.
        assert_eq!(model_rating("huggingface/zai-org/GLM-5.2"), Some(138));
        assert_eq!(model_rating("orcarouter/z-ai/glm-5"), Some(102));
        assert_eq!(model_rating("orcarouter/openai/gpt-5.4-mini"), Some(112));
        assert_eq!(model_rating("orcarouter/openai/gpt-5"), Some(76));
        // `-fast` and dated suffixes are the same model.
        assert_eq!(
            model_rating("orcarouter/anthropic/claude-opus-4.6-fast"),
            Some(140)
        );
    }

    #[test]
    fn zero_means_cannot_program_and_unknown_means_unrated_not_zero() {
        // The anchor of the scale: these are not weak coders, they are not
        // coders. They must never be picked for code, at any tier.
        for id in [
            "groq/whisper-large-v3",
            "groq/canopylabs/orpheus-v1-english",
            "groq/meta-llama/llama-prompt-guard-2-86m",
            "huggingface/Qwen/Qwen3-Embedding-8B",
        ] {
            assert_eq!(model_rating(id), Some(0), "{id}");
        }
        // An unrated model is NOT zero — it stays reachable at the neutral tier.
        assert_eq!(model_rating("opencode/big-pickle"), None);
        assert_eq!(model_rating("opencode/x-preview-f-free"), None);
        assert_eq!(
            strength_of("opencode/big-pickle", &HashMap::new()),
            UNRATED_DPR
        );
    }

    /// Regression for the whole point of the table. The alias-name heuristic
    /// this replaced scored `nemotron-3-ultra` 93 of 100 — the top of its deep
    /// tier — because the word "ultra" was worth +40. The published coding index
    /// puts it at 49, and that model is on record for spending 175 s on a
    /// trivial question and failing 6 of its last 10 calls. It must sit BELOW
    /// the deep floor, and below the flash model that actually outperforms it.
    #[test]
    fn the_heuristic_had_it_backwards_and_the_table_does_not() {
        let ultra = model_rating("opencode/nemotron-3-ultra-free").expect("rated");
        let flash = model_rating("opencode/deepseek-v4-flash-free").expect("rated");
        assert!(
            ultra < DPR_DEEP,
            "ultra {ultra} must not reach the deep tier"
        );
        assert!(
            flash >= DPR_NORMAL,
            "flash {flash} must clear the normal floor"
        );
        assert!(flash > ultra, "flash {flash} must outrank ultra {ultra}");
    }

    #[test]
    fn ordering_sorts_zen_by_strength_and_keeps_openrouter_after_it() {
        // Deliberately scrambled input, incl. two ties (100 and 70).
        let models: Vec<ModelInfo> = [
            "opencode/ling-3.0-tiny-free",
            "openrouter/qwen/qwen-2.5:free",
            "opencode/mimo-v2.5-free",
            "opencode/nemotron-3-ultra-free",
            "openrouter/z-ai/glm-5",
            "opencode/longcat-2.0-free",
            "opencode/big-pickle",
            "opencode/laguna-s-2.1-free",
            "opencode/deepseek-v4-flash-free",
            "opencode/north-mini-code-free",
        ]
        .into_iter()
        .map(model)
        .collect();

        // No catalog file → the shipped table alone must produce the order.
        // Note where `nemotron-3-ultra` lands: fifth, not first.
        let ordered = order_opencode_models(models.clone(), &HashMap::new());
        let ids: Vec<&str> = ordered.iter().map(|m| m.id.as_str()).collect();
        assert_eq!(
            ids,
            vec![
                "opencode/deepseek-v4-flash-free",
                "opencode/mimo-v2.5-free",
                // 100-way tie (one rated, one unrated) broken by id.
                "opencode/big-pickle",
                "opencode/laguna-s-2.1-free",
                "opencode/nemotron-3-ultra-free",
                // 70-way tie broken by id.
                "opencode/longcat-2.0-free",
                "opencode/north-mini-code-free",
                "opencode/ling-3.0-tiny-free",
                // openrouter/* keeps its own relative order, after the block.
                "openrouter/qwen/qwen-2.5:free",
                "openrouter/z-ai/glm-5",
            ]
        );

        // A catalog file overrides the table for the ids it lists.
        let catalog: HashMap<String, i32> =
            HashMap::from([("opencode/ling-3.0-tiny-free".to_string(), 999)]);
        let ordered = order_opencode_models(models, &catalog);
        assert_eq!(ordered[0].id, "opencode/ling-3.0-tiny-free");
        assert_eq!(ordered[1].id, "opencode/deepseek-v4-flash-free");
    }

    #[test]
    fn catalog_file_is_read_and_bad_input_degrades_to_the_table() {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock before unix epoch")
            .as_nanos();
        let dir = std::env::temp_dir().join(format!(
            "delegator-zen-catalog-test-{}-{nanos}",
            std::process::id()
        ));
        fs::create_dir_all(&dir).expect("create temp runtime home");

        // Missing file → empty map (callers then use the shipped table).
        assert!(load_zen_strengths_from(&dir).is_empty());

        let real_shape = format!(
            r#"{{"version":1,"ratingsVersion":{},"updatedAt":"2026-08-10T16:45:38Z","models":[
            {{"id":"opencode/nemotron-3-ultra-free","strength":99}},
            {{"id":"opencode/big-pickle","strength":70}},
            {{"id":"opencode/no-score-here"}}]}}"#,
            ratings_version()
        );
        fs::write(dir.join(ZEN_CATALOG_FILE), &real_shape).expect("write catalog");
        let strengths = load_zen_strengths_from(&dir);
        assert_eq!(strengths.len(), 2);
        assert_eq!(strengths["opencode/nemotron-3-ultra-free"], 99);
        // An id the catalog does not score falls through to the table, and an
        // id neither of them knows lands on the neutral unrated score.
        assert_eq!(
            strength_of("opencode/no-score-here", &strengths),
            UNRATED_DPR
        );
        assert_eq!(strength_of("opencode/hy3-free", &strengths), 118);
        // The catalog still wins where it does carry a score.
        assert_eq!(strength_of("opencode/big-pickle", &strengths), 70);

        // A cache built from a DIFFERENT ratings table must be refused whole.
        // Measured on the 0.7 upgrade: the runtime rewrites this file only once
        // per 24 h, so a surviving pre-0.7 catalog kept scoring
        // `nemotron-3-ultra` 93 — top of the deep tier — against the 99 the new
        // table gives it. A pre-0.7 catalog has no stamp at all, hence 0.
        let stale = real_shape.replace(
            &format!(r#""ratingsVersion":{}"#, ratings_version()),
            r#""ratingsVersion":0"#,
        );
        fs::write(dir.join(ZEN_CATALOG_FILE), stale).expect("write stale catalog");
        assert!(
            load_zen_strengths_from(&dir).is_empty(),
            "a catalog from another ratings table must be rejected, not trusted"
        );
        // Rejected means the shipped table answers instead — the whole point.
        assert_eq!(
            strength_of(
                "opencode/nemotron-3-ultra-free",
                &load_zen_strengths_from(&dir)
            ),
            99
        );

        fs::write(dir.join(ZEN_CATALOG_FILE), "{ not json").expect("write corrupt catalog");
        assert!(load_zen_strengths_from(&dir).is_empty());

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn install_chain_covers_every_combination_of_winget_and_npm() {
        use InstallStep::*;
        // winget alone already installs the CLI without Node.js; npm stays as
        // the fallback for the case winget refuses the package.
        assert_eq!(install_plan(true, true), vec![WingetOpenCode, NpmOpenCode]);
        // No npm: winget must first bring Node.js LTS in, then npm can run.
        assert_eq!(
            install_plan(true, false),
            vec![WingetOpenCode, WingetNodeJs, NpmOpenCode]
        );
        // No winget: only the classic npm route is left.
        assert_eq!(install_plan(false, true), vec![NpmOpenCode]);
        // Nothing to run — the GUI shows the manual download links instead.
        assert_eq!(install_plan(false, false), Vec::new());
    }

    #[test]
    fn install_commands_are_spelled_exactly_as_verified_by_hand() {
        assert_eq!(
            command_line(InstallStep::WingetOpenCode),
            "winget install --id SST.opencode -e --silent \
             --accept-package-agreements --accept-source-agreements"
        );
        assert_eq!(
            command_line(InstallStep::WingetNodeJs),
            "winget install --id OpenJS.NodeJS.LTS -e --silent \
             --accept-package-agreements --accept-source-agreements"
        );
        assert_eq!(
            command_line(InstallStep::NpmOpenCode),
            "npm install -g opencode-ai"
        );
        // Only Node.js is a prerequisite; the other two end the chain.
        assert!(InstallStep::WingetOpenCode.installs_cli());
        assert!(InstallStep::NpmOpenCode.installs_cli());
        assert!(!InstallStep::WingetNodeJs.installs_cli());
        // One short Russian line per step, and only two distinct ones.
        assert_eq!(
            InstallStep::WingetOpenCode.status_line(),
            InstallStep::NpmOpenCode.status_line()
        );
        assert_eq!(
            InstallStep::WingetNodeJs.status_line(),
            "Устанавливаю Node.js…"
        );
    }

    #[test]
    fn manual_fallback_links_point_at_the_official_pages() {
        assert_eq!(NODEJS_DOWNLOAD_URL, "https://nodejs.org/en/download");
        assert_eq!(OPENCODE_SITE_URL, "https://opencode.ai");
    }

    /// An empty plan must fail immediately instead of spawning anything.
    #[tokio::test]
    async fn an_empty_plan_fails_without_spawning_a_process() {
        let result = install_dependencies(Vec::new(), |_| unreachable!("no step may run")).await;
        assert_eq!(result, Err(NO_INSTALLER_FOUND.to_string()));
    }

    #[test]
    fn failure_text_prefers_the_last_stderr_line_and_is_truncated() {
        assert_eq!(
            short_failure(
                "npm WARN deprecated\n",
                "npm ERR! code EACCES\nnpm ERR! syscall mkdir\n"
            ),
            "npm ERR! syscall mkdir"
        );
        // Empty stderr → fall back to stdout.
        assert_eq!(
            short_failure("only stdout here\n", "   \n"),
            "only stdout here"
        );
        assert_eq!(short_failure("", ""), "нет вывода команды");
        let long = "e".repeat(300);
        assert_eq!(short_failure("", &long).chars().count(), 121);
    }
}
#[cfg(test)]
mod order_tests {
    use super::*;

    fn model(id: &str) -> ModelInfo {
        ModelInfo {
            id: id.to_string(),
            name: id.to_string(),
            is_free: true,
            provider: "x".into(),
        }
    }

    #[test]
    fn custom_providers_come_first_then_the_free_route() {
        let catalog: HashMap<String, i32> = [
            ("opencode/weak".to_string(), 10),
            ("opencode/strong".to_string(), 90),
        ]
        .into_iter()
        .collect();
        let ordered = order_opencode_models(
            vec![
                model("opencode/weak"),
                model(crate::config::UNIVERSAL_FREE_MODEL),
                model("opencode/strong"),
                model("agentrouter/claude-opus-5"),
            ],
            &catalog,
        );
        let ids: Vec<&str> = ordered.iter().map(|m| m.id.as_str()).collect();
        assert_eq!(
            ids,
            vec![
                "agentrouter/claude-opus-5",
                crate::config::UNIVERSAL_FREE_MODEL,
                "opencode/strong",
                "opencode/weak",
            ]
        );
    }
}
