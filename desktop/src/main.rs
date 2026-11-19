//! oxygen: a Zen-style browser (vertical tabs, workspaces, Essentials, split
//! view, compact mode, Glance) built on the system webview (WebView2 on
//! Windows) and designed to stay under a fixed memory budget.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod blocker;
mod memory;
mod session;

use serde_json::{json, Value};
use session::{SavedTab, Session, Settings, Workspace};
use std::collections::HashMap;
use std::time::{Duration, Instant};
use tao::{
    dpi::LogicalSize,
    event::{Event, WindowEvent},
    event_loop::{ControlFlow, EventLoopBuilder, EventLoopProxy},
    window::{Fullscreen, Icon, Window, WindowBuilder},
};
use wry::{http::Request, NewWindowResponse, Rect, WebContext, WebView, WebViewBuilder};

const UI_HTML: &str = include_str!("ui.html");
const CONTENT_JS: &str = include_str!("content.js");
const GLANCE_JS: &str = include_str!("glance.js");
const COMPACT_STRIP: f64 = 6.0;
const SPLIT_GAP: f64 = 4.0;
const TICK: Duration = Duration::from_secs(3);
const MAX_CLOSED: usize = 25;
const PALETTE: [&str; 6] = ["#7c6cf0", "#e5484d", "#30a46c", "#f76b15", "#0090ff", "#d6409f"];

/// WebView2 flags. Every webview shares one WebView2 environment (one browser
/// process), so these must be identical for all of them. wry's defaults are
/// kept, and renderer processes are capped so sites share processes instead of
/// each one paying for its own.
#[cfg(windows)]
const BROWSER_ARGS: &str =
    "--disable-features=msWebOOUI,msPdfOOUI,msSmartScreenProtection --renderer-process-limit=4";

enum Ev {
    Chrome(String),
    Content(u64, String),
    Glance(String),
    Title(u64, String),
    Url(u64, String),
    NewTab(String),
    Tick,
}

struct Tab {
    id: u64,
    url: String,
    title: String,
    workspace: u32,
    pinned: bool,
    essential: bool,
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
        }
    }
}

struct App {
    window: Window,
    proxy: EventLoopProxy<Ev>,
    ctx: WebContext,
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
    next_id: u64,
    meter: memory::Meter,
    mem_mb: u64,
    dirty: bool,
}

fn rect(x: f64, y: f64, w: f64, h: f64) -> Rect {
    Rect {
        position: wry::dpi::LogicalPosition::new(x, y).into(),
        size: wry::dpi::LogicalSize::new(w.max(0.0), h.max(0.0)).into(),
    }
}

