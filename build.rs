fn main() {
    // The script's real inputs, and nothing else. With no rerun-if-changed line
    // Cargo re-runs it - and so rebuilds the whole crate - whenever ANY file of
    // the package is newer: a new .ps1 under scripts\ alone cost a debug test
    // build 8 minutes. Cargo.toml is an input because winresource reads
    // [package.metadata.winresource] from it; a version bump needs no line, it
    // gives this script's run a new hash.
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=Cargo.toml");
    println!("cargo:rerun-if-changed=assets/delegator.ico");

    #[cfg(target_os = "windows")]
    winresource::WindowsResource::new()
        .set_icon("assets/delegator.ico")
        .compile()
        .expect("failed to embed the Delegator application icon");
}
