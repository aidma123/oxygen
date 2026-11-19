//! Small native touches. Everything is a no-op off Windows.

/// Colours the window's title bar to match the sidebar (Windows 11).
pub fn style_title_bar(_window: &tao::window::Window, _rgb: (u8, u8, u8), _dark: bool) {
    #[cfg(windows)]
    unsafe {
        use tao::platform::windows::WindowExtWindows;
        use windows::Win32::Foundation::HWND;
        use windows::Win32::Graphics::Dwm::{
            DwmSetWindowAttribute, DWMWA_BORDER_COLOR, DWMWA_CAPTION_COLOR, DWMWA_TEXT_COLOR,
            DWMWA_USE_IMMERSIVE_DARK_MODE,
        };
        let hwnd = HWND(_window.hwnd() as _);
        let (r, g, b) = _rgb;
        let colorref = |r: u8, g: u8, b: u8| -> u32 { r as u32 | (g as u32) << 8 | (b as u32) << 16 };
        let caption = colorref(r, g, b);
        let text = if _dark { colorref(0xe4, 0xeb, 0xf3) } else { colorref(0x1d, 0x27, 0x33) };
        let dark: i32 = _dark as i32;
        let set = |attr, val: &u32| {
            let _ = DwmSetWindowAttribute(hwnd, attr, val as *const u32 as _, 4);
        };
        let _ = DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark as *const i32 as _, 4);
        set(DWMWA_CAPTION_COLOR, &caption);
        set(DWMWA_BORDER_COLOR, &caption);
        set(DWMWA_TEXT_COLOR, &text);
    }
}

/// Rounds the corners of a page webview so it reads as a card on the frame.
pub fn round_corners(_view: &wry::WebView, _width: f64, _height: f64, _scale: f64, _radius: f64) {
    #[cfg(windows)]
    unsafe {
        use windows::Win32::Foundation::HWND;
        use windows::Win32::Graphics::Gdi::{CreateRoundRectRgn, SetWindowRgn};
        use wry::WebViewExtWindows;
        let hwnd = HWND(_view.hwnd().0);
        let w = (_width * _scale).round() as i32;
        let h = (_height * _scale).round() as i32;
        let d = (_radius * 2.0 * _scale).round() as i32;
        let region = CreateRoundRectRgn(0, 0, w + 1, h + 1, d, d);
        // The window owns the region after this call.
        let _ = SetWindowRgn(hwnd, Some(region), true);
    }
}

