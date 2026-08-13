use directories::UserDirs;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone)]
pub struct IdeStatus {
    pub name: String,
    pub is_detected: bool,
    pub is_hooked: bool,
    pub config_path: Option<PathBuf>,
}

const DELEGATOR_HOOK_HEADER: &str = "<!-- DELEGATOR_HOOK_START -->";
const DELEGATOR_HOOK_FOOTER: &str = "<!-- DELEGATOR_HOOK_END -->";

/// File names Delegator itself writes into IDE config directories. A file with
/// one of these names counts as evidence of a real IDE only when it carries
/// foreign (non-Delegator) content — see [`is_delegator_artifact`].
const DELEGATOR_HOOK_FILE_NAMES: [&str; 5] = [
    "AGENTS.md",
    "CLAUDE.md",
    "delegator.md",
    "delegator.instructions.md",
    "DELEGATOR.md",
];

/// Entry points Delegator shipped from the retired `~/.codex\bin` location.
const LEGACY_ENTRY_POINTS: [&str; 7] = [
    "ai-delegate",
    "ai-delegate-micro",
    "ai-delegate-parallel",
    "ai-delegate-plan",
    "ai-delegate-semantic-router",
    "gemini-delegate",
    "opencode-delegate",
];

/// Files from Delegator's legacy `~/.codex\bin` layout. Always Delegator's own.
const DELEGATOR_LEGACY_FILE_NAMES: [&str; 6] = [
    "ai-delegate.cmd",
    "ai-delegate.ps1",
    "gemini-delegate.cmd",
    "gemini-delegate.ps1",
    "opencode-delegate.cmd",
    "opencode-delegate.ps1",
];

/// Delegator never creates a directory tree deeper than `<root>\<dir>\<file>`,
/// so anything deeper is by definition foreign content.
const MAX_SCAN_DEPTH: usize = 2;
/// Directories holding only Delegator artifacts hold one or two entries; a
/// bigger directory is real IDE state and stops the scan early.
const MAX_SCAN_ENTRIES: usize = 64;

const RUNTIME_ENTRY_RELATIVE: &str = r"runtime\ai-delegate.cmd";

/// Entry point to advertise, plus whether it actually exists. Preference: the
/// runtime shipped next to this executable, then the standard install location.
/// A developer build has neither — and must not rewrite the user's instruction
/// files with a path that points into a build tree.
fn resolve_runtime_entrypoint(local_appdata: &Path) -> (PathBuf, bool) {
    let beside_exe = std::env::current_exe().ok().and_then(|path| {
        path.parent()
            .map(|parent| parent.join(RUNTIME_ENTRY_RELATIVE))
    });
    let installed = local_appdata
        .join(r"Programs\Delegator")
        .join(RUNTIME_ENTRY_RELATIVE);
    for candidate in beside_exe
        .iter()
        .cloned()
        .chain(std::iter::once(installed.clone()))
    {
        if candidate.exists() {
            return (candidate, true);
        }
    }
    (beside_exe.unwrap_or(installed), false)
}

/// Rewrites every reference to the retired `~/.codex\bin` entry points so
/// instruction files always name the installed runtime. Delegator used to live
/// inside the Codex profile, and agents kept quoting that path long after the
/// runtime moved to `%LOCALAPPDATA%\Programs\Delegator\runtime`.
fn migrate_legacy_text(env: &IdeEnv, content: String) -> String {
    if !env.runtime_ready {
        // The runtime location is unknown, so any rewrite would point at a
        // path that does not exist. Leave the file exactly as it is.
        return content;
    }
    let runtime_dir = env
        .runtime_entry
        .parent()
        .map(PathBuf::from)
        .unwrap_or_default();
    let legacy_bin = env.home.join(r".codex\bin");
    let mut result = content;
    // The policy file moved out of the Codex profile too.
    result = result.replace(
        &env.home
            .join(r".codex\DELEGATOR.md")
            .to_string_lossy()
            .to_string(),
        &runtime_dir.join("DELEGATOR.md").to_string_lossy(),
    );
    for name in LEGACY_ENTRY_POINTS {
        let installed = runtime_dir.join(format!("{name}.cmd"));
        for extension in ["cmd", "ps1"] {
            let legacy = legacy_bin.join(format!("{name}.{extension}"));
            result = result.replace(
                &legacy.to_string_lossy().to_string(),
                &installed.to_string_lossy(),
            );
        }
    }
    result
}

