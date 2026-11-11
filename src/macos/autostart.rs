use std::path::PathBuf;
const LABEL: &str = "org.delegator.macos";

fn agent_path() -> PathBuf {
    crate::ide_detector::IdeDetector::get_user_home()
        .join("Library/LaunchAgents")
        .join(format!("{LABEL}.plist"))
}
fn xml(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}
fn agent(exe: &std::path::Path) -> String {
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>{LABEL}</string>
<key>ProgramArguments</key><array><string>{}</string><string>--background</string></array>
<key>RunAtLoad</key><true/>
</dict></plist>
"#,
        xml(&exe.to_string_lossy())
    )
}
pub fn is_enabled() -> bool {
    agent_path().is_file()
}
pub fn set_enabled(enabled: bool) -> Result<(), String> {
    let path = agent_path();
    if enabled {
        let exe = std::env::current_exe().map_err(|e| e.to_string())?;
        std::fs::create_dir_all(path.parent().unwrap()).map_err(|e| e.to_string())?;
        std::fs::write(path, agent(&exe)).map_err(|e| e.to_string())
    } else {
        match std::fs::remove_file(path) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(e.to_string()),
        }
    }
}
pub fn reconcile() {
    if is_enabled() {
        let _ = set_enabled(true);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn launch_agent_preserves_spaces_and_escapes_xml() {
        let content = agent(std::path::Path::new(
            "/Applications/A & B.app/Contents/MacOS/delegator",
        ));
        assert!(content.contains("A &amp; B.app"));
        assert!(content.contains("<string>--background</string>"));
        assert!(!content.contains("KeepAlive"));
    }
}
