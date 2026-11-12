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

#[cfg(target_os = "macos")]
fn claim_file(path: &std::path::Path) -> std::io::Result<Option<std::fs::File>> {
    use std::os::{fd::AsRawFd, unix::fs::OpenOptionsExt};
    let file = std::fs::OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .mode(0o600)
        .open(path)?;
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
        return Ok(Some(file));
    }
    let error = std::io::Error::last_os_error();
    if error.kind() == std::io::ErrorKind::WouldBlock {
        Ok(None)
    } else {
        Err(error)
    }
}

#[cfg(target_os = "macos")]
pub fn acquire() -> InstanceLock {
    use std::io::Write;
    use std::os::fd::IntoRawFd;
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
    let root = crate::platform::data_root();
    if std::fs::create_dir_all(&root).is_err() {
        return InstanceLock::Acquired;
    }
    let file = match claim_file(&root.join("instance.lock")) {
        Ok(Some(file)) => file,
        Ok(None) => return InstanceLock::AlreadyRunning,
        Err(error) => {
            eprintln!("Cannot acquire Delegator instance lock: {error}");
            return InstanceLock::Acquired;
        }
    };
    let fd = file.into_raw_fd();
    LOCK_HANDLE.store(fd as isize, Ordering::SeqCst);
    // Unix socket names are limited to 104 bytes on macOS. A long home path
    // (or a test profile under TMPDIR) exceeds that, so use a loopback port.
    if let Ok(listener) = std::net::TcpListener::bind(("127.0.0.1", 0)) {
        if let Ok(address) = listener.local_addr() {
            let path = root.join("instance.port");
            if let Ok(mut file) = std::fs::OpenOptions::new()
                .create(true)
                .write(true)
                .truncate(true)
                .mode(0o600)
                .open(&path)
            {
                let _ = write!(file, "{}", address.port());
                let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
            }
        }
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                drop(stream);
                crate::tray_service::request_open();
            }
        });
    }
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

#[cfg(target_os = "macos")]
pub fn raise_running_instance() {
    let path = crate::platform::data_root().join("instance.port");
    if let Some(port) = std::fs::read_to_string(path)
        .ok()
        .and_then(|s| s.parse::<u16>().ok())
    {
        let address = std::net::SocketAddr::from(([127, 0, 0, 1], port));
        let _ =
            std::net::TcpStream::connect_timeout(&address, std::time::Duration::from_millis(500));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[cfg(target_os = "macos")]
    fn lock_rejects_a_second_open_and_is_released_on_close() {
        let path =
            std::env::temp_dir().join(format!("delegator-instance-test-{}", std::process::id()));
        let first = claim_file(&path).unwrap().unwrap();
        assert!(claim_file(&path).unwrap().is_none());
        drop(first);
        assert!(claim_file(&path).unwrap().is_some());
        let _ = std::fs::remove_file(path);
    }

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
