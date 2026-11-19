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

/// Whether the floating sidebar can overlap the page. Elsewhere it pushes the
/// page aside instead.
pub const CAN_OVERLAY: bool = cfg!(windows);

/// Ensures only one oxygen runs at a time. Returns false if another instance
/// is running; that instance's window is brought to the front.
pub fn claim_single_instance(_restarted: bool) -> bool {
    #[cfg(windows)]
    unsafe {
        use windows::core::w;
        use windows::Win32::Foundation::{CloseHandle, GetLastError, ERROR_ALREADY_EXISTS};
        use windows::Win32::System::Threading::CreateMutexW;
        // After a restart the old process may still be exiting, so wait for it.
        let attempts = if _restarted { 60 } else { 1 };
        for _ in 0..attempts {
            let Ok(handle) = CreateMutexW(None, false, w!("Local\\oxygen-browser-single-instance")) else { return true };
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
