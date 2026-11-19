// Embeds the oxygen logo as the .exe icon on Windows.
fn main() {
    println!("cargo:rerun-if-changed=assets/oxygen.ico");
    #[cfg(windows)]
    {
        let mut res = winresource::WindowsResource::new();
        res.set_icon("assets/oxygen.ico");
        res.set("ProductName", "oxygen");
        res.set("FileDescription", "oxygen browser");
        if let Err(e) = res.compile() {
            println!("cargo:warning=could not embed the app icon: {e}");
        }
    }
}