fn get_hook_text(env: &IdeEnv) -> String {
    let entrypoint = env.runtime_entry.clone();
    format!(
        "{header}\n# Delegator Integration\n\
Delegator gives you free access to stronger models through `{entry}`. Two uses: check your own answer before you send it, and offload bulk work. Both cost you no tokens.\n\
**Run every command below in PowerShell** (the leading `&` is the PowerShell call operator). Allow up to 6 minutes per call and do not set a shorter tool timeout.\n\
\n\
## 1. Review your answer before you send it\n\
Do this whenever your final answer contains code, a root-cause claim, an API or config recipe, or a migration plan.\n\
1. Write the task to `$env:TEMP\\dg-task.txt` and your finished answer to `$env:TEMP\\dg-draft.md` (UTF-8, BOM allowed).\n\
2. Run: `& \"{entry}\" improve -PromptFile \"$env:TEMP\\dg-task.txt\" -DraftFile \"$env:TEMP\\dg-draft.md\"`\n\
3. Read the EXIT CODE, not just the output:\n\
   - exit 0 — the first line is `##DELEGATOR_IMPROVE## {{...}}`, everything after it is the corrected answer: send that instead of yours.\n\
   - exit 3 — nothing to fix, send your own answer unchanged.\n\
   - any other code — the check could not run; send your own answer and mention nothing about it.\n\
Optional: add `-ContextFile \"<path>;<path>\"` with files you actually read, so the reviewer sees them. A wrong path is only skipped, never fatal.\n\
\n\
## 2. Offload work\n\
Bulk or boilerplate code, summaries of long files and logs, research questions, test generation, translations.\n\
- `& \"{entry}\" delegate -PromptFile \"<file>\"` — one answer from the strongest free model.\n\
- `& \"{entry}\" boost -PromptFile \"<file>\"` — several models plus a judge; slow, only for genuinely hard questions.\n\
Do not delegate architectural decisions, and do not delegate an edit that is faster to do yourself.\n\
\n\
## 3. `-benchmark`\n\
If the user's message is exactly `-benchmark`, open `{runtime}\\BENCHMARK.md` and follow it literally. It measures the user's own model against the same model with Delegator, and it grades mechanically — never grade the answers yourself and never invent a result.\n\
\n\
## Rules\n\
- The subcommand (`improve`, `delegate`, `boost`) is mandatory and comes first.\n\
- Never pass a prompt inline: write it to a UTF-8 file and pass `-PromptFile`. An inline prompt is cut at the first line break and `%VAR%` in it is expanded.\n\
- Use exactly the path above, never a copy from a project directory or from an old `.codex\\bin` folder.\n\
{footer}\n",
        header = DELEGATOR_HOOK_HEADER,
        entry = entrypoint.display(),
        runtime = entrypoint
            .parent()
            .map(|dir| dir.display().to_string())
            .unwrap_or_default(),
        footer = DELEGATOR_HOOK_FOOTER
    )
}

/// True when `path` is a file Delegator itself wrote (hook block, an emptied
/// hook file left behind by "disable", or a legacy runtime shim).
fn is_delegator_artifact(path: &Path) -> bool {
    let name = match path.file_name().and_then(|n| n.to_str()) {
        Some(name) => name,
        None => return false,
    };

    if DELEGATOR_LEGACY_FILE_NAMES
        .iter()
        .any(|candidate| candidate.eq_ignore_ascii_case(name))
    {
        return true;
    }

    if !DELEGATOR_HOOK_FILE_NAMES
        .iter()
        .any(|candidate| candidate.eq_ignore_ascii_case(name))
    {
        return false;
    }

    match fs::read_to_string(path) {
        Ok(content) => content.contains(DELEGATOR_HOOK_HEADER) || content.trim().is_empty(),
        // Unreadable file with a hook name: treat as real content, not ours.
        Err(_) => false,
    }
}

/// True when `dir` holds at least one entry that Delegator did not create.
/// A missing directory, an empty directory, or a directory containing nothing
/// but Delegator hook files (at any nesting level Delegator can produce) all
/// return false — they are not evidence that an IDE is installed.
fn dir_has_foreign_content(dir: &Path) -> bool {
    let mut budget = MAX_SCAN_ENTRIES;
    scan_for_foreign_content(dir, 0, &mut budget)
}

