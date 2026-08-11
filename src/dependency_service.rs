use std::path::{Path, PathBuf};

const OPENCODE_NAMES: [&str; 2] = ["opencode.cmd", "opencode.exe"];
const NPM_NAMES: [&str; 2] = ["npm.cmd", "npm.exe"];
const WINGET_NAMES: [&str; 1] = ["winget.exe"];

#[derive(Debug, Clone)]
pub struct DependencyStatus {
    pub opencode_cli_path: Option<PathBuf>,
    /// npm installs the OpenCode CLI when winget cannot (or is absent).
    pub npm_path: Option<PathBuf>,
    /// winget is the preferred installer: `SST.opencode` needs no Node.js at
    /// all, and `OpenJS.NodeJS.LTS` unlocks the npm route when it does.
    pub winget_path: Option<PathBuf>,
}

impl DependencyStatus {
    pub fn detect() -> Self {
        Self {
            opencode_cli_path: find_opencode_cli(),
            npm_path: find_npm(),
            winget_path: find_winget(),
        }
    }

    pub fn opencode_cli_available(&self) -> bool {
        self.opencode_cli_path.is_some()
    }

    pub fn npm_available(&self) -> bool {
        self.npm_path.is_some()
    }

    pub fn winget_available(&self) -> bool {
        self.winget_path.is_some()
    }
}

/// Locates the OpenCode CLI (npm's `opencode.cmd` shim, a winget shim or a bare
/// `opencode.exe`). Shared by the dependency panel and Zen model discovery.
///
/// PATH first, then the install roots of both routes: a CLI the GUI just
/// installed lands in `%APPDATA%\npm` or in winget's links dir, and the ALREADY
/// RUNNING process does not pick up PATH changes until it is restarted —
/// without this fallback the tab would keep the "CLI not found" warning after a
/// successful install.
pub fn find_opencode_cli() -> Option<PathBuf> {
    find_on_path(&OPENCODE_NAMES)
        .or_else(|| find_in_dirs(&npm_global_dirs(), &OPENCODE_NAMES))
        .or_else(|| find_in_dirs(&winget_link_dirs(), &OPENCODE_NAMES))
}

/// Scans PATH for npm (Node.js ships `npm.cmd` on Windows), then the default
/// Node.js install root — a Node.js that winget installed a minute ago is not
/// on the running process's PATH yet.
pub fn find_npm() -> Option<PathBuf> {
    find_on_path(&NPM_NAMES).or_else(|| find_in_dirs(&nodejs_install_dirs(), &NPM_NAMES))
}

/// Scans PATH for winget (Windows 10 21H1+ / 11 ship it as an App Execution
/// Alias in `%LOCALAPPDATA%\Microsoft\WindowsApps`).
pub fn find_winget() -> Option<PathBuf> {
    find_on_path(&WINGET_NAMES).or_else(|| find_in_dirs(&windows_apps_dirs(), &WINGET_NAMES))
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
    dirs_from_env(&["APPDATA"], "npm")
}

/// Where the Node.js MSI (and therefore `winget install OpenJS.NodeJS.LTS`)
/// puts `npm.cmd`.
fn nodejs_install_dirs() -> Vec<PathBuf> {
    dirs_from_env(
        &["ProgramFiles", "ProgramW6432", "ProgramFiles(x86)"],
        "nodejs",
    )
}

/// Where winget publishes the shims of the packages it installs. `Links` is
/// the documented location for portable packages (which `SST.opencode` is);
/// the two `Programs` entries cover an installer that unpacks its own tree.
fn winget_link_dirs() -> Vec<PathBuf> {
    std::env::var_os("LOCALAPPDATA")
        .map(|local| {
            let local = Path::new(&local);
            vec![
                local.join("Microsoft").join("WinGet").join("Links"),
                local.join("Programs").join("opencode"),
                local.join("Programs").join("opencode").join("bin"),
            ]
        })
        .unwrap_or_default()
}

/// App Execution Aliases (winget itself lives here).
fn windows_apps_dirs() -> Vec<PathBuf> {
    dirs_from_env(&["LOCALAPPDATA"], "Microsoft\\WindowsApps")
}

fn dirs_from_env(variables: &[&str], suffix: &str) -> Vec<PathBuf> {
    variables
        .iter()
        .filter_map(|name| std::env::var_os(name))
        .map(|root| Path::new(&root).join(suffix))
        .collect()
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

    /// `winget install OpenJS.NodeJS.LTS` writes `npm.cmd` into
    /// `%ProgramFiles%\nodejs`, which the running process never sees on PATH.
    #[test]
    fn npm_is_also_looked_up_in_the_nodejs_install_root() {
        let dirs = nodejs_install_dirs();
        assert!(
            !dirs.is_empty(),
            "no Program Files variable in the environment"
        );
        assert!(
            dirs.iter().all(|dir| dir.ends_with("nodejs")),
            "unexpected Node.js roots: {dirs:?}"
        );
        assert!(
            winget_link_dirs()
                .iter()
                .any(|dir| dir.ends_with("Links") || dir.ends_with("opencode")),
            "winget shim dirs must cover Links and the opencode program dir"
        );
    }
}
