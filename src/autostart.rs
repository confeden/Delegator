//! Start Delegator at logon — owned by the app, not only by the installer.
//!
//! ONE mechanism: the `HKCU\…\Run` value. Until 0.8.1 autostart was a shortcut
//! the installer dropped into the Startup folder, and the app had no say in it:
//! the only way to switch it off was to reinstall. Running both mechanisms at
//! once would be worse than either, because both fire at logon and the second
//! copy hits the single-instance lock (I12) — which RAISES THE WINDOW of the
//! first. A background autostart would then greet the user with a window every
//! morning. So the legacy shortcut is deleted on sight.

use crate::ide_detector::IdeDetector;
use std::path::{Path, PathBuf};
use windows_sys::Win32::Foundation::{ERROR_FILE_NOT_FOUND, ERROR_SUCCESS};
use windows_sys::Win32::System::Registry::{
    RegCloseKey, RegCreateKeyExW, RegDeleteValueW, RegOpenKeyExW, RegQueryValueExW, RegSetValueExW,
    HKEY, HKEY_CURRENT_USER, KEY_READ, KEY_SET_VALUE, REG_OPTION_NON_VOLATILE, REG_SZ,
};

const RUN_SUBKEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
const RUN_VALUE: &str = "Delegator";
/// Without it eframe shows the window, so every logon opens the GUI.
const BACKGROUND_FLAG: &str = "--background";
/// The Startup-folder shortcut older installers created.
const LEGACY_SHORTCUT: &str = "Delegator.lnk";

