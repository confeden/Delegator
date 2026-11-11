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
        // Prompts, logs and database files created by this process and its
        // children belong to this user only, as with Windows profile ACLs.
        unsafe {
            libc::umask(0o077);
        }
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

/// Children may create their own process groups (provider timeout isolation).
/// Walk the owned process tree as well as terminating the core itself.
#[cfg(target_os = "macos")]
pub fn kill_process_tree(pid: u32) {
    fn descendants(pid: u32, depth: usize) {
        if depth > 32 {
            return;
        }
        if let Ok(output) = std::process::Command::new("/usr/bin/pgrep")
            .args(["-P", &pid.to_string()])
            .output()
        {
            for child in String::from_utf8_lossy(&output.stdout).split_whitespace() {
                if let Ok(child) = child.parse::<u32>() {
                    descendants(child, depth + 1);
                }
            }
        }
        unsafe {
            libc::kill(pid as i32, libc::SIGKILL);
        }
    }
    descendants(pid, 0);
}

/// Also clean up a core adopted after a previous GUI crash. Match the exact
/// executable and current user; never kill unrelated Python/Core processes.
#[cfg(target_os = "macos")]
pub fn kill_leftover_core() {
    let Ok(exe) = std::env::current_exe() else {
        return;
    };
    let Some(root) = exe.parent() else {
        return;
    };
    let core = root.join(CORE_NAME);
    let Ok(output) = std::process::Command::new("/bin/ps")
        .args(["-axo", "uid=,pid=,comm="])
        .output()
    else {
        return;
    };
    for line in String::from_utf8_lossy(&output.stdout).lines() {
        let Some((uid, rest)) = line.trim_start().split_once(char::is_whitespace) else {
            continue;
        };
        let Some((pid, command)) = rest.trim_start().split_once(char::is_whitespace) else {
            continue;
        };
        if uid.parse::<u32>().ok() == Some(unsafe { libc::geteuid() })
            && std::path::Path::new(command.trim()) == core
        {
            if let Ok(pid) = pid.parse() {
                kill_process_tree(pid);
            }
        }
    }
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;
    use std::io::BufRead;

    #[test]
    fn stopping_core_also_stops_children_in_separate_sessions() {
        let mut parent = std::process::Command::new("python3").args(["-c",
            "import subprocess,time; p=subprocess.Popen(['/bin/sleep','60'], start_new_session=True); print(p.pid,flush=True); p.wait(); time.sleep(60)"])
            .stdout(std::process::Stdio::piped()).spawn().unwrap();
        let mut reader = std::io::BufReader::new(parent.stdout.take().unwrap());
        let mut child = String::new();
        reader.read_line(&mut child).unwrap();
        kill_process_tree(parent.id());
        assert!(!parent.wait().unwrap().success());
        let status = std::process::Command::new("/bin/ps")
            .args(["-p", child.trim(), "-o", "stat="])
            .output()
            .unwrap();
        let status = String::from_utf8_lossy(&status.stdout);
        assert!(
            status.trim().is_empty() || status.trim().starts_with('Z'),
            "child still running: {status}"
        );
    }
}
