//! Start Delegator at logon — a shortcut in the user's Startup folder.
//!
//! ONE mechanism: `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Delegator.lnk`,
//! aimed at the INSTALLED `delegator.exe` with `--background`. The `Run` registry
//! value 0.8.x–0.9.x wrote is migrated into the shortcut and then removed, so the
//! two can never both fire at logon: the second copy would hit the single-instance
//! lock (I12), which RAISES THE WINDOW of the first, and a background autostart
//! would greet the user with a window every morning.

use crate::ide_detector::IdeDetector;
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use windows_sys::Win32::Foundation::{ERROR_FILE_NOT_FOUND, ERROR_SUCCESS};
use windows_sys::Win32::System::Registry::{
    RegCloseKey, RegCreateKeyExW, RegDeleteValueW, RegOpenKeyExW, RegQueryValueExW, HKEY,
    HKEY_CURRENT_USER, KEY_READ, KEY_SET_VALUE, REG_OPTION_NON_VOLATILE,
};

/// The value 0.8.x–0.9.x wrote; read only to migrate it, never written again.
const RUN_SUBKEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
const RUN_VALUE: &str = "Delegator";
/// Without it eframe shows the window, so every logon opens the GUI.
const BACKGROUND_FLAG: &str = "--background";
const SHORTCUT_NAME: &str = "Delegator.lnk";
/// CREATE_NO_WINDOW: the PowerShell helper must not flash a console at logon.
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// The legacy `Run` value. A struct so tests can point at a key of their own (G78).
#[derive(Debug, Clone)]
struct RunEntry {
    subkey: String,
    value: String,
}

impl RunEntry {
    fn current() -> Self {
        Self {
            subkey: RUN_SUBKEY.to_string(),
            value: RUN_VALUE.to_string(),
        }
    }

    fn read(&self) -> Option<String> {
        let key = open_key(&self.subkey, KEY_READ, false)?;
        let name = wide(&self.value);
        let mut kind: u32 = 0;
        let mut size: u32 = 0;
        let probe = unsafe {
            RegQueryValueExW(
                key,
                name.as_ptr(),
                std::ptr::null(),
                &mut kind,
                std::ptr::null_mut(),
                &mut size,
            )
        };
        if probe != ERROR_SUCCESS || size < 2 {
            unsafe { RegCloseKey(key) };
            return None;
        }
        let mut buffer = vec![0u8; size as usize];
        let status = unsafe {
            RegQueryValueExW(
                key,
                name.as_ptr(),
                std::ptr::null(),
                &mut kind,
                buffer.as_mut_ptr(),
                &mut size,
            )
        };
        unsafe { RegCloseKey(key) };
        if status != ERROR_SUCCESS {
            return None;
        }
        // REG_SZ is UTF-16 and the terminator is not guaranteed to be counted.
        let units: Vec<u16> = buffer[..size as usize]
            .chunks_exact(2)
            .map(|pair| u16::from_le_bytes([pair[0], pair[1]]))
            .collect();
        let text = String::from_utf16_lossy(&units);
        let text = text.trim_end_matches('\0').to_string();
        if text.is_empty() {
            None
        } else {
            Some(text)
        }
    }

    fn clear(&self) -> Result<(), String> {
        // A missing key means a missing value: nothing to remove, and creating
        // the key just to delete from it would be litter.
        let key = match open_key(&self.subkey, KEY_SET_VALUE, false) {
            Some(key) => key,
            None => return Ok(()),
        };
        let name = wide(&self.value);
        let status = unsafe { RegDeleteValueW(key, name.as_ptr()) };
        unsafe { RegCloseKey(key) };
        if status == ERROR_SUCCESS || status == ERROR_FILE_NOT_FOUND {
            Ok(())
        } else {
            Err(format!("autostart could not be removed (error {status})"))
        }
    }
}

fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(std::iter::once(0)).collect()
}