fn scan_for_foreign_content(dir: &Path, depth: usize, budget: &mut usize) -> bool {
    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(_) => return false,
    };

    for entry in entries.flatten() {
        if *budget == 0 {
            // More entries than Delegator could ever have produced.
            return true;
        }
        *budget -= 1;

        let path = entry.path();
        let is_dir = entry.file_type().map(|t| t.is_dir()).unwrap_or(false);
        if is_dir {
            if depth >= MAX_SCAN_DEPTH {
                return true;
            }
            if scan_for_foreign_content(&path, depth + 1, budget) {
                return true;
            }
        } else if !is_delegator_artifact(&path) {
            return true;
        }
    }

    false
}

/// Resolved filesystem locations detection and hook writing operate on.
/// Split out from [`IdeDetector`] so unit tests can point every lookup at a
/// temp directory instead of the real user profile.
#[derive(Debug, Clone)]
struct IdeEnv {
    home: PathBuf,
    appdata: PathBuf,
    local_appdata: PathBuf,
    path_dirs: Vec<PathBuf>,
    /// Entry point instruction files must name.
    runtime_entry: PathBuf,
    /// False when no runtime exists next to the executable nor in the install
    /// directory (a developer build): hook files are then left untouched.
    runtime_ready: bool,
}

impl IdeEnv {
    fn current() -> Self {
        let home = IdeDetector::get_user_home();
        let appdata = IdeDetector::get_appdata();
        let local_appdata = IdeDetector::get_local_appdata();
        let path_dirs = std::env::var_os("PATH")
            .map(|value| std::env::split_paths(&value).collect())
            .unwrap_or_default();
        let (runtime_entry, runtime_ready) = resolve_runtime_entrypoint(&local_appdata);
        Self {
            home,
            appdata,
            local_appdata,
            path_dirs,
            runtime_entry,
            runtime_ready,
        }
    }

    fn target_files(&self, name: &str) -> Vec<PathBuf> {
        match name {
            // Antigravity reads the global rules from ~/.gemini\GEMINI.md; the
            // config\AGENTS.md path alone left the IDE quoting a stale entry
            // point from an older install (reported 2026-08-11).
            "Antigravity" => vec![
                self.home.join(".gemini\\GEMINI.md"),
                self.home.join(".gemini\\config\\AGENTS.md"),
            ],
            "Codex" => vec![self.home.join(".codex\\AGENTS.md")],
            "OpenCode" => vec![self.home.join(".config\\opencode\\AGENTS.md")],
            "Cursor" => vec![self.home.join(".cursor\\rules\\delegator.md")],
            "Claude" => vec![
                self.home.join(".claude\\CLAUDE.md"),
                self.appdata.join("Claude\\CLAUDE.md"),
            ],
            "VS Code" => vec![self
                .home
                .join(".copilot\\instructions\\delegator.instructions.md")],
            _ => Vec::new(),
        }
    }

    /// Config roots an IDE owns. Used only as a fallback signal: the root must
    /// additionally contain content Delegator did not write.
    fn detection_roots(&self, name: &str) -> Vec<PathBuf> {
        match name {
            "Antigravity" => vec![self.home.join(".gemini"), self.home.join(".antigravity")],
            "Codex" => vec![self.home.join(".codex")],
            "OpenCode" => vec![
                self.home.join(".config\\opencode"),
                self.home.join(".local\\share\\opencode"),
            ],
            "Cursor" => vec![self.appdata.join("Cursor"), self.home.join(".cursor")],
            "Claude" => vec![self.appdata.join("Claude"), self.home.join(".claude")],
            "VS Code" => vec![self.appdata.join("Code"), self.home.join(".vscode")],
            _ => Vec::new(),
        }
    }

