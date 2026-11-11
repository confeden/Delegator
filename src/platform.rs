//! Platform paths shared with the bundled runtime (scripts/platform.ps1).
use std::path::PathBuf;

pub fn data_root() -> PathBuf {
    #[cfg(target_os = "macos")]
    {
        crate::ide_detector::IdeDetector::get_user_home()
            .join("Library/Application Support/Delegator")
    }
    #[cfg(not(target_os = "macos"))]
    {
        std::env::var_os("LOCALAPPDATA")
            .or_else(|| std::env::var_os("APPDATA"))
            .map(PathBuf::from)
            .unwrap_or_default()
            .join("DelegatorWin")
    }
}

pub const CORE_NAME: &str = if cfg!(target_os = "windows") {
    "delegator-core.exe"
} else {
    "delegator-core"
};
pub const ENTRY_NAME: &str = if cfg!(target_os = "windows") {
    "ai-delegate.cmd"
} else {
    "ai-delegate"
};

pub fn runtime_dir(executable_dir: &std::path::Path) -> PathBuf {
    #[cfg(target_os = "macos")]
    {
        executable_dir
            .parent()
            .unwrap_or(executable_dir)
            .join("Resources/runtime")
    }
    #[cfg(not(target_os = "macos"))]
    {
        executable_dir.join("runtime")
    }
}

pub fn initialize_environment() {
    #[cfg(target_os = "macos")]
    {
        // Finder/launchd do not inherit the user's interactive shell PATH.
        let home = crate::ide_detector::IdeDetector::get_user_home();
        let mut dirs = vec![
            home.join(".opencode/bin"),
            home.join(".local/bin"),
            PathBuf::from("/opt/homebrew/bin"),
            PathBuf::from("/usr/local/bin"),
        ];
        if let Some(path) = std::env::var_os("PATH") {
            dirs.extend(std::env::split_paths(&path));
        }
        if let Ok(path) = std::env::join_paths(dirs) {
            std::env::set_var("PATH", path);
        }
        if let Ok(exe) = std::env::current_exe() {
            std::env::set_var("DELEGATOR_SECRET_HELPER", &exe);
            if let Some(root) = exe.parent() {
                let pwsh = root
                    .parent()
                    .unwrap_or(root)
                    .join("Resources/powershell/pwsh");
                if pwsh.is_file() {
                    std::env::set_var("DELEGATOR_PWSH", pwsh);
                }
            }
        }
    }
}
