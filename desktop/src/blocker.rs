#![cfg_attr(not(windows), allow(dead_code))]
//! Built-in ad and tracker blocker. Requests to listed hosts (and their
//! subdomains) are answered with an empty 403 before they leave the machine.

use std::collections::HashSet;
use std::sync::OnceLock;

static LIST: &str = include_str!("blocklist.txt");

fn hosts() -> &'static HashSet<&'static str> {
    static SET: OnceLock<HashSet<&'static str>> = OnceLock::new();
    SET.get_or_init(|| {
        LIST.lines()
            .map(str::trim)
            .filter(|l| !l.is_empty() && !l.starts_with('#') && !l.contains('/'))
            .collect()
    })
}

/// Extracts the lowercase host from a URL without pulling in a URL parser.
fn host_of(url: &str) -> Option<String> {
    let rest = url.split_once("://")?.1;
    let end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let authority = &rest[..end];
    let authority = authority.rsplit_once('@').map_or(authority, |(_, h)| h);
    let host = authority.split(':').next()?;
    Some(host.to_ascii_lowercase())
}

pub fn is_blocked(url: &str) -> bool {
    let Some(host) = host_of(url) else { return false };
    let set = hosts();
    let mut h = host.as_str();
    loop {
        if set.contains(h) {
            return true;
        }
        match h.find('.') {
            Some(i) => h = &h[i + 1..],
            None => return false,
        }
    }
}

#[cfg(windows)]
pub fn install(view: &wry::WebView) {
    use webview2_com::Microsoft::Web::WebView2::Win32::*;
    use webview2_com::WebResourceRequestedEventHandler;
    use windows::core::{w, PWSTR};
    use wry::WebViewExtWindows;

    let webview = view.webview();
    let env = view.environment();
    unsafe {
        if webview
            .AddWebResourceRequestedFilter(w!("*"), COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL)
            .is_err()
        {
            return;
        }
        let handler = WebResourceRequestedEventHandler::create(Box::new(move |_, args| {
            let Some(args) = args else { return Ok(()) };
            let request = args.Request()?;
            let mut uri = PWSTR::null();
            request.Uri(&mut uri)?;
            let uri = webview2_com::take_pwstr(uri);
            if is_blocked(&uri) {
                let response = env.CreateWebResourceResponse(None, 403, w!("Blocked"), w!(""))?;
                args.SetResponse(&response)?;
            }
            Ok(())
        }));
        let mut token = Default::default();
        let _ = webview.add_WebResourceRequested(&handler, &mut token);
    }
}

#[cfg(not(windows))]
pub fn install(_view: &wry::WebView) {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blocks_listed_hosts_and_subdomains() {
        assert!(is_blocked("https://doubleclick.net/x"));
        assert!(is_blocked("https://stats.g.doubleclick.net/collect?v=1"));
        assert!(is_blocked("https://user@ad.doubleclick.net:443/"));
        assert!(!is_blocked("https://example.com/doubleclick.net"));
        assert!(!is_blocked("https://notdoubleclick.net/"));
        assert!(!is_blocked("about:blank"));
    }
}