    /// Paths only a real installation of the IDE produces. Delegator never
    /// writes any of them.
    fn install_markers(&self, name: &str) -> Vec<PathBuf> {
        match name {
            "Antigravity" => vec![
                self.home.join(".gemini\\antigravity"),
                self.home.join(".antigravity"),
                self.appdata.join("Antigravity"),
                self.appdata.join("Antigravity IDE"),
                self.local_appdata.join("Antigravity"),
                self.local_appdata.join("Programs\\Antigravity"),
                self.local_appdata.join("Programs\\Antigravity IDE"),
            ],
            // The app ships as the MSIX package OpenAI.Codex and now presents
            // itself as ChatGPT, but it still keeps its profile in ~/.codex.
            "Codex" => vec![
                self.home.join(".codex\\config.toml"),
                self.home.join(".codex\\auth.json"),
                self.home.join(".codex\\sessions"),
                self.home.join(".codex\\history.jsonl"),
                self.local_appdata.join("OpenAI\\Codex"),
            ],
            "OpenCode" => vec![
                self.home.join(".local\\share\\opencode"),
                self.home.join(".config\\opencode\\opencode.json"),
                self.home.join(".config\\opencode\\auth.json"),
                self.appdata.join("@opencode-ai"),
            ],
            "Cursor" => vec![
                self.local_appdata.join("Programs\\Cursor"),
                self.appdata.join("Cursor\\User"),
                self.home.join(".cursor\\extensions"),
                self.home.join(".cursor\\argv.json"),
            ],
            "Claude" => vec![
                self.appdata.join("Claude\\config.json"),
                self.appdata.join("Claude\\Local Storage"),
                self.home.join(".claude.json"),
                self.home.join(".claude\\settings.json"),
                self.home.join(".claude\\projects"),
                self.home.join(".claude\\history.jsonl"),
                self.local_appdata.join("claude-cli-nodejs"),
                self.local_appdata.join("AnthropicClaude"),
            ],
            "VS Code" => vec![
                self.appdata.join("Code\\User"),
                self.home.join(".vscode\\extensions"),
                self.local_appdata.join("Programs\\Microsoft VS Code"),
            ],
            _ => Vec::new(),
        }
    }

    /// Executable stems whose presence on PATH proves the IDE's CLI is installed.
    fn command_markers(name: &str) -> &'static [&'static str] {
        match name {
            "OpenCode" => &["opencode"],
            _ => &[],
        }
    }

    fn command_on_path(&self, stem: &str) -> bool {
        const EXTENSIONS: [&str; 4] = [".cmd", ".exe", ".bat", ".ps1"];
        self.path_dirs.iter().any(|dir| {
            EXTENSIONS
                .iter()
                .any(|ext| dir.join(format!("{stem}{ext}")).exists())
        })
    }

    /// Evidence-based detection: an IDE counts as installed only when something
    /// Delegator cannot have created is present.
    fn is_detected(&self, name: &str) -> bool {
        if self
            .install_markers(name)
            .iter()
            .any(|marker| marker.exists())
        {
            return true;
        }

        if Self::command_markers(name)
            .iter()
            .any(|stem| self.command_on_path(stem))
        {
            return true;
        }

        self.detection_roots(name)
            .iter()
            .any(|root| dir_has_foreign_content(root))
    }

    /// Target files a hook may be written to. Multi-target IDEs (Claude) only
    /// get the hook where the config directory already exists, so enabling the
    /// hook never fabricates the second product's directory. When no directory
    /// exists yet, the primary target is used.
    fn writable_target_files(&self, name: &str) -> Vec<PathBuf> {
        let targets = self.target_files(name);
        if targets.len() < 2 {
            return targets;
        }
        let existing: Vec<PathBuf> = targets
            .iter()
            .filter(|path| path.parent().map(|dir| dir.exists()).unwrap_or(false))
            .cloned()
            .collect();
        if existing.is_empty() {
            targets.into_iter().take(1).collect()
        } else {
            existing
        }
    }

    fn is_hooked(&self, name: &str) -> bool {
        self.target_files(name).iter().any(|path| {
            fs::read_to_string(path)
                .map(|content| content.contains(DELEGATOR_HOOK_HEADER))
                .unwrap_or(false)
        })
    }
}

pub struct IdeDetector;

impl IdeDetector {
    const IDE_NAMES: [&'static str; 6] = [
        "Antigravity",
        "Codex",
        "OpenCode",
        "Cursor",
        "Claude",
        "VS Code",
    ];

    /// Label for the UI. The internal name stays the config key forever, so a
    /// vendor renaming its app (Codex → ChatGPT) never rewrites user settings.
    pub fn display_name(name: &str) -> &str {
        match name {
            "Codex" => "Codex (ChatGPT)",
            other => other,
        }
    }

    pub fn get_user_home() -> PathBuf {
        UserDirs::new()
            .map(|u| u.home_dir().to_path_buf())
            .unwrap_or_else(|| PathBuf::from("C:\\Users\\Default"))
    }

    pub fn get_appdata() -> PathBuf {
        std::env::var_os("APPDATA")
            .map(PathBuf::from)
            .unwrap_or_else(|| Self::get_user_home().join("AppData\\Roaming"))
    }

