//! One Delegator per logon session.
//!
//! Two copies are not merely untidy — they fight. Both supervise the core on
//! :1380 (so one keeps respawning what the other tree-kills), both write
//! `config.json` and would undo each other's checkboxes, both run the
//! once-per-24h `opencode upgrade`, and both put an icon in the tray so
//! «Выйти» stops meaning anything definite. The health identity check that
//! guards the CORE has no equivalent for the GUI, which is what this adds.
//!
//! The lock is a named mutex rather than a pid file: Windows releases it when
//! the process dies for ANY reason, including a taskkill or a crash, so a stale
//! lock cannot lock the user out of their own app.

use std::sync::atomic::{AtomicIsize, Ordering};

/// `Local\` scopes the name to the logon session on purpose. `Global\` would
/// make two different users on the same machine — or two RDP sessions — fight
/// over a single slot, and each of them has their own `%LOCALAPPDATA%`, their
/// own config and their own tray, so each is entitled to their own Delegator.
#[cfg(target_os = "windows")]
const MUTEX_NAME: &str = "Local\\DelegatorWin.SingleInstance";

/// Kept for the life of the process. Never closed deliberately: the OS drops it
/// at exit, which is exactly the release semantics we want.
static LOCK_HANDLE: AtomicIsize = AtomicIsize::new(0);

/// Outcome of trying to become *the* instance.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InstanceLock {
    /// We hold the lock and may start the GUI.
    Acquired,
    /// Another Delegator is already running in this session.
    AlreadyRunning,
}

/// Tries to claim the single-instance lock.
///
/// A failure to CREATE the mutex (a sandbox that forbids named objects, an
/// exotic policy) is deliberately treated as `Acquired`: refusing to start
/// because we could not take a lock would be a worse bug than the duplicate the
/// lock protects against.
/// Claims one named mutex and reports what happened, WITHOUT touching the
/// process-wide handle. Split out purely so the test can use a name of its own:
/// a test that claims the production name fails on any machine where Delegator
/// happens to be running, which is exactly the machine the owner develops on.
#[cfg(target_os = "windows")]
fn claim(name: &str) -> (InstanceLock, isize) {
    use windows_sys::Win32::Foundation::{GetLastError, ERROR_ALREADY_EXISTS};
    use windows_sys::Win32::System::Threading::CreateMutexW;

    let wide: Vec<u16> = name.encode_utf16().chain(std::iter::once(0)).collect();
    unsafe {
        let handle = CreateMutexW(std::ptr::null(), 0, wide.as_ptr());
        if handle.is_null() {
            return (InstanceLock::Acquired, 0);
        }
        // The handle is opened even when the object already existed, so the
        // error code — not the handle — is what answers the question.
        if GetLastError() == ERROR_ALREADY_EXISTS {
            return (InstanceLock::AlreadyRunning, handle as isize);
        }
        (InstanceLock::Acquired, handle as isize)
    }
}

#[cfg(target_os = "windows")]
pub fn acquire() -> InstanceLock {
    let (lock, handle) = claim(MUTEX_NAME);
    if lock == InstanceLock::Acquired && handle != 0 {
        LOCK_HANDLE.store(handle, Ordering::SeqCst);
    }
    lock
}

#[cfg(not(target_os = "windows"))]
pub fn acquire() -> InstanceLock {
    InstanceLock::Acquired
}

/// Brings the Delegator window that is already running to the front.
///
/// Best-effort by design: the running copy may legitimately be sitting in the
/// tray with no window at all (that is its normal state), in which case there
/// is nothing to raise and the second copy simply exits quietly rather than
/// reporting an error the user cannot act on.
#[cfg(target_os = "windows")]
pub fn raise_running_instance() {
    use windows_sys::Win32::Foundation::{BOOL, HWND, LPARAM};
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        EnumWindows, GetWindowTextW, IsWindowVisible,
    };

    // The window title is `Delegator v<version>` (see APP_TITLE), and the
    // version part changes with every release — an installer that leaves one
    // build running while another starts must still find it, so match the stem.
    const TITLE_STEM: &str = "Delegator v";

    unsafe extern "system" fn visit(hwnd: HWND, found: LPARAM) -> BOOL {
        unsafe {
            if IsWindowVisible(hwnd) == 0 {
                return 1;
            }
            let mut buffer = [0u16; 256];
            let len = GetWindowTextW(hwnd, buffer.as_mut_ptr(), buffer.len() as i32);
            if len <= 0 {
                return 1;
            }
            let title = String::from_utf16_lossy(&buffer[..len as usize]);
            if title.starts_with(TITLE_STEM) {
                *(found as *mut isize) = hwnd as isize;
                return 0; // stop enumerating
            }
            1
        }
    }

    let mut found: isize = 0;
    unsafe {
        EnumWindows(Some(visit), &mut found as *mut isize as LPARAM);
    }
    if found != 0 {
        crate::tray_service::attach_window_handle(found);
        crate::tray_service::raise_window();
    }
}

#[cfg(not(target_os = "windows"))]
pub fn raise_running_instance() {}

#[cfg(test)]
mod tests {
    use super::*;

    /// The first claim must win, and — the part that actually matters — a second
    /// must NOT, because that is what a second copy of the exe sees.
    ///
    /// Deliberately NOT the production name: a real Delegator running on the
    /// developer's own machine holds that one, and asserting against it turned
    /// `cargo test` into a coin flip depending on whether the tray was open.
    #[test]
    #[cfg(target_os = "windows")]
    fn the_second_claim_of_a_name_is_refused() {
        let name = format!("Local\\DelegatorWin.SelfTest-{}", std::process::id());
        let (first, handle) = claim(&name);
        assert_eq!(first, InstanceLock::Acquired);
        assert_ne!(handle, 0);
        // The handle stays open for the rest of the process, which is what keeps
        // the object alive — exactly how the real lock behaves.
        assert_eq!(claim(&name).0, InstanceLock::AlreadyRunning);
        assert_eq!(claim(&name).0, InstanceLock::AlreadyRunning);
    }
}