/// Where the autostart entry lives. A struct so tests can point at a key of
/// their own instead of the real `Run` key — a test that claims a
/// production-named OS resource breaks as soon as the real app uses it (G78).
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

    fn write(&self, command: &str) -> Result<(), String> {
        let key = open_key(&self.subkey, KEY_SET_VALUE, true)
            .ok_or_else(|| format!("HKCU\\{} could not be opened", self.subkey))?;
        let name = wide(&self.value);
        let payload = wide(command);
        let bytes = unsafe {
            std::slice::from_raw_parts(
                payload.as_ptr() as *const u8,
                std::mem::size_of_val(&payload[..]),
            )
        };
        let status = unsafe {
            RegSetValueExW(
                key,
                name.as_ptr(),
                0,
                REG_SZ,
                bytes.as_ptr(),
                bytes.len() as u32,
            )
        };
        unsafe { RegCloseKey(key) };
        if status == ERROR_SUCCESS {
            Ok(())
        } else {
            Err(format!("autostart could not be written (error {status})"))
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

/// `"C:\…\delegator.exe" --background` — quoted, because the install path holds
/// no spaces today but `%LOCALAPPDATA%` of a user whose name does is one rename
/// away, and an unquoted `Run` value is split on the first one.
fn command_for(exe: &Path) -> String {
    format!("\"{}\" {BACKGROUND_FLAG}", exe.display())
}

/// The executable a `Run` value names, if it is quoted the way we write it.
fn exe_in(command: &str) -> Option<PathBuf> {
    let rest = command.strip_prefix('"')?;
    let end = rest.find('"')?;
    Some(PathBuf::from(&rest[..end]))
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

pub fn is_enabled() -> bool {
    RunEntry::current().read().is_some()
}

pub fn set_enabled(enable: bool) -> Result<(), String> {
    let entry = RunEntry::current();
    if !enable {
        return entry.clear();
    }
    let exe = autostart_exe().ok_or_else(|| "delegator.exe was not found".to_string())?;
    entry.write(&command_for(&exe))
}

/// Startup housekeeping. Deliberately never turns autostart ON where it was off:
/// an absent entry is a decision the user made, and re-adding it behind their
/// back is exactly what made the old installer-only switch impossible to escape.
pub fn reconcile() {
    let entry = RunEntry::current();
    migrate_legacy_shortcut(&entry, &legacy_shortcut_path(), installed_exe());
    repoint_stale_entry(&entry, installed_exe());
}

fn legacy_shortcut_path() -> PathBuf {
    IdeDetector::get_appdata()
        .join(r"Microsoft\Windows\Start Menu\Programs\Startup")
        .join(LEGACY_SHORTCUT)
}

/// Carries an older install's autostart over to the `Run` value and then removes
/// the shortcut, because while both exist a logon starts Delegator twice.
///
/// This is not "switching autostart on": the shortcut IS the user's earlier yes,
/// and dropping it without a replacement would silently switch autostart OFF.
/// With no installed copy to point at — a developer build on a machine where
/// Delegator was never installed — the shortcut is left exactly as it is, and so
/// is a value that could not be written: G48 is the lesson that a build tree
/// must never rewrite the user's real setup, and half a migration is worse than
/// none.
fn migrate_legacy_shortcut(entry: &RunEntry, shortcut: &Path, installed: Option<PathBuf>) {
    if !shortcut.exists() {
        return;
    }
    let Some(installed) = installed else {
        return;
    };
    if entry.read().is_none() && entry.write(&command_for(&installed)).is_err() {
        return;
    }
    let _ = std::fs::remove_file(shortcut);
}

/// After a reinstall into a different directory the stored command names an exe
/// that no longer exists — autostart then silently does nothing. Repoint it, but
/// only when the stored target is really gone and only at an INSTALLED copy.
fn repoint_stale_entry(entry: &RunEntry, installed: Option<PathBuf>) {
    let (Some(command), Some(installed)) = (entry.read(), installed) else {
        return;
    };
    let desired = command_for(&installed);
    if command == desired {
        return;
    }
    if exe_in(&command).map(|exe| exe.exists()).unwrap_or(false) {
        // Points at something that exists — the user's own choice, hands off.
        return;
    }
    let _ = entry.write(&desired);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};
    use windows_sys::Win32::System::Registry::RegDeleteKeyW;

    /// A `Run`-shaped entry of our own, under a key no shipping code touches.
    struct TempEntry {
        entry: RunEntry,
    }

    impl TempEntry {
        fn new(tag: &str) -> Self {
            let nanos = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("clock before unix epoch")
                .as_nanos();
            // ONE level under `Software`, so `Drop` can delete the whole key:
            // a nested one would leave its (empty) parent behind on the
            // developer's machine forever, which is the exact kind of litter
            // this release is about.
            let entry = RunEntry {
                subkey: format!(
                    r"Software\DelegatorTest-autostart-{tag}-{}-{nanos}",
                    std::process::id()
                ),
                value: "TestRun".to_string(),
            };
            Self { entry }
        }
    }

    impl Drop for TempEntry {
        fn drop(&mut self) {
            let _ = self.entry.clear();
            let path = wide(&self.entry.subkey);
            unsafe { RegDeleteKeyW(HKEY_CURRENT_USER, path.as_ptr()) };
        }
    }

    #[test]
    fn writing_and_clearing_round_trips() {
        let temp = TempEntry::new("round-trip");
        assert_eq!(temp.entry.read(), None);

        let exe = PathBuf::from(r"C:\Program Files\Delegator Test\delegator.exe");
        temp.entry
            .write(&command_for(&exe))
            .expect("the value must be writable");
        let stored = temp.entry.read().expect("value");
        assert_eq!(
            stored,
            r#""C:\Program Files\Delegator Test\delegator.exe" --background"#
        );
        // The path has a space in it; without the quotes Windows would run
        // `C:\Program` at every logon.
        assert_eq!(exe_in(&stored), Some(exe));

        temp.entry.clear().expect("clear");
        assert_eq!(temp.entry.read(), None);
        // Removing what is not there is success, not an error.
        temp.entry.clear().expect("clearing twice must be a no-op");
    }

    #[test]
    fn reconcile_never_switches_autostart_on() {
        let temp = TempEntry::new("stays-off");
        let installed = std::env::temp_dir().join("delegator-autostart-test.exe");
        std::fs::write(&installed, b"MZ").expect("fake exe");

        repoint_stale_entry(&temp.entry, Some(installed.clone()));
        assert_eq!(
            temp.entry.read(),
            None,
            "an absent entry is the user's decision"
        );
        let _ = std::fs::remove_file(&installed);
    }

    #[test]
    fn a_stale_target_is_repointed_and_a_live_one_is_left_alone() {
        let temp = TempEntry::new("repoint");
        let installed = std::env::temp_dir().join("delegator-autostart-installed.exe");
        std::fs::write(&installed, b"MZ").expect("fake exe");

        // (a) The stored exe is gone: repoint to the installed copy. The path is
        // deliberately not under a user profile — the release audit reads
        // `C:\Users\<name>\…` in a source file as a leaked personal path.
        let gone = PathBuf::from(r"C:\Delegator-that-was-uninstalled\delegator.exe");
        temp.entry.write(&command_for(&gone)).expect("write");
        repoint_stale_entry(&temp.entry, Some(installed.clone()));
        assert_eq!(temp.entry.read(), Some(command_for(&installed)));

        // (b) The stored exe exists: whatever the user pointed at, leave it.
        let other = std::env::temp_dir().join("delegator-autostart-other.exe");
        std::fs::write(&other, b"MZ").expect("fake exe");
        temp.entry.write(&command_for(&other)).expect("write");
        repoint_stale_entry(&temp.entry, Some(installed.clone()));
        assert_eq!(temp.entry.read(), Some(command_for(&other)));

        // (c) No installed copy at all: never repoint at a build tree (G48).
        temp.entry.write(&command_for(&gone)).expect("write");
        repoint_stale_entry(&temp.entry, None);
        assert_eq!(temp.entry.read(), Some(command_for(&gone)));

        let _ = std::fs::remove_file(&installed);
        let _ = std::fs::remove_file(&other);
    }

    /// A stand-in for `{userstartup}\Delegator.lnk`, in a temp directory.
    fn temp_shortcut(tag: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock before unix epoch")
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "delegator-startup-{tag}-{}-{nanos}.lnk",
            std::process::id()
        ));
        std::fs::write(&path, b"shortcut").expect("fake shortcut");
        path
    }

    #[test]
    fn the_startup_shortcut_is_carried_over_and_then_removed() {
        let temp = TempEntry::new("migrate");
        let installed = std::env::temp_dir().join("delegator-autostart-migrate.exe");
        std::fs::write(&installed, b"MZ").expect("fake exe");
        let shortcut = temp_shortcut("migrate");

        migrate_legacy_shortcut(&temp.entry, &shortcut, Some(installed.clone()));
        assert_eq!(
            temp.entry.read(),
            Some(command_for(&installed)),
            "the shortcut was the user's yes; it must survive the move"
        );
        assert!(
            !shortcut.exists(),
            "both mechanisms would start Delegator twice"
        );

        let _ = std::fs::remove_file(&installed);
    }

    #[test]
    fn without_an_installed_copy_the_shortcut_is_left_alone() {
        let temp = TempEntry::new("no-install");
        let shortcut = temp_shortcut("no-install");

        migrate_legacy_shortcut(&temp.entry, &shortcut, None);
        assert!(
            shortcut.exists(),
            "half a migration switches autostart off; a dev build must not do that"
        );
        assert_eq!(temp.entry.read(), None);

        let _ = std::fs::remove_file(&shortcut);
    }

    #[test]
    fn an_existing_run_value_is_not_overwritten_by_the_migration() {
        let temp = TempEntry::new("already-set");
        let installed = std::env::temp_dir().join("delegator-autostart-set.exe");
        std::fs::write(&installed, b"MZ").expect("fake exe");
        let chosen = PathBuf::from(r"C:\Elsewhere\delegator.exe");
        temp.entry.write(&command_for(&chosen)).expect("write");
        let shortcut = temp_shortcut("already-set");

        migrate_legacy_shortcut(&temp.entry, &shortcut, Some(installed));
        assert_eq!(temp.entry.read(), Some(command_for(&chosen)));
        assert!(!shortcut.exists());

        let _ = std::fs::remove_file(&chosen);
    }

    #[test]
    fn a_command_without_quotes_yields_no_exe() {
        assert_eq!(exe_in("delegator.exe --background"), None);
        assert_eq!(exe_in("\"unterminated --background"), None);
    }
}