/// Puts a webview above its siblings (used for the floating sidebar).
pub fn raise(_view: &wry::WebView) {
    #[cfg(windows)]
    unsafe {
        use windows::Win32::Foundation::HWND;
        use windows::Win32::UI::WindowsAndMessaging::{SetWindowPos, HWND_TOP, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE};
        use wry::WebViewExtWindows;
        let _ = SetWindowPos(HWND(_view.hwnd().0), Some(HWND_TOP), 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    }
}

/// Removes the rounded corners (used while a video is full screen).
pub fn square_corners(_view: &wry::WebView) {
    #[cfg(windows)]
    unsafe {
        use windows::Win32::Foundation::HWND;
        use windows::Win32::Graphics::Gdi::SetWindowRgn;
        use wry::WebViewExtWindows;
        let _ = SetWindowRgn(HWND(_view.hwnd().0), None, true);
    }
}

/// Chromium's password saving and form autofill for a page.
pub fn set_autofill(_view: &wry::WebView, _save_passwords: bool) {
    #[cfg(windows)]
    unsafe {
        use webview2_com::Microsoft::Web::WebView2::Win32::ICoreWebView2Settings4;
        use windows::core::Interface;
        use wry::WebViewExtWindows;
        if let Ok(settings) = _view.webview().Settings() {
            if let Ok(s4) = settings.cast::<ICoreWebView2Settings4>() {
                let _ = s4.SetIsPasswordAutosaveEnabled(_save_passwords);
                let _ = s4.SetIsGeneralAutofillEnabled(_save_passwords);
            }
        }
    }
}

/// Calls `changed(true/false)` when the page enters or leaves HTML full screen
/// (a video's full-screen button). WebView2 leaves resizing to the app.
pub fn on_page_fullscreen(_view: &wry::WebView, _changed: impl Fn(bool) + 'static) {
    #[cfg(windows)]
    unsafe {
        use webview2_com::ContainsFullScreenElementChangedEventHandler;
        use wry::WebViewExtWindows;
        let handler = ContainsFullScreenElementChangedEventHandler::create(Box::new(move |sender, _| {
            if let Some(sender) = sender {
                let mut full = windows::core::BOOL::default();
                let _ = sender.ContainsFullScreenElement(&mut full);
                _changed(full.as_bool());
            }
            Ok(())
        }));
        let mut token = Default::default();
        let _ = _view.webview().add_ContainsFullScreenElementChanged(&handler, &mut token);
    }
}

/// What to clear from the profile.
pub enum ClearKind {
    Cache,
    CookiesAndSiteData,
    History,
}

/// Clears browsing data for the whole profile, then calls `done`.
pub fn clear_browsing_data(_view: &wry::WebView, _kind: ClearKind, done: impl FnOnce() + 'static) {
    #[cfg(windows)]
    unsafe {
        use webview2_com::ClearBrowsingDataCompletedHandler;
        use webview2_com::Microsoft::Web::WebView2::Win32::*;
        use windows::core::Interface;
        use wry::WebViewExtWindows;
        let kinds = match _kind {
            ClearKind::Cache => COREWEBVIEW2_BROWSING_DATA_KINDS_DISK_CACHE,
            ClearKind::CookiesAndSiteData => COREWEBVIEW2_BROWSING_DATA_KINDS_ALL_SITE,
            ClearKind::History => COREWEBVIEW2_BROWSING_DATA_KINDS_BROWSING_HISTORY,
        };
        let profile = _view
            .webview()
            .cast::<ICoreWebView2_13>()
            .and_then(|w| w.Profile())
            .and_then(|p| p.cast::<ICoreWebView2Profile2>());
        if let Ok(profile) = profile {
            let handler = ClearBrowsingDataCompletedHandler::create(Box::new(move |_| {
                done();
                Ok(())
            }));
            let _ = profile.ClearBrowsingData(kinds, &handler);
            return;
        }
    }
    #[allow(unreachable_code)]
    done();
}

/// Whether the floating sidebar can overlap the page. Elsewhere it pushes the
/// page aside instead.
pub const CAN_OVERLAY: bool = cfg!(windows);

/// Ensures only one oxygen runs at a time. Returns false if another instance
/// is running; that instance's window is brought to the front.
pub fn claim_single_instance(_restarted: bool) -> bool {
    #[cfg(windows)]
    unsafe {
        use std::hash::{Hash, Hasher};
        use windows::core::HSTRING;
        use windows::Win32::Foundation::{CloseHandle, GetLastError, ERROR_ALREADY_EXISTS};
        use windows::Win32::System::Threading::CreateMutexW;
        // One instance per profile folder, so a separate test profile can run
        // alongside the normal one.
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        crate::session::data_dir().hash(&mut hasher);
        let name = HSTRING::from(format!("Local\\oxygen-browser-{:x}", hasher.finish()));
        // After a restart the old process may still be exiting, so wait for it.
        let attempts = if _restarted { 60 } else { 1 };
        for _ in 0..attempts {
            let Ok(handle) = CreateMutexW(None, false, &name) else { return true };
            if GetLastError() != ERROR_ALREADY_EXISTS {
                // The handle stays open for the life of the process.
                return true;
            }
            let _ = CloseHandle(handle);
            if _restarted {
                std::thread::sleep(std::time::Duration::from_millis(100));
            }
        }
        focus_existing();
        false
    }
    #[cfg(not(windows))]
    true
}

#[cfg(windows)]
fn hwnd_file() -> std::path::PathBuf {
    crate::session::data_dir().join("window.id")
}

/// Records this instance's window so a second launch can bring it forward.
pub fn record_window(_window: &tao::window::Window) {
    #[cfg(windows)]
    {
        use tao::platform::windows::WindowExtWindows;
        let _ = std::fs::write(hwnd_file(), _window.hwnd().to_string());
    }
}

#[cfg(windows)]
fn focus_existing() {
    use windows::Win32::Foundation::HWND;
    use windows::Win32::UI::WindowsAndMessaging::{IsIconic, IsWindow, SetForegroundWindow, ShowWindow, SW_RESTORE};
    let Some(raw) = std::fs::read_to_string(hwnd_file()).ok().and_then(|s| s.trim().parse::<isize>().ok()) else { return };
    unsafe {
        let hwnd = HWND(raw as _);
        if IsWindow(Some(hwnd)).as_bool() {
            if IsIconic(hwnd).as_bool() {
                let _ = ShowWindow(hwnd, SW_RESTORE);
            }
            let _ = SetForegroundWindow(hwnd);
        }
    }
}
