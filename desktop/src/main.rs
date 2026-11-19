//! oxygen: a Zen-style browser (vertical tabs, workspaces, Essentials, split
//! view, compact mode, Glance) built on the system webview (WebView2 on
//! Windows) and designed to stay under a fixed memory budget.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod blocker;
mod extensions;
mod keys;
mod memory;
mod platform;
mod search;
mod session;

use serde_json::{json, Value};
use session::{HistoryEntry, SavedTab, Session, Settings, Workspace};
use std::collections::HashMap;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tao::{
    dpi::LogicalSize,
    event::{Event, StartCause, WindowEvent},
    event_loop::{ControlFlow, EventLoopBuilder, EventLoopProxy},
    window::{Fullscreen, Icon, Window, WindowBuilder},
};
use wry::{http::Request, NewWindowResponse, Rect, WebContext, WebView, WebViewBuilder};

const UI_HTML: &str = include_str!("ui.html");
const CONTENT_JS: &str = include_str!("content.js");
const GLANCE_JS: &str = include_str!("glance.js");
const JETBRAINS_MONO: &[u8] = include_bytes!("../assets/fonts/JetBrainsMono-latin.woff2");

/// Gap between the page card and the window edges, like Zen's element separation.
const MARGIN: f64 = 8.0;
/// Width of the collapsed sidebar (icons only).
const RAIL_W: f64 = 52.0;
const SPLIT_GAP: f64 = 8.0;
const CORNER_RADIUS: f64 = 8.0;
const ANIM: Duration = Duration::from_millis(200);
const FRAME_INTERVAL: Duration = Duration::from_millis(8);
const TICK: Duration = Duration::from_secs(3);
const MAX_CLOSED: usize = 25;
const MAX_HISTORY: usize = 1500;

enum Ev {
    Chrome(String),
    Content(u64, String),
    Glance(String),
    Title(u64, String),
    Url(u64, String),
    /// A link asked for a new tab: (url, switch to it).
    NewTab(String, bool),
    Tick,
    /// (id, name, enabled) of every installed extension.
    Extensions(Vec<(String, String, bool)>),
    /// An extension folder finished loading (or failed).
    ExtensionAdded(std::path::PathBuf, Result<String, String>),
    /// A Web Store download finished (or failed).
    ExtensionDownloaded(Result<std::path::PathBuf, String>),
    /// An extension was switched on/off or removed.
    ExtensionsChanged,
    /// Live search suggestions for a query.
    Suggestions(String, Vec<String>),
    /// A page entered or left HTML full screen (e.g. a video).
    PageFullscreen(u64, bool),
    /// Browsing data finished clearing.
    Cleared(&'static str),
}

struct Tab {
    id: u64,
    url: String,
    title: String,
    workspace: u32,
    pinned: bool,
    essential: bool,
    /// Pinned tabs and Essentials remember the page they were pinned on, so
    /// you can always get back to it (as in Zen).
    pinned_url: Option<String>,
    /// `None` means the tab is unloaded: it costs no memory until selected.
    view: Option<WebView>,
    shown: bool,
    last_active: Instant,
}

impl Tab {
    fn saved(&self) -> SavedTab {
        SavedTab {
            id: self.id,
            url: self.url.clone(),
            title: self.title.clone(),
            workspace: self.workspace,
            pinned: self.pinned,
            essential: self.essential,
            pinned_url: self.pinned_url.clone(),
        }
    }