fn open_key(subkey: &str, access: u32, create: bool) -> Option<HKEY> {
    let mut handle: HKEY = std::ptr::null_mut();
    let path = wide(subkey);
    let status = unsafe {
        if create {
            RegCreateKeyExW(
                HKEY_CURRENT_USER,
                path.as_ptr(),
                0,
                std::ptr::null_mut(),
                REG_OPTION_NON_VOLATILE,
                access,
                std::ptr::null(),
                &mut handle,
                std::ptr::null_mut(),
            )
        } else {
            RegOpenKeyExW(HKEY_CURRENT_USER, path.as_ptr(), 0, access, &mut handle)
        }
    };
    if status == ERROR_SUCCESS {
        Some(handle)
    } else {
        None
    }
}

fn installed_exe() -> Option<PathBuf> {
    let candidate = IdeDetector::get_local_appdata().join(r"Programs\Delegator\delegator.exe");
    candidate.exists().then_some(candidate)
}

/// The copy that should start at logon: the INSTALLED one when it exists, so a
/// developer build never registers a path into its build tree (the trap G48
/// describes for instruction files), and the running copy otherwise.
fn autostart_exe() -> Option<PathBuf> {
    installed_exe().or_else(|| std::env::current_exe().ok())
}

/// The Startup folder of the current user.
fn startup_dir() -> PathBuf {
    IdeDetector::get_appdata().join(r"Microsoft\Windows\Start Menu\Programs\Startup")
}

fn shortcut_path(dir: &Path) -> PathBuf {
    dir.join(SHORTCUT_NAME)
}

/// PowerShell single-quoted literal: the only quote to double is `'`.
fn ps_quote(text: &str) -> String {
    text.replace('\'', "''")
}

/// Writes the shortcut through WScript.Shell, the same COM object Explorer uses.
fn write_shortcut(path: &Path, exe: &Path) -> Result<(), String> {
    let working_dir = exe.parent().unwrap_or(Path::new(""));
    let script = format!(
        "$s=(New-Object -ComObject WScript.Shell).CreateShortcut('{}');         $s.TargetPath='{}';$s.Arguments='{BACKGROUND_FLAG}';         $s.WorkingDirectory='{}';$s.Save()",
        ps_quote(&path.display().to_string()),
        ps_quote(&exe.display().to_string()),
        ps_quote(&working_dir.display().to_string()),
    );
    let output = Command::new("powershell.exe")
        .args([
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            &script,
        ])
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .map_err(|error| format!("PowerShell did not start: {error}"))?;
    if output.status.success() && path.exists() {
        Ok(())
    } else {
        Err(format!(
            "autostart shortcut could not be written: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ))
    }
}

/// The copy that should start at logon: the INSTALLED one only, so a developer
/// build never registers a path into its build tree (G48).
pub fn is_enabled() -> bool {
    shortcut_path(&startup_dir()).exists()
}

pub fn set_enabled(enable: bool) -> Result<(), String> {
    let path = shortcut_path(&startup_dir());
    if !enable {
        return match std::fs::remove_file(&path) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(format!("autostart could not be removed: {error}")),
        };
    }
    let exe = autostart_exe().ok_or_else(|| "delegator.exe was not found".to_string())?;
    write_shortcut(&path, &exe)
}

/// Startup housekeeping. Never turns autostart ON where it was off. A legacy
/// `Run` value is carried into the shortcut and removed only once the shortcut
/// exists, so a failed write leaves the user's yes where it was.
pub fn reconcile() {
    let legacy = RunEntry::current();
    if legacy.read().is_none() {
        return;
    }
    let Some(installed) = installed_exe() else {
        return;
    };
    let path = shortcut_path(&startup_dir());
    if !path.exists() && write_shortcut(&path, &installed).is_err() {
        return;
    }
    let _ = legacy.clear();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ps_quote_doubles_only_the_single_quote() {
        assert_eq!(
            ps_quote(r"D:\Apps\O'Brien\x.lnk"),
            r"D:\Apps\O''Brien\x.lnk"
        );
    }

    #[test]
    fn the_shortcut_lives_in_startup_and_is_named_delegator() {
        let dir = Path::new(r"C:\Startup");
        assert_eq!(shortcut_path(dir), Path::new(r"C:\Startup\Delegator.lnk"));
    }

    #[test]
    fn startup_dir_is_the_per_user_startup_folder() {
        assert!(
            startup_dir().ends_with(Path::new(r"Microsoft\Windows\Start Menu\Programs\Startup"))
        );
    }
}
