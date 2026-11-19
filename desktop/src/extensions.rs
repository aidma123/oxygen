//! Chrome extensions, run by WebView2's own extension support.
//!
//! Extensions are installed from the Chrome Web Store (the .crx package is
//! downloaded and unpacked into the profile's `extensions` folder) or by
//! dropping an unpacked extension folder there. WebView2 doesn't draw
//! extension toolbar buttons, so oxygen shows them in the sidebar and opens
//! their popup pages itself.

use serde::Serialize;
use std::path::{Path, PathBuf};

#[derive(Serialize, Clone, Debug)]
pub struct Extension {
    /// WebView2's id for the extension (used in chrome-extension:// URLs).
    pub id: String,
    pub name: String,
    pub enabled: bool,
    /// Data URL of the extension's icon, if it has one.
    pub icon: String,
    /// Path of the popup page inside the extension, if it has one.
    pub popup: String,
}

pub fn folder() -> PathBuf {
    crate::session::data_dir().join("extensions")
}

/// Extracts a Web Store extension id from a store link or a bare id.
pub fn parse_store_id(input: &str) -> Option<String> {
    let is_id = |s: &str| s.len() == 32 && s.bytes().all(|b| (b'a'..=b'p').contains(&b));
    let trimmed = input.trim();
    if is_id(trimmed) {
        return Some(trimmed.to_string());
    }
    trimmed
        .split(['/', '?', '#', '&', '='])
        .find(|part| is_id(part))
        .map(str::to_string)
}

/// Whether a URL is an extension's page on the Chrome Web Store.
pub fn store_id_from_url(url: &str) -> Option<String> {
    let lower = url.to_ascii_lowercase();
    if lower.starts_with("https://chromewebstore.google.com/detail/")
        || lower.starts_with("https://chrome.google.com/webstore/detail/")
    {
        parse_store_id(url)
    } else {
        None
    }
}

/// Returns the zip archive inside a .crx package (CRX2 or CRX3).
pub fn crx_to_zip(crx: &[u8]) -> Result<&[u8], String> {
    let u32_at = |i: usize| -> Option<usize> {
        crx.get(i..i + 4).map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]) as usize)
    };
    if crx.get(0..4) != Some(b"Cr24") {
        // Some downloads are already plain zips.
        return if crx.starts_with(b"PK") { Ok(crx) } else { Err("not an extension package".into()) };
    }
    let start = match u32_at(4) {
        Some(3) => 12 + u32_at(8).ok_or("damaged package")?,
        Some(2) => 16 + u32_at(8).ok_or("damaged package")? + u32_at(12).ok_or("damaged package")?,
        _ => return Err("unsupported package version".into()),
    };
    crx.get(start..).filter(|z| z.starts_with(b"PK")).ok_or_else(|| "damaged package".into())
}

/// Downloads a Web Store extension and unpacks it into the extensions
/// folder. Runs on a background thread; returns the unpacked folder.
pub fn download_from_store(id: &str) -> Result<PathBuf, String> {
    let dest = folder().join(id);
    let tmp = crate::session::data_dir().join("download");
    let _ = std::fs::create_dir_all(&tmp);
    let crx_path = tmp.join(format!("{id}.crx"));
    let url = format!(
        "https://clients2.google.com/service/update2/crx?response=redirect&prodversion=157.0.0.0&acceptformat=crx2,crx3&x=id%3D{id}%26uc"
    );
    run_hidden("curl.exe", &["-fsSL", "--retry", "2", "-o", &crx_path.to_string_lossy(), &url])
        .map_err(|e| format!("Download failed ({e}). Check the link and your connection."))?;
    let crx = std::fs::read(&crx_path).map_err(|e| e.to_string())?;
    let zip = crx_to_zip(&crx)?;
    let zip_path = tmp.join(format!("{id}.zip"));
    std::fs::write(&zip_path, zip).map_err(|e| e.to_string())?;
    let _ = std::fs::remove_dir_all(&dest);
    std::fs::create_dir_all(&dest).map_err(|e| e.to_string())?;
    // Windows ships bsdtar, which unpacks zip archives.
    run_hidden("tar.exe", &["-xf", &zip_path.to_string_lossy(), "-C", &dest.to_string_lossy()])
        .map_err(|e| format!("Couldn't unpack the extension ({e})"))?;
    // Store packages carry signature metadata that unpacked extensions may not contain.
    let _ = std::fs::remove_dir_all(dest.join("_metadata"));
    let _ = std::fs::remove_file(crx_path);
    let _ = std::fs::remove_file(zip_path);
    if !dest.join("manifest.json").exists() {
        let _ = std::fs::remove_dir_all(&dest);
        return Err("The package has no manifest.json".into());
    }
    Ok(dest)
}