/// Applies the options every webview must share.
fn platform(b: WebViewBuilder<'_>) -> WebViewBuilder<'_> {
    #[cfg(windows)]
    {
        use wry::WebViewBuilderExtWindows;
        b.with_additional_browser_args(BROWSER_ARGS)
            .with_browser_extensions_enabled(true)
            .with_extensions_path(session::data_dir().join("extensions"))
    }
    #[cfg(not(windows))]
    {
        b
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

fn build_content(
    window: &Window,
    ctx: &mut WebContext,
    proxy: &EventLoopProxy<Ev>,
    block_ads: bool,
    id: u64,
    url: &str,
    bounds: Rect,
) -> Option<WebView> {
    let (p1, p2, p3, p4) = (proxy.clone(), proxy.clone(), proxy.clone(), proxy.clone());
    let builder = WebViewBuilder::new_with_web_context(ctx)
        .with_bounds(bounds)
        .with_initialization_script_for_main_only(CONTENT_JS, true)
        .with_ipc_handler(move |r: Request<String>| {
            let _ = p1.send_event(Ev::Content(id, r.into_body()));
        })
        .with_document_title_changed_handler(move |t| {
            let _ = p2.send_event(Ev::Title(id, t));
        })
        .with_on_page_load_handler(move |_, u| {
            let _ = p3.send_event(Ev::Url(id, u));
        })
        .with_new_window_req_handler(move |u, _| {
            // Links that want a new window open as a background tab instead.
            let _ = p4.send_event(Ev::NewTab(u));
            NewWindowResponse::Deny
        });
    let view = match platform(builder).build_as_child(window) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("failed to create tab webview: {e}");
            return None;
        }
    };
    // Install the blocker before the first request goes out.
    if block_ads {
        blocker::install(&view);
    }
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

/// Turns address-bar input into a URL: either the address itself or a search.
fn normalize_input(input: &str, engine: &str) -> String {
    let s = input.trim();
    let lower = s.to_ascii_lowercase();
    const SCHEMES: [&str; 6] = ["http://", "https://", "file://", "about:", "edge://", "data:"];
    if SCHEMES.iter().any(|p| lower.starts_with(p)) {
        return s.to_string();
    }
    let local = lower.starts_with("localhost") || lower.starts_with("127.0.0.1");
    let looks_like_host = !s.contains(char::is_whitespace)
        && (s.contains('.') || local)
        && !s.starts_with('.')
        && !s.ends_with('.');
    if looks_like_host {
        return format!("{}{s}", if local { "http://" } else { "https://" });
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
        let p = proxy.clone();
        let builder = WebViewBuilder::new_with_web_context(&mut ctx)
            .with_html(UI_HTML)
            .with_bounds(rect(0.0, 0.0, s.settings.sidebar_width, 800.0))
            .with_ipc_handler(move |r: Request<String>| {
                let _ = p.send_event(Ev::Chrome(r.into_body()));
            });
        let chrome = platform(builder)
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
                view: None,
                shown: false,
                last_active: now,
            })
            .collect();
        let mut app = App {
            window,
            proxy,
            ctx,
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
            next_id: s.next_id,
            meter: memory::Meter::new(),
            mem_mb: 0,
            dirty: false,
        };
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

    fn sidebar_width(&self) -> f64 {
        if self.settings.compact && !self.peek {
            COMPACT_STRIP
        } else {
            self.settings.sidebar_width
        }
    }

    /// (x, y, width, height) of the page area right of the sidebar.
    fn content_area(&self) -> (f64, f64, f64, f64) {
        let size = self.window.inner_size().to_logical::<f64>(self.window.scale_factor());
        let sw = self.sidebar_width();
        (sw, 0.0, (size.width - sw).max(0.0), size.height)
    }

    fn glance_rect(&self) -> Rect {
        let (x, y, w, h) = self.content_area();
        rect(x + w * 0.06, y + h * 0.05, w * 0.88, h * 0.9)
    }

    /// Positions every webview, loading visible tabs and hiding the rest.
    fn layout(&mut self) {
        let size = self.window.inner_size().to_logical::<f64>(self.window.scale_factor());
        let _ = self.chrome.set_bounds(rect(0.0, 0.0, self.sidebar_width(), size.height));
        let (x, y, w, h) = self.content_area();
        let vis = self.visible_ids();
        let slots = if vis.len() == 2 {
            let half = (w - SPLIT_GAP) / 2.0;
            vec![rect(x, y, half, h), rect(x + half + SPLIT_GAP, y, half, h)]
        } else {
            vec![rect(x, y, w, h)]
        };
        let now = Instant::now();
        for (id, slot) in vis.iter().zip(slots) {
            let Some(i) = self.idx(*id) else { continue };
            if self.tabs[i].view.is_none() {
                let url = self.tabs[i].url.clone();
                self.tabs[i].view = build_content(
                    &self.window,
                    &mut self.ctx,
                    &self.proxy,
                    self.settings.block_ads,
                    *id,
                    &url,
                    slot.clone(),
                );
                self.tabs[i].shown = false;
            }
            let t = &mut self.tabs[i];
            t.last_active = now;
            if let Some(v) = &t.view {
                let _ = v.set_bounds(slot);
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
        if let Some(g) = &self.glance {
            let _ = g.set_bounds(self.glance_rect());
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
        let split = self.split;
        let tj = |t: &Tab| {
            json!({
                "id": t.id, "url": t.url, "title": t.title, "loaded": t.view.is_some(),
                "active": Some(t.id) == active, "essential": t.essential, "pinned": t.pinned,
                "inSplit": split.is_some_and(|(a, b)| a == t.id || b == t.id),
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
            "split": split.filter(|_| self.visible_ids().len() == 2), "compact": self.settings.compact,
            "peek": self.peek, "settings": self.settings, "mem": self.mem_mb,
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

    fn save(&self) {
        session::save(&Session {
            workspaces: self.workspaces.clone(),
            tabs: self.tabs.iter().map(Tab::saved).collect(),
            active_workspace: self.active_ws,
            active_tabs: self.active_tab.iter().map(|(w, t)| (*w, *t)).collect(),
            split: self.split,
            settings: self.settings.clone(),
            next_id: self.next_id,
        });
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
        if self.settings.compact {
            self.peek = false;
        }
        self.layout();
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

    fn reopen_closed(&mut self) {
        if let Some(t) = self.closed.pop() {
            let ws = if self.workspaces.iter().any(|w| w.id == t.workspace) { t.workspace } else { self.active_ws };
            self.active_ws = ws;
            let id = self.open_tab(t.url, false);
            if let Some(i) = self.idx(id) {
                self.tabs[i].title = t.title;
                self.tabs[i].pinned = t.pinned;
                self.tabs[i].essential = t.essential;
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

    fn set_compact(&mut self, on: bool) {
        self.settings.compact = on;
        self.peek = false;
        self.layout();
        self.render();
    }

    fn focus_address(&mut self, new_tab: bool) {
        if self.settings.compact && !self.peek {
            self.peek = true;
            self.layout();
            self.render();
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
        let bounds = self.glance_rect();
        let builder = WebViewBuilder::new_with_web_context(&mut self.ctx)
            .with_bounds(bounds)
            .with_initialization_script_for_main_only(GLANCE_JS, true)
            .with_ipc_handler(move |r: Request<String>| {
                let _ = p1.send_event(Ev::Glance(r.into_body()));
            })
            .with_new_window_req_handler(move |u, _| {
                let _ = p2.send_event(Ev::NewTab(u));
                NewWindowResponse::Deny
            });
        if let Ok(v) = platform(builder).build_as_child(&self.window) {
            if self.settings.block_ads {
                blocker::install(&v);
            }
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

    fn on_key(&mut self, k: &str) {
        match k {
            "ctrl+t" => self.focus_address(true),
            "ctrl+l" => self.focus_address(false),
            "ctrl+w" => {
                if self.glance.is_some() {
                    self.close_glance();
                } else if let Some(a) = self.active() {
                    self.close(a);
                }
            }
            "ctrl+shift+t" => self.reopen_closed(),
            "ctrl+tab" => self.cycle_tab(1),
            "ctrl+shift+tab" => self.cycle_tab(-1),
            "ctrl+alt+c" => self.set_compact(!self.settings.compact),
            "ctrl+alt+v" => self.toggle_split(),
            "ctrl+alt+arrowleft" => self.cycle_ws(-1),
            "ctrl+alt+arrowright" => self.cycle_ws(1),
            "ctrl+shift+e" => {
                if let Some(a) = self.active() {
                    self.toggle_essential(a);
                }
            }
            "f11" => {
                let fs = self.window.fullscreen().is_some();
                self.window.set_fullscreen(if fs { None } else { Some(Fullscreen::Borderless(None)) });
            }
            "escape" => {
                self.close_glance();
                if self.peek {
                    self.peek = false;
                    self.layout();
                    self.render();
                }
            }
            "ctrl+r" | "f5" => {
                if let Some(v) = self.active_view() {
                    let _ = v.reload();
                }
            }
            "alt+arrowleft" => {
                if let Some(v) = self.active_view() {
                    let _ = v.go_back();
                }
            }
            "alt+arrowright" => {
                if let Some(v) = self.active_view() {
                    let _ = v.go_forward();
                }
            }
            _ => {
                if let Some(n) = k.strip_prefix("ctrl+").and_then(|d| d.parse::<usize>().ok()) {
                    let list = self.ws_tab_ids(self.active_ws);
                    let target = if n == 9 { list.last() } else { list.get(n.wrapping_sub(1)) };
                    if let Some(id) = target.copied() {
                        self.select(id);
                    }
                }
            }
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
            self.render();
        }
    }

    fn handle_chrome(&mut self, msg: &str) {
        let Ok(v) = serde_json::from_str::<Value>(msg) else { return };
        let id = v["id"].as_u64().unwrap_or(0);
        match v["t"].as_str().unwrap_or("") {
            "ready" => {
                self.chrome_ready = true;
                self.render();
                if self.tabs.is_empty() {
                    self.focus_address(true);
                }
            }
            "go" => {
                let url = normalize_input(v["input"].as_str().unwrap_or(""), &self.settings.search_engine);
                if self.settings.compact {
                    self.peek = false;
                }
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
            "back" => self.on_key("alt+arrowleft"),
            "forward" => self.on_key("alt+arrowright"),
            "reload" => self.on_key("ctrl+r"),
            "reloadTab" => {
                if let Some(view) = self.idx(id).and_then(|i| self.tabs[i].view.as_ref()) {
                    let _ = view.reload();
                }
            }
            "pin" => {
                if let Some(i) = self.idx(id) {
                    self.tabs[i].pinned = !self.tabs[i].pinned;
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
            "compact" => self.set_compact(!self.settings.compact),
            "peek" => {
                let on = v["on"].as_bool().unwrap_or(false);
                if self.settings.compact && self.peek != on {
                    self.peek = on;
                    self.layout();
                    self.render();
                }
            }
            "ws" => self.switch_ws(v["id"].as_u64().unwrap_or(0) as u32),
            "newWs" => {
                let new_id = self.workspaces.iter().map(|w| w.id).max().unwrap_or(0) + 1;
                self.workspaces.push(Workspace {
                    id: new_id,
                    name: v["name"].as_str().unwrap_or("Workspace").to_string(),
                    icon: v["icon"].as_str().unwrap_or("✨").to_string(),
                    color: PALETTE[new_id as usize % PALETTE.len()].to_string(),
                });
                self.switch_ws(new_id);
            }
            "editWs" => {
                let ws_id = id as u32;
                if let Some(w) = self.workspaces.iter_mut().find(|w| w.id == ws_id) {
                    w.name = v["name"].as_str().unwrap_or(&w.name).to_string();
                    w.icon = v["icon"].as_str().unwrap_or(&w.icon).to_string();
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
                    self.settings = new;
                    self.peek = false;
                    self.layout();
                    self.enforce_limits();
                    self.render();
                }
            }
            "key" => {
                let k = v["k"].as_str().unwrap_or("").to_string();
                self.on_key(&k);
            }
            _ => {}
        }
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
                        if let (Some(i), Some(u)) = (self.idx(id), v["url"].as_str()) {
                            if self.tabs[i].url != u {
                                self.tabs[i].url = u.to_string();
                                self.render();
                            }
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
                        self.tabs[i].title = title;
                        self.render();
                    }
                }
            }
            Ev::Url(id, url) => {
                if let Some(i) = self.idx(id) {
                    if self.tabs[i].url != url && !url.starts_with("about:blank") {
                        self.tabs[i].url = url;
                        self.render();
                    }
                }
            }
            Ev::NewTab(url) => {
                self.open_tab(url, false);
            }
            Ev::Tick => {
                self.mem_mb = self.meter.total_mb();
                self.enforce_limits();
                let _ = self.chrome.evaluate_script(&format!(
                    "window.zl&&zl.mem({},{})",
                    self.mem_mb, self.settings.memory_budget_mb
                ));
                if self.dirty {
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

    let event_loop = EventLoopBuilder::<Ev>::with_user_event().build();
    let proxy = event_loop.create_proxy();
    let window = WindowBuilder::new()
        .with_title("oxygen")
        .with_inner_size(LogicalSize::new(1280.0, 800.0))
        .with_min_inner_size(LogicalSize::new(520.0, 360.0))
        .with_window_icon(Icon::from_rgba(include_bytes!("../assets/icon64.rgba").to_vec(), 64, 64).ok())
        .build(&event_loop)
        .expect("could not create the window");
    let mut app = App::new(window, proxy.clone(), session::load());

    std::thread::spawn(move || loop {
        std::thread::sleep(TICK);
        if proxy.send_event(Ev::Tick).is_err() {
            break;
        }
    });

    event_loop.run(move |event, _, control_flow| {
        *control_flow = ControlFlow::Wait;
        match event {
            Event::WindowEvent { event, .. } => match event {
                WindowEvent::CloseRequested => {
                    app.save();
                    *control_flow = ControlFlow::Exit;
                }
                WindowEvent::Resized(_) | WindowEvent::ScaleFactorChanged { .. } => app.layout(),
                _ => {}
            },
            Event::UserEvent(ev) => app.handle(ev),
            _ => {}
        }
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
    fn titles_from_urls() {
        assert_eq!(title_from_url("https://www.example.com/path"), "example.com");
    }
}
