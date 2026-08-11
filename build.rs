fn main() {
    #[cfg(target_os = "windows")]
    winresource::WindowsResource::new()
        .set_icon("assets/delegator.ico")
        .compile()
        .expect("failed to embed the Delegator application icon");
}