fn run_hidden(program: &str, args: &[&str]) -> Result<(), String> {
    let mut cmd = std::process::Command::new(program);
    cmd.args(args);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    let out = cmd.output().map_err(|e| e.to_string())?;
    if out.status.success() {
        Ok(())
    } else {
        let msg = String::from_utf8_lossy(&out.stderr).trim().to_string();
        Err(if msg.is_empty() { format!("exit code {:?}", out.status.code()) } else { msg })
    }
}

/// Icon and popup page from an extension's manifest.
pub fn manifest_details(dir: &Path) -> (String, String) {
    let Ok(text) = std::fs::read_to_string(dir.join("manifest.json")) else { return (String::new(), String::new()) };
    let text = text.trim_start_matches('\u{feff}');
    let Ok(m) = serde_json::from_str::<serde_json::Value>(text) else { return (String::new(), String::new()) };
    let action = m.get("action").or_else(|| m.get("browser_action")).or_else(|| m.get("page_action"));
    let popup = action
        .and_then(|a| a.get("default_popup"))
        .and_then(|p| p.as_str())
        .unwrap_or("")
        .trim_start_matches('/')
        .to_string();
    // Prefer an icon close to 32 px.
    let mut candidates: Vec<String> = Vec::new();
    let mut push_icons = |v: Option<&serde_json::Value>| match v {
        Some(serde_json::Value::String(s)) => candidates.push(s.clone()),
        Some(serde_json::Value::Object(map)) => {
            for size in ["32", "48", "38", "24", "19", "16", "64", "128"] {
                if let Some(s) = map.get(size).and_then(|s| s.as_str()) {
                    candidates.push(s.to_string());
                }
            }
        }
        _ => {}
    };
    push_icons(action.and_then(|a| a.get("default_icon")));
    push_icons(m.get("icons"));
    let icon = candidates
        .iter()
        .find_map(|rel| {
            let rel = rel.trim_start_matches('/');
            let bytes = std::fs::read(dir.join(rel)).ok()?;
            let mime = if rel.ends_with(".svg") { "image/svg+xml" } else if rel.ends_with(".jpg") || rel.ends_with(".jpeg") { "image/jpeg" } else { "image/png" };
            Some(format!("data:{mime};base64,{}", crate::base64(&bytes)))
        })
        .unwrap_or_default();
    (icon, popup)
}

fn disabled_path() -> PathBuf {
    crate::session::data_dir().join("extensions-disabled.json")
}

/// Folder names of extensions the user switched off.
pub fn load_disabled() -> Vec<String> {
    std::fs::read(disabled_path())
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}

pub fn save_disabled(names: &[String]) {
    if let Ok(json) = serde_json::to_vec(names) {
        let _ = std::fs::write(disabled_path(), json);
    }
}

pub fn folder_name(dir: &Path) -> String {
    dir.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
}

/// Unpacked extension folders in the profile.
pub fn installed_folders() -> Vec<PathBuf> {
    std::fs::read_dir(folder())
        .map(|it| {
            it.filter_map(|e| e.ok())
                .map(|e| e.path())
                .filter(|p| p.is_dir() && p.join("manifest.json").exists())
                .collect()
        })
        .unwrap_or_default()
}

#[cfg(windows)]
mod native {
    use webview2_com::Microsoft::Web::WebView2::Win32::*;
    use webview2_com::{
        BrowserExtensionEnableCompletedHandler, BrowserExtensionRemoveCompletedHandler,
        ProfileAddBrowserExtensionCompletedHandler, ProfileGetBrowserExtensionsCompletedHandler,
    };
    use windows::core::{Interface, HSTRING, PWSTR};
    use wry::WebViewExtWindows;

    fn profile(view: &wry::WebView) -> Option<ICoreWebView2Profile7> {
        let webview: ICoreWebView2_13 = view.webview().cast().ok()?;
        unsafe { webview.Profile().ok()?.cast().ok() }
    }

    fn read(ext: &ICoreWebView2BrowserExtension) -> (String, String, bool) {
        unsafe {
            let mut id = PWSTR::null();
            let mut name = PWSTR::null();
            let mut enabled = windows::core::BOOL::default();
            let _ = ext.Id(&mut id);
            let _ = ext.Name(&mut name);
            let _ = ext.IsEnabled(&mut enabled);
            (webview2_com::take_pwstr(id), webview2_com::take_pwstr(name), enabled.as_bool())
        }
    }

    /// Calls `done` with (id, name, enabled) for every installed extension.
    pub fn list(view: &wry::WebView, done: impl FnOnce(Vec<(String, String, bool)>) + 'static) {
        let Some(profile) = profile(view) else { return done(Vec::new()) };
        let handler = ProfileGetBrowserExtensionsCompletedHandler::create(Box::new(move |_, list| {
            let mut out = Vec::new();
            if let Some(list) = list {
                unsafe {
                    let mut count = 0u32;
                    let _ = list.Count(&mut count);
                    for i in 0..count {
                        if let Ok(ext) = list.GetValueAtIndex(i) {
                            out.push(read(&ext));
                        }
                    }
                }
            }
            done(out);
            Ok(())
        }));
        unsafe {
            let _ = profile.GetBrowserExtensions(&handler);
        }
    }