    pub fn get_local_appdata() -> PathBuf {
        std::env::var_os("LOCALAPPDATA")
            .map(PathBuf::from)
            .unwrap_or_else(|| Self::get_user_home().join("AppData\\Local"))
    }

    // Kept for API compatibility: detection and hook writing now go through
    // an injectable `IdeEnv` instead of these global helpers.
    #[allow(dead_code)]
    pub fn get_ide_target_files(name: &str) -> Vec<PathBuf> {
        IdeEnv::current().target_files(name)
    }

    #[allow(dead_code)]
    pub fn get_ide_target_file(name: &str) -> Option<PathBuf> {
        Self::get_ide_target_files(name).into_iter().next()
    }

    pub fn detect_all(active_states: &std::collections::HashMap<String, bool>) -> Vec<IdeStatus> {
        Self::detect_all_in(&IdeEnv::current(), active_states)
    }

    fn detect_all_in(
        env: &IdeEnv,
        active_states: &std::collections::HashMap<String, bool>,
    ) -> Vec<IdeStatus> {
        let mut list = Vec::new();

        for name in Self::IDE_NAMES {
            let _enabled_in_cfg = active_states.get(name).copied().unwrap_or(false);

            list.push(IdeStatus {
                name: name.to_string(),
                is_detected: env.is_detected(name),
                is_hooked: env.is_hooked(name),
                config_path: env.target_files(name).into_iter().next(),
            });
        }

        list
    }

    pub fn apply_hook(name: &str, enable: bool) -> Result<(), String> {
        Self::apply_hook_in(&IdeEnv::current(), name, enable)
    }

    fn apply_hook_in(env: &IdeEnv, name: &str, enable: bool) -> Result<(), String> {
        if env.target_files(name).is_empty() {
            return Err(format!("Unknown IDE: {}", name));
        }

        // Never write (and never create directories) for an IDE that is not
        // installed — that is what used to make Delegator "detect" itself.
        // Disabling always runs so hooks left by earlier versions get cleaned.
        if enable && !env.is_detected(name) {
            return Err(format!("IDE not detected, hook skipped: {}", name));
        }

        let paths = if enable {
            env.writable_target_files(name)
        } else {
            env.target_files(name)
        };

        for path in paths {
            Self::apply_hook_to_path(env, name, &path, enable)?;
        }
        Ok(())
    }

    pub fn remove_all_hooks() {
        Self::remove_all_hooks_in(&IdeEnv::current());
    }

    fn remove_all_hooks_in(env: &IdeEnv) {
        for name in Self::IDE_NAMES {
            let _ = Self::apply_hook_in(env, name, false);
        }
    }

    /// Retires the old `~/.codex` installation: the runtime lives in
    /// `%LOCALAPPDATA%\Programs\Delegator\runtime` now, and leaving shims behind
    /// makes agents quote the Codex path as the entry point (reported 2026-08-11).
    pub fn migrate_legacy_installation(_enable: bool) {
        Self::cleanup_legacy_installation_in(&IdeEnv::current());
    }

    pub fn remove_legacy_shims() {
        Self::cleanup_legacy_installation_in(&IdeEnv::current());
    }

    fn cleanup_legacy_installation_in(env: &IdeEnv) {
        // Strip our block from the legacy policy file; whatever the user wrote
        // there stays untouched.
        let legacy_policy = env.home.join(r".codex\DELEGATOR.md");
        if legacy_policy.exists() {
            let _ = Self::apply_hook_to_path(env, "Legacy Codex policy", &legacy_policy, false);
            if fs::read_to_string(&legacy_policy)
                .map(|content| content.trim().is_empty())
                .unwrap_or(false)
            {
                let _ = fs::remove_file(&legacy_policy);
            }
        }

        // Delete the entry points Delegator itself put in ~/.codex\bin. Files
        // the user placed there are left alone, and the directory is removed
        // only once it is empty.
        let bin_dir = env.home.join(r".codex\bin");
        if !bin_dir.exists() {
            return;
        }
        for name in LEGACY_ENTRY_POINTS {
            for extension in ["cmd", "ps1"] {
                let path = bin_dir.join(format!("{name}.{extension}"));
                if path.exists() {
                    let _ = fs::remove_file(path);
                }
            }
        }
        let empty = fs::read_dir(&bin_dir)
            .map(|mut entries| entries.next().is_none())
            .unwrap_or(false);
        if empty {
            let _ = fs::remove_dir(&bin_dir);
        }
    }

