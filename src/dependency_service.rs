use std::path::{Path, PathBuf};

const OPENCODE_NAMES: [&str; 2] = ["opencode.cmd", "opencode.exe"];
const NPM_NAMES: [&str; 2] = ["npm.cmd", "npm.exe"];

#[derive(Debug, Clone)]
pub struct DependencyStatus {
    pub opencode_cli_path: Option<PathBuf>,
    /// npm is what installs (and re-installs) the OpenCode CLI; without it
    /// the «Скачать OpenCode CLI» button has nothing to run.
    pub npm_path: Option<PathBuf>,
}

impl DependencyStatus {
    pub fn detect() -> Self {
        Self {
            opencode_cli_path: find_opencode_cli(),
            npm_path: find_npm(),
        }
    }

    pub fn opencode_cli_available(&self) -> bool {
        self.opencode_cli_path.is_some()
    }

    pub fn npm_available(&self) -> bool {
        self.npm_path.is_some()
    }
}

/// Locates the OpenCode CLI (npm's `opencode.cmd` shim or a bare
/// `opencode.exe`). Shared by the dependency panel and Zen model discovery.
///
/// PATH first, then npm's global bin dir: a CLI the GUI just installed via
/// «Скачать OpenCode CLI» lands in `%APPDATA%\npm`, which the ALREADY RUNNING
/// process does not pick up until it is restarted — without this fallback the
/// tab would keep the "CLI not found" warning after a successful install.
pub fn find_opencode_cli() -> Option<PathBuf> {
    find_on_path(&OPENCODE_NAMES).or_else(|| find_in_dirs(&npm_global_dirs(), &OPENCODE_NAMES))
}

/// Scans PATH for npm (Node.js ships `npm.cmd` on Windows). None means the
/// «Скачать OpenCode CLI» button has nothing to run and stays disabled.
pub fn find_npm() -> Option<PathBuf> {
    find_on_path(&NPM_NAMES)
}

fn find_on_path(names: &[&str]) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    let directories: Vec<PathBuf> = std::env::split_paths(&path).collect();
    find_in_dirs(&directories, names)
}

fn find_in_dirs(directories: &[PathBuf], names: &[&str]) -> Option<PathBuf> {
    for directory in directories {
        for name in names {
            let candidate = directory.join(name);
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }
    None
}

/// Where `npm install -g` puts its shims on Windows (`%APPDATA%\npm`).
fn npm_global_dirs() -> Vec<PathBuf> {
    std::env::var_os("APPDATA")
        .map(|appdata| vec![Path::new(&appdata).join("npm")])
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn lookup_prefers_earlier_dirs_and_ignores_directories() {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock before unix epoch")
            .as_nanos();
        let root =
            std::env::temp_dir().join(format!("delegator-dep-test-{}-{nanos}", std::process::id()));
        let empty = root.join("empty");
        let decoy = root.join("decoy");
        let real = root.join("real");
        for dir in [&empty, &decoy, &real] {
            fs::create_dir_all(dir).expect("create temp dir");
        }
        // A DIRECTORY named like the shim must not count as a hit.
        fs::create_dir_all(decoy.join("opencode.cmd")).expect("create decoy dir");
        fs::write(real.join("opencode.cmd"), "@echo off\r\n").expect("write shim");

        assert_eq!(find_in_dirs(&[empty.clone()], &OPENCODE_NAMES), None);
        assert_eq!(
            find_in_dirs(&[empty, decoy, real.clone()], &OPENCODE_NAMES),
            Some(real.join("opencode.cmd"))
        );

        let _ = fs::remove_dir_all(&root);
    }
}