    /// Loads an unpacked extension folder. `done` gets the new id or an error.
    pub fn add(view: &wry::WebView, dir: &std::path::Path, done: impl FnOnce(Result<String, String>) + 'static) {
        let Some(profile) = profile(view) else { return done(Err("Extensions aren't available".into())) };
        let handler = ProfileAddBrowserExtensionCompletedHandler::create(Box::new(move |result, ext| {
            match (result, ext) {
                (Ok(()), Some(ext)) => done(Ok(read(&ext).0)),
                (Err(e), _) => done(Err(format!("WebView2 couldn't load it ({})", e.message()))),
                _ => done(Err("WebView2 couldn't load it".into())),
            }
            Ok(())
        }));
        unsafe {
            if let Err(e) = profile.AddBrowserExtension(&HSTRING::from(dir), &handler) {
                eprintln!("AddBrowserExtension failed: {e}");
            }
        }
    }

    fn with_extension(view: &wry::WebView, id: String, f: impl FnOnce(ICoreWebView2BrowserExtension) + 'static) {
        let Some(profile) = profile(view) else { return };
        let handler = ProfileGetBrowserExtensionsCompletedHandler::create(Box::new(move |_, list| {
            if let Some(list) = list {
                unsafe {
                    let mut count = 0u32;
                    let _ = list.Count(&mut count);
                    for i in 0..count {
                        if let Ok(ext) = list.GetValueAtIndex(i) {
                            if read(&ext).0 == id {
                                f(ext);
                                break;
                            }
                        }
                    }
                }
            }
            Ok(())
        }));
        unsafe {
            let _ = profile.GetBrowserExtensions(&handler);
        }
    }

    pub fn set_enabled(view: &wry::WebView, id: String, enabled: bool, done: impl FnOnce() + 'static) {
        with_extension(view, id, move |ext| unsafe {
            let handler = BrowserExtensionEnableCompletedHandler::create(Box::new(move |_| {
                done();
                Ok(())
            }));
            let _ = ext.Enable(enabled, &handler);
        });
    }

    pub fn remove(view: &wry::WebView, id: String, done: impl FnOnce() + 'static) {
        with_extension(view, id, move |ext| unsafe {
            let handler = BrowserExtensionRemoveCompletedHandler::create(Box::new(move |_| {
                done();
                Ok(())
            }));
            let _ = ext.Remove(&handler);
        });
    }
}

#[cfg(windows)]
pub use native::{add, list, remove, set_enabled};

#[cfg(not(windows))]
mod native_stub {
    pub fn list(_: &wry::WebView, done: impl FnOnce(Vec<(String, String, bool)>) + 'static) {
        done(Vec::new())
    }
    pub fn add(_: &wry::WebView, _: &std::path::Path, done: impl FnOnce(Result<String, String>) + 'static) {
        done(Err("Extensions are only supported on Windows".into()))
    }
    pub fn set_enabled(_: &wry::WebView, _: String, _: bool, done: impl FnOnce() + 'static) {
        done()
    }
    pub fn remove(_: &wry::WebView, _: String, done: impl FnOnce() + 'static) {
        done()
    }
}

#[cfg(not(windows))]
pub use native_stub::{add, list, remove, set_enabled};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_store_links() {
        let id = "cjpalhdlnbpafiamejdnhcphjbkeiagm";
        assert_eq!(parse_store_id(id).as_deref(), Some(id));
        assert_eq!(
            parse_store_id(&format!("https://chromewebstore.google.com/detail/ublock-origin/{id}?hl=en")).as_deref(),
            Some(id)
        );
        assert_eq!(store_id_from_url(&format!("https://chrome.google.com/webstore/detail/x/{id}")).as_deref(), Some(id));
        assert_eq!(store_id_from_url("https://example.com/"), None);
        assert_eq!(parse_store_id("not an id"), None);
    }

    /// Downloads a real extension (needs network): `cargo test -- --ignored`.
    #[test]
    #[ignore]
    fn downloads_from_web_store() {
        let dir = download_from_store("ddkjiahejlhfcafbddmgiahcphecmpfh").expect("download");
        assert!(dir.join("manifest.json").exists());
        let (icon, popup) = manifest_details(&dir);
        assert!(icon.starts_with("data:image/"));
        assert!(!popup.is_empty());
    }

    #[test]
    fn unwraps_crx3() {
        let mut crx = b"Cr24".to_vec();
        crx.extend(3u32.to_le_bytes());
        crx.extend(4u32.to_le_bytes());
        crx.extend([0u8; 4]);
        crx.extend(b"PK\x03\x04rest");
        assert_eq!(crx_to_zip(&crx).unwrap(), b"PK\x03\x04rest");
        assert!(crx_to_zip(b"nonsense").is_err());
    }
}