    fn apply_hook_to_path(
        env: &IdeEnv,
        name: &str,
        path: &PathBuf,
        enable: bool,
    ) -> Result<(), String> {
        let exists = path.exists();

        // Removing a hook from a file that is not there is a no-op: there is
        // nothing to clean and creating the path would be pure litter.
        if !enable && !exists {
            return Ok(());
        }

        if enable {
            if let Some(parent) = path.parent() {
                let _ = fs::create_dir_all(parent);
            }
        }

        let existing_content = if exists {
            fs::read_to_string(path).unwrap_or_default()
        } else {
            String::new()
        };

        let mut cleaned_content = String::new();
        let mut skipping = false;

        for line in existing_content.lines() {
            if line.contains(DELEGATOR_HOOK_HEADER) {
                skipping = true;
                continue;
            }
            if line.contains(DELEGATOR_HOOK_FOOTER) {
                skipping = false;
                continue;
            }
            if !skipping {
                cleaned_content.push_str(line);
                cleaned_content.push('\n');
            }
        }

        let final_content = if enable {
            format!("{}{}", get_hook_text(env), cleaned_content.trim_start())
        } else {
            cleaned_content
        };
        let final_content = migrate_legacy_text(env, final_content);

        fs::write(path, final_content)
            .map_err(|e| format!("Failed to update config for {}: {}", name, e))?;

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn developer_build_does_not_rewrite_instruction_files() {
        // Running the binary from a build tree must never point an IDE at a
        // runtime path that does not exist (reported 2026-08-11).
        let profile = TempProfile::new("dev-build");
        let mut env = profile.env();
        env.runtime_ready = false;
        let legacy = env
            .home
            .join(r".codex\bin\ai-delegate.cmd")
            .to_string_lossy()
            .to_string();
        let content = format!("Entry point: `{legacy}`\n");
        assert_eq!(migrate_legacy_text(&env, content.clone()), content);

        let ready = profile.env();
        assert!(ready.runtime_ready);
        let rewritten = migrate_legacy_text(&ready, content);
        assert!(!rewritten.contains(".codex"));
        assert!(rewritten.contains("ai-delegate.cmd"));
    }

    #[test]
    fn legacy_codex_entry_points_are_removed() {
        let profile = TempProfile::new("legacy-cleanup");
        let env = profile.env();
        profile.write("home/.codex/bin/ai-delegate.cmd", "@echo off\r\n");
        profile.write("home/.codex/bin/gemini-delegate.ps1", "# old\r\n");
        profile.write("home/.codex/bin/user-script.cmd", "@echo off\r\n");

        IdeDetector::cleanup_legacy_installation_in(&env);

        let bin = env.home.join(r".codex\bin");
        assert!(!bin.join("ai-delegate.cmd").exists());
        assert!(!bin.join("gemini-delegate.ps1").exists());
        // Files Delegator never wrote stay, and so does the directory holding them.
        assert!(bin.join("user-script.cmd").exists());
    }

    use super::*;
    use std::collections::HashMap;
    use std::time::{SystemTime, UNIX_EPOCH};

    /// Isolated profile: every path the detector consults lives under one temp
    /// directory, so tests never read or write the real user profile.
    struct TempProfile {
        root: PathBuf,
    }

    impl TempProfile {
        fn new(tag: &str) -> Self {
            let nanos = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("clock before unix epoch")
                .as_nanos();
            let root = std::env::temp_dir().join(format!(
                "delegator-ide-test-{tag}-{}-{nanos}",
                std::process::id()
            ));
            fs::create_dir_all(root.join("home")).expect("create temp home");
            fs::create_dir_all(root.join("appdata")).expect("create temp appdata");
            fs::create_dir_all(root.join("localappdata")).expect("create temp local appdata");
            Self { root }
        }

        fn home(&self) -> PathBuf {
            self.root.join("home")
        }

        fn appdata(&self) -> PathBuf {
            self.root.join("appdata")
        }

        fn env(&self) -> IdeEnv {
            let runtime_entry = self.root.join("runtime").join("ai-delegate.cmd");
            if !runtime_entry.exists() {
                fs::create_dir_all(runtime_entry.parent().expect("runtime dir"))
                    .expect("create runtime dir");
                fs::write(
                    &runtime_entry,
                    "@echo off

",
                )
                .expect("write runtime entry");
            }
            IdeEnv {
                home: self.home(),
                appdata: self.appdata(),
                local_appdata: self.root.join("localappdata"),
                path_dirs: Vec::new(),
                runtime_entry,
                runtime_ready: true,
            }
        }

        fn write(&self, relative: &str, content: &str) -> PathBuf {
            let path = self.root.join(relative);
            if let Some(parent) = path.parent() {
                fs::create_dir_all(parent).expect("create parent dir");
            }
            fs::write(&path, content).expect("write test file");
            path
        }

        fn mkdir(&self, relative: &str) -> PathBuf {
            let path = self.root.join(relative);
            fs::create_dir_all(&path).expect("create test dir");
            path
        }
    }

    impl Drop for TempProfile {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    // (a) A directory holding nothing but Delegator's own hook file is not an IDE.
    #[test]
    fn dir_with_only_delegator_hook_is_not_detected() {
        let profile = TempProfile::new("hook-only");
        let env = profile.env();

        profile.write("home/.codex/AGENTS.md", &get_hook_text(&env));
        profile.write("home/.config/opencode/AGENTS.md", &get_hook_text(&env));
        // Nested case: `.cursor` only holds `rules\delegator.md`.
        profile.write("home/.cursor/rules/delegator.md", &get_hook_text(&env));
        profile.write("home/.claude/CLAUDE.md", &get_hook_text(&env));
        profile.write("appdata/Claude/CLAUDE.md", &get_hook_text(&env));
        profile.write("home/.gemini/config/AGENTS.md", &get_hook_text(&env));
        // "Disable" leaves an emptied hook file behind — also not evidence.
        profile.write("home/.copilot/instructions/delegator.instructions.md", "");
        profile.write("home/.vscode/argv.json", "{}"); // sanity: this one IS evidence

        for name in ["Antigravity", "Codex", "OpenCode", "Cursor", "Claude"] {
            assert!(
                !env.is_detected(name),
                "{name} must not be detected from Delegator's own artifacts"
            );
        }
        assert!(
            env.is_detected("VS Code"),
            "a foreign file in a detection root is real evidence"
        );
    }

    // (a') An emptied hook file plus an empty legacy shim dir is still not an IDE.
    #[test]
    fn emptied_hook_and_legacy_shims_are_not_detected() {
        let profile = TempProfile::new("legacy-shims");
        let env = profile.env();

        profile.write("home/.codex/AGENTS.md", "");
        profile.write("home/.codex/DELEGATOR.md", "");
        profile.write("home/.codex/bin/ai-delegate.cmd", "@echo off\r\n");

        assert!(!env.is_detected("Codex"));
    }

    // (b) A real IDE marker is detected.
    #[test]
    fn real_ide_markers_are_detected() {
        let profile = TempProfile::new("markers");
        let env = profile.env();

        profile.write("home/.gemini/antigravity/state.json", "{}");
        profile.write("home/.codex/config.toml", "model = \"gpt\"\n");
        profile.write("home/.config/opencode/opencode.json", "{}");
        profile.mkdir("home/.cursor/extensions");
        profile.write("home/.claude/settings.json", "{}");
        profile.mkdir("appdata/Code/User");

        for name in [
            "Antigravity",
            "Codex",
            "OpenCode",
            "Cursor",
            "Claude",
            "VS Code",
        ] {
            assert!(env.is_detected(name), "{name} must be detected by marker");
        }

        let statuses = IdeDetector::detect_all_in(&env, &HashMap::new());
        assert_eq!(statuses.len(), 6);
        assert!(statuses.iter().all(|status| status.is_detected));
        assert!(statuses.iter().all(|status| !status.is_hooked));
    }

    // (b') A hook file sitting next to real content still leaves the IDE detected.
    #[test]
    fn hook_next_to_real_content_stays_detected() {
        let profile = TempProfile::new("mixed");
        let env = profile.env();

        profile.write("home/.codex/config.toml", "model = \"gpt\"\n");
        IdeDetector::apply_hook_in(&env, "Codex", true).expect("hook a detected IDE");

        let hook = profile.home().join(".codex\\AGENTS.md");
        assert!(fs::read_to_string(&hook)
            .expect("hook file")
            .contains(DELEGATOR_HOOK_HEADER));
        assert!(env.is_detected("Codex"));
        assert!(env.is_hooked("Codex"));

        IdeDetector::apply_hook_in(&env, "Codex", false).expect("unhook");
        assert!(!fs::read_to_string(&hook)
            .expect("hook file")
            .contains(DELEGATOR_HOOK_HEADER));
        assert!(!env.is_hooked("Codex"));
        assert!(env.is_detected("Codex"));
    }

    // (b'') PATH-based marker: the OpenCode CLI proves an install.
    #[test]
    fn opencode_cli_on_path_is_detected() {
        let profile = TempProfile::new("path-cli");
        let bin = profile.mkdir("bin");
        profile.write("bin/opencode.cmd", "@echo off\r\n");

        let mut env = profile.env();
        assert!(!env.is_detected("OpenCode"));
        env.path_dirs = vec![bin];
        assert!(env.is_detected("OpenCode"));
    }

    // (c) Enabling a hook for an undetected IDE creates nothing at all.
    #[test]
    fn enabling_hook_for_undetected_ide_creates_nothing() {
        let profile = TempProfile::new("no-litter");
        let env = profile.env();

        for name in IdeDetector::IDE_NAMES {
            let result = IdeDetector::apply_hook_in(&env, name, true);
            assert!(result.is_err(), "{name} must not be hooked when undetected");
        }

        for relative in [
            "home/.codex",
            "home/.config",
            "home/.cursor",
            "home/.claude",
            "home/.gemini",
            "home/.copilot",
            "appdata/Claude",
        ] {
            assert!(
                !profile.root.join(relative).exists(),
                "{relative} must not be created for an undetected IDE"
            );
        }

        let home_entries = fs::read_dir(profile.home()).expect("read home").count();
        assert_eq!(home_entries, 0, "home profile must stay untouched");
    }

    // (d) Removing a hook from a non-existent path is a no-op and creates nothing.
    #[test]
    fn removing_hook_from_missing_path_creates_nothing() {
        let profile = TempProfile::new("remove-noop");
        let env = profile.env();

        for name in IdeDetector::IDE_NAMES {
            IdeDetector::apply_hook_in(&env, name, false)
                .unwrap_or_else(|e| panic!("removing {name} must succeed: {e}"));
        }
        IdeDetector::remove_all_hooks_in(&env);

        let home_entries = fs::read_dir(profile.home()).expect("read home").count();
        let appdata_entries = fs::read_dir(profile.appdata())
            .expect("read appdata")
            .count();
        assert_eq!(home_entries, 0, "removal must not create directories");
        assert_eq!(appdata_entries, 0, "removal must not create directories");
    }

    // Multi-target IDE: hooking Claude via the CLI must not fabricate the
    // desktop app's %APPDATA%\Claude directory.
    #[test]
    fn multi_target_hook_does_not_fabricate_missing_product_dir() {
        let profile = TempProfile::new("multi-target");
        let env = profile.env();

        profile.write("home/.claude/settings.json", "{}");
        IdeDetector::apply_hook_in(&env, "Claude", true).expect("hook detected Claude");

        assert!(profile.home().join(".claude\\CLAUDE.md").exists());
        assert!(
            !profile.appdata().join("Claude").exists(),
            "the second target's directory must not be created"
        );
        assert!(env.is_hooked("Claude"));
    }

    /// Diagnostic probe against the real machine.
    /// Run with: cargo test -- --ignored --nocapture detection_report
    #[test]
    #[ignore]
    fn detection_report_for_this_machine() {
        let env = IdeEnv::current();
        println!("home           = {}", env.home.display());
        println!("appdata        = {}", env.appdata.display());
        println!("local appdata  = {}", env.local_appdata.display());
        for name in IdeDetector::IDE_NAMES {
            println!("\n=== {name}: detected = {}", env.is_detected(name));
            for marker in env.install_markers(name) {
                println!(
                    "  [{}] marker {}",
                    if marker.exists() { "x" } else { " " },
                    marker.display()
                );
            }
            for stem in IdeEnv::command_markers(name) {
                println!(
                    "  [{}] PATH   {stem}",
                    if env.command_on_path(stem) { "x" } else { " " }
                );
            }
            for root in env.detection_roots(name) {
                println!(
                    "  [{}] root   {} (exists = {})",
                    if dir_has_foreign_content(&root) {
                        "x"
                    } else {
                        " "
                    },
                    root.display(),
                    root.exists()
                );
            }
        }
    }
}