    /// Keeps the pinned page in step with the tab's pinned/Essential state.
    fn sync_pin(&mut self) {
        if self.pinned || self.essential {
            if self.pinned_url.is_none() {
                self.pinned_url = Some(self.url.clone());
            }
        } else {
            self.pinned_url = None;
        }
    }
}

/// Animates the sidebar width and the page's left edge together.
struct Anim {
    from: (f64, f64),
    to: (f64, f64),
    start: Instant,
}

/// Options every webview must share: they all live in one WebView2
/// environment (one browser process), so these are fixed at startup.
struct EnvConfig {
    #[cfg_attr(not(windows), allow(dead_code))]
    browser_args: String,
}

struct App {
    window: Window,
    proxy: EventLoopProxy<Ev>,
    ctx: WebContext,
    env: EnvConfig,
    chrome: WebView,
    chrome_ready: bool,
    tabs: Vec<Tab>,
    workspaces: Vec<Workspace>,
    active_ws: u32,
    active_tab: HashMap<u32, u64>,
    split: Option<(u64, u64)>,
    peek: bool,
    glance: Option<WebView>,
    closed: Vec<SavedTab>,
    settings: Settings,
    force_dark_at_start: bool,
    next_id: u64,
    meter: memory::Meter,
    mem_mb: u64,
    dirty: bool,
    history: Vec<HistoryEntry>,
    history_dirty: bool,
    /// Current (sidebar width, page left edge).
    cur: (f64, f64),
    anim: Option<Anim>,
    exit: bool,
    extensions: Vec<extensions::Extension>,
    /// WebView2 extension id -> unpacked folder.
    extension_folders: HashMap<String, std::path::PathBuf>,
    extension_status: String,
    extension_popup: Option<(String, WebView)>,
    searches: Vec<search::SearchEntry>,
    searches_dirty: bool,
    /// The tab showing a full-screen video, and whether the window was
    /// already full screen before it.
    page_fullscreen: Option<(u64, bool)>,
    privacy_status: String,
}

fn rect(x: f64, y: f64, w: f64, h: f64) -> Rect {
    Rect {
        position: wry::dpi::LogicalPosition::new(x, y).into(),
        size: wry::dpi::LogicalSize::new(w.max(0.0), h.max(0.0)).into(),
    }
}

fn now_secs() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn ease_out_cubic(t: f64) -> f64 {
    1.0 - (1.0 - t).powi(3)
}

fn base64(bytes: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for c in bytes.chunks(3) {
        let n = (c[0] as u32) << 16 | (*c.get(1).unwrap_or(&0) as u32) << 8 | *c.get(2).unwrap_or(&0) as u32;
        out.push(T[(n >> 18) as usize & 63] as char);
        out.push(T[(n >> 12) as usize & 63] as char);
        out.push(if c.len() > 1 { T[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if c.len() > 2 { T[n as usize & 63] as char } else { '=' });
    }
    out
}

/// @font-face rule with the bundled JetBrains Mono inlined (built once).
fn jetbrains_face() -> &'static str {
    static FACE: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    FACE.get_or_init(|| {
        format!(
            "@font-face{{font-family:'JetBrains Mono';src:url(data:font/woff2;base64,{}) format('woff2');font-weight:100 800;font-display:block}}",
            base64(JETBRAINS_MONO)
        )
    })
}

/// The sidebar page, with the bundled JetBrains Mono font inlined.
fn ui_html() -> String {
    UI_HTML.replace("/*OXYGEN_FONT_FACE*/", jetbrains_face())
}

/// Tells pages to use the interface font ("Use this font on websites").
fn site_font_script(s: &Settings) -> String {
    if !s.font_on_sites {
        return "window.__OXYGEN_SITE_FONT=null;".into();
    }
    let family = match s.font.as_str() {
        "jetbrains" => "'JetBrains Mono', ui-monospace, monospace",
        "segoe" => "'Segoe UI', sans-serif",
        "cascadia" => "'Cascadia Code', 'Cascadia Mono', monospace",
        "consolas" => "Consolas, monospace",
        "georgia" => "Georgia, serif",
        "verdana" => "Verdana, sans-serif",
        _ => "'Segoe UI Variable Text', 'Segoe UI', system-ui, sans-serif",
    };
    let face = if s.font == "jetbrains" { jetbrains_face() } else { "" };
    format!("window.__OXYGEN_SITE_FONT={};", json!({ "family": family, "face": face }))
}

/// Everything a page needs from the browser before its own scripts run.
fn page_setup_script(s: &Settings) -> String {
    format!("{}
{}", keys::page_script(s), site_font_script(s))
}

/// Parses `rgb(r, g, b)` / `rgba(r, g, b, a)` as produced by getComputedStyle.
fn parse_rgb(s: &str) -> Option<(u8, u8, u8)> {
    let inner = s.split_once('(')?.1.trim_end_matches(')');
    let mut parts = inner.split(',').map(|p| p.trim().parse::<f64>().ok());
    let r = parts.next()??;
    let g = parts.next()??;
    let b = parts.next()??;
    Some((r.round() as u8, g.round() as u8, b.round() as u8))
}

/// Applies the options every webview must share.
fn platform_builder<'a>(b: WebViewBuilder<'a>, _env: &EnvConfig, _theme: &str) -> WebViewBuilder<'a> {
    #[cfg(windows)]
    {
        use wry::WebViewBuilderExtWindows;
        // Extensions are loaded once at startup (see load_extensions), not per tab.
        b.with_additional_browser_args(&_env.browser_args)
            .with_browser_extensions_enabled(true)
            .with_scroll_bar_style(wry::ScrollBarStyle::FluentOverlay)
            .with_devtools(true)
            .with_theme(wry_theme(_theme))
    }
    #[cfg(not(windows))]
    {
        b
    }
}

#[cfg(windows)]
fn wry_theme(theme: &str) -> wry::Theme {
    match theme {
        "dark" => wry::Theme::Dark,
        "light" => wry::Theme::Light,
        _ => wry::Theme::Auto,
    }
}

fn apply_theme(_view: &WebView, _theme: &str) {
    #[cfg(windows)]
    {
        use wry::WebViewExtWindows;
        let _ = _view.set_theme(wry_theme(_theme));
    }
}

/// Tells WebView2 a tab is in the background so it can trim its memory.
fn set_memory_level(_view: &WebView, _low: bool) {
    #[cfg(windows)]
    {
        use wry::{MemoryUsageLevel, WebViewExtWindows};
        let level = if _low { MemoryUsageLevel::Low } else { MemoryUsageLevel::Normal };
        let _ = _view.set_memory_usage_level(level);
    }
}

#[allow(clippy::too_many_arguments)]
fn build_content(
    window: &Window,
    ctx: &mut WebContext,
    env: &EnvConfig,
    settings: &Settings,
    proxy: &EventLoopProxy<Ev>,
    id: u64,
    url: &str,
    bounds: Rect,
) -> Option<WebView> {
    let (p1, p2, p3, p4, p5) = (proxy.clone(), proxy.clone(), proxy.clone(), proxy.clone(), proxy.clone());
    let setup = page_setup_script(settings);
    let builder = WebViewBuilder::new_with_web_context(ctx)
        .with_bounds(bounds)
        .with_initialization_script_for_main_only(format!("{setup}
{CONTENT_JS}"), true)
        .with_ipc_handler(move |r: Request<String>| {
            let _ = p1.send_event(Ev::Content(id, r.into_body()));
        })
        .with_document_title_changed_handler(move |t| {
            let _ = p2.send_event(Ev::Title(id, t));
        })
        .with_on_page_load_handler(move |_, u| {
            let _ = p3.send_event(Ev::Url(id, u));
        })
        .with_new_window_req_handler(move |u, features| {
            // Pop-ups that ask for a size (sign-in windows like "Sign in with
            // Google") open as real pop-ups so they can report back to the page.
            // Other new-window links open as a tab you are switched to.
            if features.size.is_some() {
                return NewWindowResponse::Allow;
            }
            let _ = p4.send_event(Ev::NewTab(u, true));
            NewWindowResponse::Deny
        });
    let view = match platform_builder(builder, env, &settings.theme).build_as_child(window) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("failed to create tab webview: {e}");
            return None;
        }
    };
    // Install the blocker before the first request goes out.
    if settings.block_ads {
        blocker::install(&view);
    }
    platform::set_autofill(&view, settings.save_passwords);
    platform::on_page_fullscreen(&view, move |on| {
        let _ = p5.send_event(Ev::PageFullscreen(id, on));
    });
    let _ = view.load_url(url);
    Some(view)
}

fn percent_encode(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => out.push(b as char),
            b' ' => out.push('+'),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

const SCHEMES: [&str; 6] = ["http://", "https://", "file://", "about:", "edge://", "data:"];

fn is_local(lower: &str) -> bool {
    lower.starts_with("localhost") || lower.starts_with("127.0.0.1")
}

fn looks_like_host(s: &str) -> bool {
    !s.contains(char::is_whitespace) && (s.contains('.') || is_local(&s.to_ascii_lowercase())) && !s.starts_with('.') && !s.ends_with('.')
}

/// Whether address-bar input is a search rather than an address.
fn is_search_input(input: &str) -> bool {
    let s = input.trim();
    let lower = s.to_ascii_lowercase();
    !s.is_empty() && !SCHEMES.iter().any(|p| lower.starts_with(p)) && !looks_like_host(s)
}

/// Turns address-bar input into a URL: either the address itself or a search.
fn normalize_input(input: &str, engine: &str) -> String {
    let s = input.trim();
    let lower = s.to_ascii_lowercase();
    if SCHEMES.iter().any(|p| lower.starts_with(p)) {
        return s.to_string();
    }
    if looks_like_host(s) {
        return format!("{}{s}", if is_local(&lower) { "http://" } else { "https://" });
    }
    let base = match engine {
        "google" => "https://www.google.com/search?q=",
        "bing" => "https://www.bing.com/search?q=",
        "brave" => "https://search.brave.com/search?q=",
        "startpage" => "https://www.startpage.com/do/search?q=",
        _ => "https://duckduckgo.com/?q=",
    };
    format!("{base}{}", percent_encode(s))
}

fn title_from_url(url: &str) -> String {
    url.split_once("://")
        .map(|(_, r)| r.split('/').next().unwrap_or(r))
        .unwrap_or(url)
        .trim_start_matches("www.")
        .to_string()
}

impl App {
    fn new(window: Window, proxy: EventLoopProxy<Ev>, s: Session) -> Self {
        let data = session::data_dir();
        let _ = std::fs::create_dir_all(data.join("extensions"));
        let mut ctx = WebContext::new(Some(data.join("webview")));
        let mut browser_args =
            String::from("--disable-features=msWebOOUI,msPdfOOUI,msSmartScreenProtection --renderer-process-limit=4");
        if s.settings.force_dark {
            browser_args.push_str(" --enable-features=WebContentsForceDark");
        }
        let env = EnvConfig { browser_args };
        let p = proxy.clone();
        let builder = WebViewBuilder::new_with_web_context(&mut ctx)
            .with_html(ui_html())
            .with_bounds(rect(0.0, 0.0, 0.0, 0.0))
            .with_ipc_handler(move |r: Request<String>| {
                let _ = p.send_event(Ev::Chrome(r.into_body()));
            });
        let chrome = platform_builder(builder, &env, &s.settings.theme)
            .build_as_child(&window)
            .expect("could not start the webview (on Windows, install the WebView2 Runtime)");
        let now = Instant::now();
        let tabs = s
            .tabs
            .into_iter()
            .map(|t| Tab {
                id: t.id,
                url: t.url,
                title: t.title,
                workspace: t.workspace,
                pinned: t.pinned,
                essential: t.essential,
                pinned_url: t.pinned_url,
                view: None,
                shown: false,
                last_active: now,
            })
            .map(|mut t: Tab| {
                t.sync_pin();
                t
            })
            .collect();
        let force_dark_at_start = s.settings.force_dark;
        let mut app = App {
            window,
            proxy,
            ctx,
            env,
            chrome,
            chrome_ready: false,
            tabs,
            workspaces: s.workspaces,
            active_ws: s.active_workspace,
            active_tab: s.active_tabs.into_iter().collect(),
            split: s.split,
            peek: false,
            glance: None,
            closed: Vec::new(),
            settings: s.settings,
            force_dark_at_start,
            next_id: s.next_id,
            meter: memory::Meter::new(),
            mem_mb: 0,
            dirty: false,
            history: session::load_history(),
            history_dirty: false,
            cur: (0.0, 0.0),
            anim: None,
            exit: false,
            extensions: Vec::new(),
            extension_folders: HashMap::new(),
            extension_status: String::new(),
            extension_popup: None,
            searches: session::load_searches(),
            searches_dirty: false,
            page_fullscreen: None,
            privacy_status: String::new(),
        };
        app.cur = app.targets();
        // Only the visible tab is loaded at startup; the rest restore lazily.
        app.layout();
        app.update_title();
        app
    }

    fn idx(&self, id: u64) -> Option<usize> {
        self.tabs.iter().position(|t| t.id == id)
    }

    fn active(&self) -> Option<u64> {
        self.active_tab
            .get(&self.active_ws)
            .copied()
            .filter(|id| self.idx(*id).is_some())
    }

    /// Tabs in sidebar order for a workspace: Essentials, pinned, then the rest.
    fn ws_tab_ids(&self, ws: u32) -> Vec<u64> {
        let ess = self.tabs.iter().filter(|t| t.essential);
        let pinned = self.tabs.iter().filter(|t| !t.essential && t.pinned && t.workspace == ws);
        let rest = self.tabs.iter().filter(|t| !t.essential && !t.pinned && t.workspace == ws);
        ess.chain(pinned).chain(rest).map(|t| t.id).collect()
    }

    fn visible_ids(&self) -> Vec<u64> {
        let Some(a) = self.active() else { return vec![] };
        if let Some((l, r)) = self.split {
            if (a == l || a == r) && self.idx(l).is_some() && self.idx(r).is_some() {
                return vec![l, r];
            }
        }
        vec![a]
    }

    fn mode(&self) -> &'static str {
        if self.peek {
            "peek"
        } else if self.settings.compact {
            "hidden"
        } else if self.settings.collapsed {
            "rail"
        } else {
            "expanded"
        }
    }

    /// Target (sidebar width, page left edge) for the current mode.
    fn targets(&self) -> (f64, f64) {
        let sw = self.settings.sidebar_width;
        let resting = if self.settings.compact {
            MARGIN
        } else if self.settings.collapsed {
            RAIL_W
        } else {
            sw
        };
        if self.peek {
            // The floating sidebar overlaps the page where the platform allows it.
            (sw, if platform::CAN_OVERLAY { resting } else { sw })
        } else if self.settings.compact {
            (0.0, MARGIN)
        } else {
            (resting, resting)
        }
    }

    /// Moves the sidebar and page to the current mode, animated or not.
    fn retarget(&mut self, animate: bool) {
        let to = self.targets();
        if self.peek {
            platform::raise(&self.chrome);
        }
        if animate && to != self.cur {
            self.anim = Some(Anim { from: self.cur, to, start: Instant::now() });
        } else {
            self.anim = None;
            self.cur = to;
        }
        self.layout();
    }

    /// Advances the sidebar animation. Returns true while it is still running.
    fn step_anim(&mut self) -> bool {
        let Some(a) = &self.anim else { return false };
        let t = (a.start.elapsed().as_secs_f64() / ANIM.as_secs_f64()).min(1.0);
        let e = ease_out_cubic(t);
        self.cur = (a.from.0 + (a.to.0 - a.from.0) * e, a.from.1 + (a.to.1 - a.from.1) * e);
        if t >= 1.0 {
            self.cur = a.to;
            self.anim = None;
        }
        self.layout();
        self.anim.is_some()
    }

    fn window_size(&self) -> (f64, f64) {
        let size = self.window.inner_size().to_logical::<f64>(self.window.scale_factor());
        (size.width, size.height)
    }

    /// (x, y, width, height) of the page card.
    fn content_area(&self) -> (f64, f64, f64, f64) {
        let (w, h) = self.window_size();
        let x = self.cur.1;
        (x, MARGIN, (w - x - MARGIN).max(0.0), (h - 2.0 * MARGIN).max(0.0))
    }

    fn glance_rect(&self) -> (f64, f64, f64, f64) {
        let (x, y, w, h) = self.content_area();
        (x + w * 0.06, y + h * 0.05, w * 0.88, h * 0.9)
    }

    /// Positions every webview, loading visible tabs and hiding the rest.
    fn layout(&mut self) {
        // A full-screen video fills the whole window, with no sidebar or margins.
        if let Some((id, _)) = self.page_fullscreen {
            let (ww, wh) = self.window_size();
            if let Some(v) = self.idx(id).and_then(|i| self.tabs[i].view.as_ref()) {
                let _ = self.chrome.set_visible(false);
                let _ = v.set_bounds(rect(0.0, 0.0, ww, wh));
                platform::square_corners(v);
                platform::raise(v);
                return;
            }
            self.page_fullscreen = None;
        }
        let (_, wh) = self.window_size();
        let scale = self.window.scale_factor();
        let chrome_w = self.cur.0;
        let _ = self.chrome.set_bounds(rect(0.0, 0.0, chrome_w.max(1.0), wh));
        let _ = self.chrome.set_visible(chrome_w >= 1.0);
        let (x, y, w, h) = self.content_area();
        let vis = self.visible_ids();
        let slots: Vec<(f64, f64, f64, f64)> = if vis.len() == 2 {
            let half = (w - SPLIT_GAP) / 2.0;
            vec![(x, y, half, h), (x + half + SPLIT_GAP, y, half, h)]
        } else {
            vec![(x, y, w, h)]
        };
        let now = Instant::now();
        for (id, (sx, sy, sw, sh)) in vis.iter().zip(slots) {
            let Some(i) = self.idx(*id) else { continue };
            if self.tabs[i].view.is_none() {
                let url = self.tabs[i].url.clone();
                self.tabs[i].view = build_content(
                    &self.window,
                    &mut self.ctx,
                    &self.env,
                    &self.settings,
                    &self.proxy,
                    *id,
                    &url,
                    rect(sx, sy, sw, sh),
                );
                self.tabs[i].shown = false;
                // A new page would cover the floating sidebar.
                if self.peek {
                    platform::raise(&self.chrome);
                }
            }
            let t = &mut self.tabs[i];
            t.last_active = now;
            if let Some(v) = &t.view {
                let _ = v.set_bounds(rect(sx, sy, sw, sh));
                platform::round_corners(v, sw, sh, scale, CORNER_RADIUS);
                if !t.shown {
                    let _ = v.set_visible(true);
                    set_memory_level(v, false);
                    t.shown = true;
                }
            }
        }
        for t in self.tabs.iter_mut().filter(|t| t.shown && !vis.contains(&t.id)) {
            if let Some(v) = &t.view {
                let _ = v.set_visible(false);
                set_memory_level(v, true);
            }
            t.shown = false;
            t.last_active = now; // the idle timer starts when the tab is hidden
        }
        if let Some((_, p)) = &self.extension_popup {
            let (px, py, pw, ph) = self.extension_popup_rect();
            let _ = p.set_bounds(rect(px, py, pw, ph));
            platform::round_corners(p, pw, ph, scale, 10.0);
        }
        if let Some(g) = &self.glance {
            let (gx, gy, gw, gh) = self.glance_rect();
            let _ = g.set_bounds(rect(gx, gy, gw, gh));
            platform::round_corners(g, gw, gh, scale, 12.0);
        }
    }

    /// Keeps the browser within its tab cap and memory budget by unloading the
    /// least recently used background tabs.
    fn enforce_limits(&mut self) {
        let vis = self.visible_ids();
        let now = Instant::now();
        let idle = Duration::from_secs(self.settings.unload_after_mins * 60);
        let mut changed = false;
        for t in self.tabs.iter_mut() {
            if t.view.is_some() && !vis.contains(&t.id) && now.duration_since(t.last_active) > idle {
                t.view = None;
                changed = true;
            }
        }
        let mut bg: Vec<(Instant, u64)> = self
            .tabs
            .iter()
            .filter(|t| t.view.is_some() && !vis.contains(&t.id))
            .map(|t| (t.last_active, t.id))
            .collect();
        bg.sort();
        let allowed = self.settings.max_loaded_tabs.saturating_sub(vis.len());
        let mut drop = bg.len().saturating_sub(allowed);
        let budget = self.settings.memory_budget_mb;
        if self.mem_mb > budget {
            // Over budget: shed more tabs the further over we are. Memory is
            // measured again next tick, so this converges quickly.
            drop = drop.max(1 + ((self.mem_mb - budget) / 200) as usize);
        }
        for (_, id) in bg.into_iter().take(drop) {
            if let Some(i) = self.idx(id) {
                self.tabs[i].view = None;
                changed = true;
            }
        }
        if changed {
            self.render();
        }
    }

    fn render(&mut self) {
        self.dirty = true;
        self.update_title();
        if !self.chrome_ready {
            return;
        }
        let active = self.active();
        let tj = |t: &Tab| {
            json!({
                "id": t.id, "url": t.url, "title": t.title, "loaded": t.view.is_some(),
                "active": Some(t.id) == active, "essential": t.essential, "pinned": t.pinned,
                "pinnedUrl": t.pinned_url, "away": t.pinned_url.as_ref().is_some_and(|p| *p != t.url),
            })
        };
        let ws = self.active_ws;
        let essentials: Vec<Value> = self.tabs.iter().filter(|t| t.essential).map(tj).collect();
        let pinned: Vec<Value> = self
            .tabs
            .iter()
            .filter(|t| !t.essential && t.pinned && t.workspace == ws)
            .map(tj)
            .collect();
        let tabs: Vec<Value> = self
            .tabs
            .iter()
            .filter(|t| !t.essential && !t.pinned && t.workspace == ws)
            .map(tj)
            .collect();
        let active_url = active
            .and_then(|id| self.idx(id))
            .map(|i| self.tabs[i].url.clone())
            .unwrap_or_default();
        let state = json!({
            "workspaces": self.workspaces, "activeWs": ws, "essentials": essentials,
            "pinned": pinned, "tabs": tabs, "activeId": active, "activeUrl": active_url,
            "split": self.split.map(|(a, b)| [a, b]), "mode": self.mode(),
            "settings": self.settings, "mem": self.mem_mb,
            "restartNeeded": self.settings.force_dark != self.force_dark_at_start,
            "keyActions": keys::actions(&self.settings),
            "extSupported": cfg!(windows),
            "extensions": self.extensions,
            "extStatus": self.extension_status,
            "extPopup": self.extension_popup.as_ref().map(|(id, _)| id.clone()),
            "privacyStatus": self.privacy_status,
            "storeId": extensions::store_id_from_url(&active_url),
            "storeInstalled": extensions::store_id_from_url(&active_url).is_some_and(|sid| self.extension_folders.values().any(|d| extensions::folder_name(d) == sid)),
        });
        let _ = self.chrome.evaluate_script(&format!("window.zl&&zl.render({state})"));
    }

    fn update_title(&self) {
        let title = self
            .active()
            .and_then(|id| self.idx(id))
            .map(|i| self.tabs[i].title.as_str())
            .filter(|t| !t.is_empty());
        self.window.set_title(&match title {
            Some(t) => format!("{t} — oxygen"),
            None => "oxygen".into(),
        });
    }

    fn save(&mut self) {
        session::save(&Session {
            workspaces: self.workspaces.clone(),
            tabs: self.tabs.iter().map(Tab::saved).collect(),
            active_workspace: self.active_ws,
            active_tabs: self.active_tab.iter().map(|(w, t)| (*w, *t)).collect(),
            split: self.split,
            settings: self.settings.clone(),
            next_id: self.next_id,
        });
        if self.history_dirty {
            session::save_history(&self.history);
            self.history_dirty = false;
        }
        if self.searches_dirty {
            session::save_searches(&self.searches);
            self.searches_dirty = false;
        }
    }

    fn record_visit(&mut self, url: &str, title: &str) {
        if !(url.starts_with("http://") || url.starts_with("https://")) {
            return;
        }
        let now = now_secs();
        match self.history.iter_mut().find(|h| h.url == url) {
            Some(h) => {
                h.visits += 1;
                h.last = now;
                if !title.is_empty() {
                    h.title = title.to_string();
                }
            }
            None => self.history.push(HistoryEntry { url: url.into(), title: title.into(), visits: 1, last: now }),
        }
        if self.history.len() > MAX_HISTORY {
            self.sort_history();
            self.history.truncate(MAX_HISTORY * 2 / 3);
        }
        self.history_dirty = true;
    }

    /// Most useful first: visited often and recently.
    fn sort_history(&mut self) {
        let now = now_secs();
        let score = |h: &HistoryEntry| {
            let days = now.saturating_sub(h.last) as f64 / 86_400.0;
            (h.visits as f64).sqrt() / (1.0 + days * 0.25)
        };
        self.history.sort_by(|a, b| score(b).partial_cmp(&score(a)).unwrap_or(std::cmp::Ordering::Equal));
    }

    fn send_history(&mut self) {
        self.sort_history();
        let list: Vec<Value> = self
            .history
            .iter()
            .take(300)
            .map(|h| json!({ "url": h.url, "title": h.title }))
            .collect();
        let searches: Vec<&str> = self.searches.iter().take(100).map(|s| s.query.as_str()).collect();
        let _ = self
            .chrome
            .evaluate_script(&format!("window.zl&&zl.history({},{})", Value::Array(list), json!(searches)));
    }

    fn active_view(&self) -> Option<&WebView> {
        self.active().and_then(|id| self.idx(id)).and_then(|i| self.tabs[i].view.as_ref())
    }

    fn open_tab(&mut self, url: String, foreground: bool) -> u64 {
        let id = self.next_id;
        self.next_id += 1;
        let title = title_from_url(&url);
        self.tabs.push(Tab {
            id,
            url,
            title,
            workspace: self.active_ws,
            pinned: false,
            essential: false,
            pinned_url: None,
            view: None, // background tabs stay unloaded until you look at them
            shown: false,
            last_active: Instant::now(),
        });
        if foreground {
            self.select(id);
        } else {
            self.render();
        }
        id
    }

    fn select(&mut self, id: u64) {
        let Some(i) = self.idx(id) else { return };
        let ws = if self.tabs[i].essential { self.active_ws } else { self.tabs[i].workspace };
        self.active_ws = ws;
        self.active_tab.insert(ws, id);
        self.glance = None;
        self.extension_popup = None;
        if self.peek {
            self.peek = false;
            self.retarget(true);
        } else {
            self.layout();
        }
        self.enforce_limits();
        self.render();
        if let Some(v) = self.active_view() {
            let _ = v.focus();
        }
    }

    fn close(&mut self, id: u64) {
        let Some(i) = self.idx(id) else { return };
        // Pick the neighbour to activate in every workspace where this tab was active.
        let affected: Vec<u32> = self
            .active_tab
            .iter()
            .filter(|(_, t)| **t == id)
            .map(|(w, _)| *w)
            .collect();
        let mut replacements = Vec::new();
        for ws in affected {
            let list = self.ws_tab_ids(ws);
            let pos = list.iter().position(|t| *t == id).unwrap_or(0);
            let next = list.get(pos + 1).or_else(|| pos.checked_sub(1).and_then(|p| list.get(p)));
            replacements.push((ws, next.copied()));
        }
        let tab = self.tabs.remove(i);
        self.closed.push(tab.saved());
        if self.closed.len() > MAX_CLOSED {
            self.closed.remove(0);
        }
        for (ws, next) in replacements {
            match next {
                Some(n) => self.active_tab.insert(ws, n),
                None => self.active_tab.remove(&ws),
            };
        }
        if self.split.is_some_and(|(a, b)| a == id || b == id) {
            self.split = None;
        }
        self.layout();
        self.enforce_limits();
        self.render();
    }

    /// Closes every unpinned tab in the current workspace.
    fn clear_tabs(&mut self) {
        let ws = self.active_ws;
        let ids: Vec<u64> = self
            .tabs
            .iter()
            .filter(|t| !t.essential && !t.pinned && t.workspace == ws)
            .map(|t| t.id)
            .collect();
        for id in &ids {
            if let Some(i) = self.idx(*id) {
                let tab = self.tabs.remove(i);
                self.closed.push(tab.saved());
            }
        }
        let excess = self.closed.len().saturating_sub(MAX_CLOSED);
        self.closed.drain(..excess);
        if self.active().is_none() {
            match self.ws_tab_ids(ws).first().copied() {
                Some(first) => self.active_tab.insert(ws, first),
                None => self.active_tab.remove(&ws),
            };
        }
        if self.split.is_some_and(|(a, b)| self.idx(a).is_none() || self.idx(b).is_none()) {
            self.split = None;
        }
        self.layout();
        self.render();
    }

    fn reopen_closed(&mut self) {
        if let Some(t) = self.closed.pop() {
            let ws = if self.workspaces.iter().any(|w| w.id == t.workspace) { t.workspace } else { self.active_ws };
            self.active_ws = ws;
            let id = self.open_tab(t.url, false);
            if let Some(i) = self.idx(id) {
                self.tabs[i].title = t.title;
                self.tabs[i].pinned = t.pinned;
                self.tabs[i].essential = t.essential;
                self.tabs[i].pinned_url = t.pinned_url;
                self.tabs[i].sync_pin();
            }
            self.select(id);
        }
    }

    fn switch_ws(&mut self, id: u32) {
        if self.workspaces.iter().any(|w| w.id == id) {
            self.active_ws = id;
            self.glance = None;
            self.layout();
            self.enforce_limits();
            self.render();
        }
    }

    fn cycle_ws(&mut self, step: isize) {
        let n = self.workspaces.len() as isize;
        let pos = self.workspaces.iter().position(|w| w.id == self.active_ws).unwrap_or(0) as isize;
        let next = self.workspaces[((pos + step).rem_euclid(n)) as usize].id;
        self.switch_ws(next);
    }

    fn cycle_tab(&mut self, step: isize) {
        let list = self.ws_tab_ids(self.active_ws);
        if list.is_empty() {
            return;
        }
        let pos = self.active().and_then(|a| list.iter().position(|t| *t == a));
        let next = match pos {
            Some(p) => (p as isize + step).rem_euclid(list.len() as isize) as usize,
            None => 0,
        };
        self.select(list[next]);
    }

    fn set_peek(&mut self, on: bool) {
        if self.peek != on {
            self.peek = on;
            self.retarget(true);
            self.render();
        }
    }

    fn set_layout_mode(&mut self, compact: bool, collapsed: bool) {
        self.settings.compact = compact;
        self.settings.collapsed = collapsed;
        self.peek = false;
        self.retarget(true);
        self.render();
    }

    fn focus_address(&mut self, new_tab: bool) {
        // With the sidebar hidden or collapsed, slide it out to show the address bar.
        if self.settings.compact || self.settings.collapsed {
            self.set_peek(true);
        }
        let _ = self.chrome.focus();
        let _ = self.chrome.evaluate_script(&format!("window.zl&&zl.focusUrl({new_tab})"));
    }

    fn toggle_split(&mut self) {
        let Some(a) = self.active() else { return };
        if self.split.is_some_and(|(l, r)| l == a || r == a) {
            self.split = None;
        } else {
            let list = self.ws_tab_ids(self.active_ws);
            let pos = list.iter().position(|t| *t == a).unwrap_or(0);
            let other = list.get(pos + 1).or_else(|| pos.checked_sub(1).and_then(|p| list.get(p)));
            match other {
                Some(o) => self.split = Some((a, *o)),
                None => return,
            }
        }
        self.layout();
        self.enforce_limits();
        self.render();
    }

    fn open_glance(&mut self, url: String) {
        if let Some(g) = &self.glance {
            let _ = g.load_url(&url);
            return;
        }
        let (p1, p2) = (self.proxy.clone(), self.proxy.clone());
        let (gx, gy, gw, gh) = self.glance_rect();
        let builder = WebViewBuilder::new_with_web_context(&mut self.ctx)
            .with_bounds(rect(gx, gy, gw, gh))
            .with_initialization_script_for_main_only(GLANCE_JS, true)
            .with_ipc_handler(move |r: Request<String>| {
                let _ = p1.send_event(Ev::Glance(r.into_body()));
            })
            .with_new_window_req_handler(move |u, features| {
                if features.size.is_some() {
                    return NewWindowResponse::Allow;
                }
                let _ = p2.send_event(Ev::NewTab(u, true));
                NewWindowResponse::Deny
            });
        if let Ok(v) = platform_builder(builder, &self.env, &self.settings.theme).build_as_child(&self.window) {
            if self.settings.block_ads {
                blocker::install(&v);
            }
            platform::round_corners(&v, gw, gh, self.window.scale_factor(), 12.0);
            let _ = v.load_url(&url);
            let _ = v.focus();
            self.glance = Some(v);
        }
    }

    fn close_glance(&mut self) {
        if self.glance.take().is_some() {
            if let Some(v) = self.active_view() {
                let _ = v.focus();
            }
        }
    }

    // MARK: Extensions

    /// Loads every unpacked extension in the profile, once per start.
    fn load_extensions(&mut self) {
        for dir in extensions::installed_folders() {
            let proxy = self.proxy.clone();
            let d = dir.clone();
            extensions::add(&self.chrome, &dir, move |result| {
                let _ = proxy.send_event(Ev::ExtensionAdded(d, result));
            });
        }
        self.refresh_extensions();
    }

    fn refresh_extensions(&self) {
        let proxy = self.proxy.clone();
        extensions::list(&self.chrome, move |list| {
            let _ = proxy.send_event(Ev::Extensions(list));
        });
    }

    fn install_extension(&mut self, input: &str) {
        let Some(id) = extensions::parse_store_id(input) else {
            self.extension_status = "That isn't a Chrome Web Store link or extension ID.".into();
            self.render();
            return;
        };
        self.extension_status = "Installing…".into();
        self.render();
        let proxy = self.proxy.clone();
        std::thread::spawn(move || {
            let _ = proxy.send_event(Ev::ExtensionDownloaded(extensions::download_from_store(&id)));
        });
    }

    fn extension_by_id(&self, id: &str) -> Option<&extensions::Extension> {
        self.extensions.iter().find(|e| e.id == id)
    }

    fn set_extension_enabled(&mut self, id: String, on: bool) {
        if let Some(dir) = self.extension_folders.get(&id) {
            let name = extensions::folder_name(dir);
            let mut disabled = extensions::load_disabled();
            disabled.retain(|n| *n != name);
            if !on {
                disabled.push(name);
            }
            extensions::save_disabled(&disabled);
        }
        if !on && self.extension_popup.as_ref().is_some_and(|(p, _)| *p == id) {
            self.extension_popup = None;
        }
        let proxy = self.proxy.clone();
        extensions::set_enabled(&self.chrome, id, on, move || {
            let _ = proxy.send_event(Ev::ExtensionsChanged);
        });
    }

    fn remove_extension(&mut self, id: String) {
        if self.extension_popup.as_ref().is_some_and(|(p, _)| *p == id) {
            self.extension_popup = None;
        }
        // Delete the files too, or it would load again next start.
        if let Some(dir) = self.extension_folders.remove(&id) {
            let _ = std::fs::remove_dir_all(dir);
        }
        let proxy = self.proxy.clone();
        extensions::remove(&self.chrome, id, move || {
            let _ = proxy.send_event(Ev::ExtensionsChanged);
        });
    }

    fn extension_popup_rect(&self) -> (f64, f64, f64, f64) {
        let (wx, _, _, wh) = self.content_area();
        let h = (wh - 40.0).clamp(200.0, 580.0);
        (wx + 8.0, MARGIN + 44.0, 380.0, h)
    }

    /// Opens (or closes) an extension's popup page next to the sidebar.
    fn toggle_extension_popup(&mut self, id: String) {
        if self.extension_popup.as_ref().is_some_and(|(p, _)| *p == id) {
            self.extension_popup = None;
            return;
        }
        let Some(ext) = self.extension_by_id(&id) else { return };
        if ext.popup.is_empty() {
            self.extension_status = format!("{} has no popup. It works in the background.", ext.name);
            self.render();
            return;
        }
        let url = format!("chrome-extension://{}/{}", ext.id, ext.popup);
        let (x, y, w, h) = self.extension_popup_rect();
        let proxy = self.proxy.clone();
        let builder = WebViewBuilder::new_with_web_context(&mut self.ctx)
            .with_bounds(rect(x, y, w, h))
            .with_url(&url)
            .with_new_window_req_handler(move |u, features| {
                if features.size.is_some() {
                    return NewWindowResponse::Allow;
                }
                let _ = proxy.send_event(Ev::NewTab(u, true));
                NewWindowResponse::Deny
            });
        if let Ok(v) = platform_builder(builder, &self.env, &self.settings.theme).build_as_child(&self.window) {
            platform::round_corners(&v, w, h, self.window.scale_factor(), 10.0);
            let _ = v.focus();
            self.extension_popup = Some((id, v));
        }
    }

    fn restart(&mut self) {
        self.save();
        if let Ok(exe) = std::env::current_exe() {
            if std::process::Command::new(exe).arg("--restarted").spawn().is_ok() {
                self.exit = true;
            }
        }
    }

    /// A key combo from the sidebar or a page: fixed keys first, then the
    /// user's shortcuts (defaults in keybinds.json, changes in Settings).
    fn on_key(&mut self, k: &str) {
        match k {
            "escape" => {
                self.extension_popup = None;
                self.close_glance();
                self.set_peek(false);
            }
            "f5" => self.run_action("reload"),
            _ => {
                if let Some(action) = keys::action_for(&self.settings, k) {
                    self.run_action(&action);
                } else if let Some(n) = k.strip_prefix("ctrl+").and_then(|d| d.parse::<usize>().ok()) {
                    // Ctrl+1..8 jump to a tab, Ctrl+9 to the last one.
                    let list = self.ws_tab_ids(self.active_ws);
                    let target = if n == 9 { list.last() } else { list.get(n.wrapping_sub(1)) };
                    if let Some(id) = target.copied() {
                        self.select(id);
                    }
                }
            }
        }
    }

    fn run_action(&mut self, action: &str) {
        match action {
            "new_tab" => self.focus_address(true),
            "focus_address" => self.focus_address(false),
            "close_tab" => {
                if self.glance.is_some() {
                    self.close_glance();
                } else if let Some(a) = self.active() {
                    self.close(a);
                }
            }
            "reopen_tab" => self.reopen_closed(),
            "next_tab" => self.cycle_tab(1),
            "prev_tab" => self.cycle_tab(-1),
            "collapse_sidebar" => self.set_layout_mode(false, !(self.settings.collapsed && !self.settings.compact)),
            "compact_mode" => self.set_layout_mode(!self.settings.compact, self.settings.collapsed),
            "split_view" => self.toggle_split(),
            "prev_workspace" => self.cycle_ws(-1),
            "next_workspace" => self.cycle_ws(1),
            "add_essential" => {
                if let Some(a) = self.active() {
                    self.toggle_essential(a);
                }
            }
            "fullscreen" => {
                let fs = self.window.fullscreen().is_some();
                self.window.set_fullscreen(if fs { None } else { Some(Fullscreen::Borderless(None)) });
            }
            "reload" => {
                if let Some(v) = self.active_view() {
                    let _ = v.reload();
                }
            }
            "back" => {
                if let Some(v) = self.active_view() {
                    let _ = v.go_back();
                }
            }
            "forward" => {
                if let Some(v) = self.active_view() {
                    let _ = v.go_forward();
                }
            }
            _ => {}
        }
    }

    /// Re-sends shortcut and font settings to open pages.
    fn push_page_setup(&self) {
        let script = format!("{}
window.__oxygenApplyFont&&__oxygenApplyFont();", page_setup_script(&self.settings));
        for v in self.tabs.iter().filter_map(|t| t.view.as_ref()) {
            let _ = v.evaluate_script(&script);
        }
    }
    fn toggle_essential(&mut self, id: u64) {
        if let Some(i) = self.idx(id) {
            let t = &mut self.tabs[i];
            t.essential = !t.essential;
            t.pinned = false;
            if !t.essential {
                t.workspace = self.active_ws;
            }
            t.sync_pin();
            self.render();
        }
    }

    fn apply_settings(&mut self, new: Settings) {
        let old = std::mem::replace(&mut self.settings, new);
        if old.keybinds != self.settings.keybinds || old.font != self.settings.font || old.font_on_sites != self.settings.font_on_sites {
            self.push_page_setup();
        }
        if old.save_passwords != self.settings.save_passwords {
            for v in self.tabs.iter().filter_map(|t| t.view.as_ref()) {
                platform::set_autofill(v, self.settings.save_passwords);
            }
        }
        if old.theme != self.settings.theme {
            let theme = self.settings.theme.clone();
            for v in self.tabs.iter().filter_map(|t| t.view.as_ref()).chain(self.glance.as_ref()) {
                apply_theme(v, &theme);
            }
            apply_theme(&self.chrome, &theme);
        }
        if old.compact != self.settings.compact || old.collapsed != self.settings.collapsed {
            self.peek = false;
            self.retarget(true);
        }
        self.enforce_limits();
        self.render();
    }

    fn handle_chrome(&mut self, msg: &str) {
        let Ok(v) = serde_json::from_str::<Value>(msg) else { return };
        let id = v["id"].as_u64().unwrap_or(0);
        match v["t"].as_str().unwrap_or("") {
            "ready" => {
                self.chrome_ready = true;
                self.load_extensions();
                self.render();
                if self.tabs.is_empty() && !self.settings.compact && !self.settings.collapsed {
                    self.focus_address(true);
                }
            }
            "frame" => {
                if let Some((r, g, b)) = v["color"].as_str().and_then(parse_rgb) {
                    self.window.set_background_color(Some((r, g, b, 255)));
                    platform::style_title_bar(&self.window, (r, g, b), v["dark"].as_bool().unwrap_or(false));
                }
            }
            "history" => self.send_history(),
            "go" => {
                let input = v["input"].as_str().unwrap_or("").trim().to_string();
                let url = normalize_input(&input, &self.settings.search_engine);
                // Remember searches (not addresses) for the address bar.
                if is_search_input(&input) {
                    search::remember(&mut self.searches, &input, now_secs());
                    self.searches_dirty = true;
                }
                self.set_peek(false);
                let active = self.active();
                match active.filter(|_| !v["newTab"].as_bool().unwrap_or(false)) {
                    Some(a) => {
                        if let Some(i) = self.idx(a) {
                            self.tabs[i].url = url.clone();
                            if let Some(view) = &self.tabs[i].view {
                                let _ = view.load_url(&url);
                                let _ = view.focus();
                            }
                        }
                        self.layout();
                        self.render();
                    }
                    None => {
                        self.open_tab(url, true);
                    }
                }
            }
            "select" => self.select(id),
            "close" => self.close(id),
            "clear" => self.clear_tabs(),
            "back" => self.run_action("back"),
            "forward" => self.run_action("forward"),
            "reload" => self.run_action("reload"),
            "action" => {
                let a = v["id"].as_str().unwrap_or("").to_string();
                self.run_action(&a);
            }
            "collapse" => {
                if self.settings.compact {
                    self.set_layout_mode(false, true);
                } else {
                    self.set_layout_mode(false, !self.settings.collapsed);
                }
            }
            "reloadTab" => {
                if let Some(view) = self.idx(id).and_then(|i| self.tabs[i].view.as_ref()) {
                    let _ = view.reload();
                }
            }
            "pin" => {
                if let Some(i) = self.idx(id) {
                    self.tabs[i].pinned = !self.tabs[i].pinned;
                    self.tabs[i].sync_pin();
                    self.render();
                }
            }
            "resetPin" => {
                // Go back to the page the tab was pinned on.
                if let Some(i) = self.idx(id) {
                    if let Some(url) = self.tabs[i].pinned_url.clone() {
                        self.tabs[i].url = url.clone();
                        match &self.tabs[i].view {
                            Some(view) => {
                                let _ = view.load_url(&url);
                            }
                            None => self.select(id),
                        }
                        self.render();
                    }
                }
            }
            "setPinUrl" => {
                // Make the tab's current page its pinned page.
                if let Some(i) = self.idx(id) {
                    self.tabs[i].pinned_url = Some(self.tabs[i].url.clone());
                    self.render();
                }
            }
            "essential" => self.toggle_essential(id),
            "split" => {
                if let Some(a) = self.active().filter(|a| *a != id) {
                    self.split = Some((a, id));
                    self.layout();
                    self.enforce_limits();
                    self.render();
                }
            }
            "unsplit" => {
                self.split = None;
                self.layout();
                self.render();
            }
            "peek" => self.set_peek(v["on"].as_bool().unwrap_or(false)),
            "ws" => self.switch_ws(v["id"].as_u64().unwrap_or(0) as u32),
            "newWs" => {
                let new_id = self.workspaces.iter().map(|w| w.id).max().unwrap_or(0) + 1;
                self.workspaces.push(Workspace {
                    id: new_id,
                    name: v["name"].as_str().unwrap_or("Workspace").to_string(),
                    icon: v["icon"].as_str().unwrap_or("globe").to_string(),
                    color: v["color"].as_str().unwrap_or(session::DEFAULT_ACCENT).to_string(),
                });
                self.switch_ws(new_id);
            }
            "editWs" => {
                let ws_id = id as u32;
                if let Some(w) = self.workspaces.iter_mut().find(|w| w.id == ws_id) {
                    w.name = v["name"].as_str().unwrap_or(&w.name).to_string();
                    w.icon = v["icon"].as_str().unwrap_or(&w.icon).to_string();
                    w.color = v["color"].as_str().unwrap_or(&w.color).to_string();
                }
                self.render();
            }
            "deleteWs" => {
                let ws_id = id as u32;
                if self.workspaces.len() > 1 {
                    self.tabs.retain(|t| t.essential || t.workspace != ws_id);
                    self.workspaces.retain(|w| w.id != ws_id);
                    self.active_tab.remove(&ws_id);
                    if self.split.is_some_and(|(a, b)| self.idx(a).is_none() || self.idx(b).is_none()) {
                        self.split = None;
                    }
                    if self.active_ws == ws_id {
                        self.active_ws = self.workspaces[0].id;
                    }
                    self.layout();
                    self.render();
                }
            }
            "move" => {
                let before = v["before"].as_u64();
                if before == Some(id) {
                    return;
                }
                let Some(i) = self.idx(id) else { return };
                let mut t = self.tabs.remove(i);
                match v["section"].as_str().unwrap_or("tabs") {
                    "essentials" => {
                        t.essential = true;
                        t.pinned = false;
                    }
                    section => {
                        t.essential = false;
                        t.pinned = section == "pinned";
                        t.workspace = self.active_ws;
                    }
                }
                t.sync_pin();
                let pos = before.and_then(|b| self.idx(b)).unwrap_or(self.tabs.len());
                self.tabs.insert(pos, t);
                self.render();
            }
            "moveWs" => {
                let target = v["ws"].as_u64().unwrap_or(0) as u32;
                if self.workspaces.iter().any(|w| w.id == target) {
                    if self.active() == Some(id) {
                        let list = self.ws_tab_ids(self.active_ws);
                        let pos = list.iter().position(|t| *t == id).unwrap_or(0);
                        let next = list.get(pos + 1).or_else(|| pos.checked_sub(1).and_then(|p| list.get(p)));
                        match next.copied() {
                            Some(n) => self.active_tab.insert(self.active_ws, n),
                            None => self.active_tab.remove(&self.active_ws),
                        };
                    }
                    if let Some(i) = self.idx(id) {
                        self.tabs[i].workspace = target;
                        self.tabs[i].pinned = false;
                    }
                    if self.split.is_some_and(|(a, b)| a == id || b == id) {
                        self.split = None;
                    }
                    self.layout();
                    self.render();
                }
            }
            "unload" => {
                if !self.visible_ids().contains(&id) {
                    if let Some(i) = self.idx(id) {
                        self.tabs[i].view = None;
                        self.render();
                    }
                }
            }
            "duplicate" => {
                if let Some(i) = self.idx(id) {
                    let url = self.tabs[i].url.clone();
                    self.open_tab(url, false);
                }
            }
            "settings" => {
                if let Ok(new) = serde_json::from_value::<Settings>(v["settings"].clone()) {
                    self.apply_settings(new);
                }
            }
            "restart" => self.restart(),
            "suggest" => {
                let q = v["q"].as_str().unwrap_or("").to_string();
                if self.settings.search_suggestions && !q.trim().is_empty() {
                    let engine = self.settings.search_engine.clone();
                    let proxy = self.proxy.clone();
                    std::thread::spawn(move || {
                        let list = search::fetch_suggestions(&engine, &q);
                        let _ = proxy.send_event(Ev::Suggestions(q, list));
                    });
                }
            }
            "clearData" => {
                let kind = v["kind"].as_str().unwrap_or("");
                let proxy = self.proxy.clone();
                match kind {
                    "history" => {
                        self.history.clear();
                        self.history_dirty = true;
                        platform::clear_browsing_data(&self.chrome, platform::ClearKind::History, move || {
                            let _ = proxy.send_event(Ev::Cleared("History cleared."));
                        });
                    }
                    "searches" => {
                        self.searches.clear();
                        self.searches_dirty = true;
                        self.privacy_status = "Search history cleared.".into();
                        self.render();
                    }
                    "cache" => platform::clear_browsing_data(&self.chrome, platform::ClearKind::Cache, move || {
                        let _ = proxy.send_event(Ev::Cleared("Cache cleared."));
                    }),
                    "cookies" => platform::clear_browsing_data(&self.chrome, platform::ClearKind::CookiesAndSiteData, move || {
                        let _ = proxy.send_event(Ev::Cleared("Cookies and site data cleared. You may need to sign in to sites again."));
                    }),
                    _ => {}
                }
            }
            "extInstall" => {
                let input = v["input"].as_str().unwrap_or("").to_string();
                self.install_extension(&input);
            }
            "extToggle" => {
                if let Some(ext) = v["ext"].as_str() {
                    self.set_extension_enabled(ext.to_string(), v["on"].as_bool().unwrap_or(true));
                }
            }
            "extRemove" => {
                if let Some(ext) = v["ext"].as_str() {
                    self.remove_extension(ext.to_string());
                }
            }
            "extPopup" => {
                if let Some(ext) = v["ext"].as_str() {
                    self.toggle_extension_popup(ext.to_string());
                    self.render();
                }
            }
            "extFolder" => {
                let dir = extensions::folder();
                let _ = std::fs::create_dir_all(&dir);
                let _ = std::process::Command::new("explorer").arg(dir).spawn();
            }
            "key" => {
                let k = v["k"].as_str().unwrap_or("").to_string();
                self.on_key(&k);
            }
            _ => {}
        }
    }

    fn set_tab_url(&mut self, id: u64, url: &str) {
        let Some(i) = self.idx(id) else { return };
        if self.tabs[i].url == url || url.starts_with("about:blank") {
            return;
        }
        self.tabs[i].url = url.to_string();
        let title = self.tabs[i].title.clone();
        self.record_visit(url, &title);
        self.render();
    }

    fn handle(&mut self, ev: Ev) {
        match ev {
            Ev::Chrome(msg) => self.handle_chrome(&msg),
            Ev::Content(id, msg) => {
                let Ok(v) = serde_json::from_str::<Value>(&msg) else { return };
                match v["t"].as_str().unwrap_or("") {
                    "key" => {
                        let k = v["k"].as_str().unwrap_or("").to_string();
                        self.on_key(&k);
                    }
                    "glance" => {
                        if let Some(u) = v["url"].as_str() {
                            self.open_glance(u.to_string());
                        }
                    }
                    "url" => {
                        if let Some(u) = v["url"].as_str() {
                            self.set_tab_url(id, u);
                        }
                    }
                    "openTab" => {
                        // Ctrl+click / middle-click open in the background, as in Chrome.
                        if let Some(u) = v["url"].as_str() {
                            self.open_tab(u.to_string(), !v["background"].as_bool().unwrap_or(false));
                        }
                    }
                    "pageclick" => {
                        if self.extension_popup.take().is_some() {
                            self.render();
                        }
                    }
                    _ => {}
                }
            }
            Ev::Glance(msg) => match msg.as_str() {
                "close" => self.close_glance(),
                "expand" => {
                    if let Some(g) = self.glance.take() {
                        let url = g.url().unwrap_or_default();
                        drop(g);
                        if !url.is_empty() {
                            self.open_tab(url, true);
                        }
                    }
                }
                _ => {}
            },
            Ev::Title(id, title) => {
                if let Some(i) = self.idx(id) {
                    if !title.trim().is_empty() && self.tabs[i].title != title {
                        self.tabs[i].title = title.clone();
                        let url = self.tabs[i].url.clone();
                        if let Some(h) = self.history.iter_mut().find(|h| h.url == url) {
                            h.title = title;
                            self.history_dirty = true;
                        }
                        self.render();
                    }
                }
            }
            Ev::Url(id, url) => self.set_tab_url(id, &url),
            Ev::NewTab(url, foreground) => {
                self.open_tab(url, foreground);
            }
            Ev::Extensions(list) => {
                // Only extensions oxygen manages (WebView2 also lists hidden built-in ones).
                self.extensions = list
                    .into_iter()
                    .filter(|(id, _, _)| self.extension_folders.contains_key(id))
                    .map(|(id, name, enabled)| {
                        let (icon, popup) = self
                            .extension_folders
                            .get(&id)
                            .map(|d| extensions::manifest_details(d))
                            .unwrap_or_default();
                        extensions::Extension { id, name, enabled, icon, popup }
                    })
                    .collect();
                self.extensions.sort_by_key(|e| e.name.to_lowercase());
                self.render();
            }
            Ev::ExtensionAdded(dir, result) => {
                match result {
                    Ok(id) => {
                        if extensions::load_disabled().contains(&extensions::folder_name(&dir)) {
                            let proxy = self.proxy.clone();
                            extensions::set_enabled(&self.chrome, id.clone(), false, move || {
                                let _ = proxy.send_event(Ev::ExtensionsChanged);
                            });
                        }
                        self.extension_folders.insert(id, dir);
                        if self.extension_status == "Installing…" {
                            self.extension_status = "Installed.".into();
                        }
                    }
                    Err(e) => {
                        self.extension_status = format!("{}: {e}", extensions::folder_name(&dir));
                    }
                }
                self.refresh_extensions();
            }
            Ev::ExtensionDownloaded(result) => match result {
                Ok(dir) => {
                    let proxy = self.proxy.clone();
                    let d = dir.clone();
                    extensions::add(&self.chrome, &dir, move |r| {
                        let _ = proxy.send_event(Ev::ExtensionAdded(d, r));
                    });
                }
                Err(e) => {
                    self.extension_status = e;
                    self.render();
                }
            },
            Ev::ExtensionsChanged => self.refresh_extensions(),
            Ev::Suggestions(q, list) => {
                let _ = self
                    .chrome
                    .evaluate_script(&format!("window.zl&&zl.suggestions({},{})", json!(q), json!(list)));
            }
            Ev::Cleared(msg) => {
                self.privacy_status = msg.into();
                self.render();
            }
            Ev::PageFullscreen(id, on) => {
                if on {
                    let was = self.window.fullscreen().is_some();
                    self.page_fullscreen = Some((id, was));
                    self.window.set_fullscreen(Some(Fullscreen::Borderless(None)));
                } else if let Some((_, was)) = self.page_fullscreen.take() {
                    if !was {
                        self.window.set_fullscreen(None);
                    }
                }
                self.layout();
            }
            Ev::Tick => {
                self.mem_mb = self.meter.total_mb();
                self.enforce_limits();
                let _ = self.chrome.evaluate_script(&format!(
                    "window.zl&&zl.mem({},{})",
                    self.mem_mb, self.settings.memory_budget_mb
                ));
                if self.dirty || self.history_dirty {
                    self.save();
                    self.dirty = false;
                }
            }
        }
    }
}

fn main() {
    // Child webviews on Linux need X11 (XWayland works).
    #[cfg(target_os = "linux")]
    std::env::set_var("GDK_BACKEND", "x11");

    let restarted = std::env::args().any(|a| a == "--restarted");
    if !platform::claim_single_instance(restarted) {
        return;
    }

    let session = session::load();
    let event_loop = EventLoopBuilder::<Ev>::with_user_event().build();
    let proxy = event_loop.create_proxy();
    let window = WindowBuilder::new()
        .with_title("oxygen")
        .with_inner_size(LogicalSize::new(1280.0, 800.0))
        .with_min_inner_size(LogicalSize::new(560.0, 380.0))
        .with_background_color((0xe9, 0xf0, 0xf8, 255))
        .with_window_icon(Icon::from_rgba(include_bytes!("../assets/icon64.rgba").to_vec(), 64, 64).ok())
        .build(&event_loop)
        .expect("could not create the window");
    platform::record_window(&window);
    let mut app = App::new(window, proxy.clone(), session);

    std::thread::spawn(move || loop {
        std::thread::sleep(TICK);
        if proxy.send_event(Ev::Tick).is_err() {
            break;
        }
    });

    event_loop.run(move |event, _, control_flow| {
        match event {
            Event::NewEvents(StartCause::ResumeTimeReached { .. }) => {
                app.step_anim();
            }
            Event::WindowEvent { event, .. } => match event {
                WindowEvent::CloseRequested => {
                    app.save();
                    app.exit = true;
                }
                WindowEvent::Resized(_) | WindowEvent::ScaleFactorChanged { .. } => app.layout(),
                WindowEvent::CursorMoved { position, .. } => {
                    // Compact mode: touching the left edge slides the sidebar out.
                    let x = position.x / app.window.scale_factor();
                    if app.settings.compact && !app.peek && x <= MARGIN + 1.0 {
                        app.set_peek(true);
                    }
                }
                _ => {}
            },
            Event::UserEvent(ev) => app.handle(ev),
            _ => {}
        }
        *control_flow = if app.exit {
            ControlFlow::Exit
        } else if app.anim.is_some() {
            ControlFlow::WaitUntil(Instant::now() + FRAME_INTERVAL)
        } else {
            ControlFlow::Wait
        };
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn address_bar_input() {
        assert_eq!(normalize_input("example.com", "duckduckgo"), "https://example.com");
        assert_eq!(normalize_input("localhost:3000", "duckduckgo"), "http://localhost:3000");
        assert_eq!(normalize_input("https://a.b/c?d", "google"), "https://a.b/c?d");
        assert_eq!(normalize_input("rust lang", "duckduckgo"), "https://duckduckgo.com/?q=rust+lang");
        assert_eq!(normalize_input("c++", "google"), "https://www.google.com/search?q=c%2B%2B");
        assert_eq!(normalize_input("hello", "bing"), "https://www.bing.com/search?q=hello");
    }

    #[test]
    fn tells_searches_from_addresses() {
        assert!(is_search_input("hello"));
        assert!(is_search_input("rust lang"));
        assert!(!is_search_input("example.com"));
        assert!(!is_search_input("https://a.b"));
        assert!(!is_search_input("localhost:3000"));
    }

    #[test]
    fn titles_from_urls() {
        assert_eq!(title_from_url("https://www.example.com/path"), "example.com");
    }

    #[test]
    fn base64_matches_reference() {
        assert_eq!(base64(b""), "");
        assert_eq!(base64(b"f"), "Zg==");
        assert_eq!(base64(b"fo"), "Zm8=");
        assert_eq!(base64(b"foo"), "Zm9v");
        assert_eq!(base64(b"oxygen!"), "b3h5Z2VuIQ==");
    }

    #[test]
    fn parses_computed_colors() {
        assert_eq!(parse_rgb("rgb(233, 240, 248)"), Some((233, 240, 248)));
        assert_eq!(parse_rgb("rgba(1, 2, 3, 0.5)"), Some((1, 2, 3)));
        assert_eq!(parse_rgb("color(srgb 0.9 0.9 0.9)"), None);
    }
}
