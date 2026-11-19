//! Saved browser state (workspaces, tabs, settings) and browsing history,
//! persisted as JSON in the user's local app data folder.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// Workspace icons the sidebar knows how to draw.
pub const WORKSPACE_ICONS: [&str; 18] = [
    "home", "briefcase", "code", "book", "music", "game", "cart", "flask", "globe", "heart", "camera", "folder", "chat",
    "terminal", "leaf", "sparkle", "star", "moon",
];
pub const DEFAULT_ACCENT: &str = "#6f9fd8";

#[derive(Serialize, Deserialize, Clone)]
pub struct Workspace {
    pub id: u32,
    pub name: String,
    pub icon: String,
    pub color: String,
}

#[derive(Serialize, Deserialize, Clone)]
pub struct SavedTab {
    pub id: u64,
    pub url: String,
    pub title: String,
    pub workspace: u32,
    #[serde(default)]
    pub pinned: bool,
    #[serde(default)]
    pub essential: bool,
    /// The page a pinned tab or Essential was pinned on.
    #[serde(default)]
    pub pinned_url: Option<String>,
}

#[derive(Serialize, Deserialize, Clone, PartialEq)]
#[serde(default)]
pub struct Settings {
    /// duckduckgo | google | bing | brave | startpage
    pub search_engine: String,
    /// Total RAM (browser + all WebView2 processes) the watchdog tries to stay under.
    pub memory_budget_mb: u64,
    /// Maximum number of tabs kept loaded at once, including the visible ones.
    pub max_loaded_tabs: usize,
    /// Background tabs are unloaded after this many minutes without being looked at.
    pub unload_after_mins: u64,
    /// Sidebar hidden; hovering the left edge slides it over the page.
    pub compact: bool,
    /// Sidebar collapsed to a narrow strip of icons.
    pub collapsed: bool,
    pub block_ads: bool,
    pub sidebar_width: f64,
    /// system | light | dark
    pub theme: String,
    /// Interface font id (see ui.html).
    pub font: String,
    /// Also use the interface font on websites.
    pub font_on_sites: bool,
    /// Show live search suggestions from the search engine while typing.
    pub search_suggestions: bool,
    /// Offer to save passwords and fill forms (Chromium's own autofill).
    pub save_passwords: bool,
    /// Force websites into a dark theme. Takes effect on the next start.
    pub force_dark: bool,
    /// Custom shortcuts: action id -> key combo ("" = unbound). Actions not
    /// listed use their default from keybinds.json.
    pub keybinds: std::collections::BTreeMap<String, String>,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            search_engine: "duckduckgo".into(),
            memory_budget_mb: 800,
            max_loaded_tabs: 4,
            unload_after_mins: 10,
            compact: false,
            collapsed: false,
            block_ads: true,
            sidebar_width: 248.0,
            theme: "system".into(),
            font: "system".into(),
            font_on_sites: false,
            search_suggestions: true,
            save_passwords: true,
            force_dark: false,
            keybinds: Default::default(),
        }
    }
}

#[derive(Serialize, Deserialize, Default)]
#[serde(default)]
pub struct Session {
    pub workspaces: Vec<Workspace>,
    pub tabs: Vec<SavedTab>,
    pub active_workspace: u32,
    /// (workspace id, tab id) pairs.
    pub active_tabs: Vec<(u32, u64)>,
    pub split: Option<(u64, u64)>,
    pub settings: Settings,
    pub next_id: u64,
}

#[derive(Serialize, Deserialize, Clone)]
pub struct HistoryEntry {
    pub url: String,
    pub title: String,
    pub visits: u32,
    /// Seconds since the Unix epoch.
    pub last: u64,
}

pub fn data_dir() -> PathBuf {
    // OXYGEN_DATA_DIR runs a separate profile (handy for testing).
    if let Some(dir) = std::env::var_os("OXYGEN_DATA_DIR") {
        return PathBuf::from(dir);
    }
    dirs::data_local_dir()
        .unwrap_or_else(std::env::temp_dir)
        .join("Oxygen")
}

fn read_json<T: serde::de::DeserializeOwned + Default>(path: &Path) -> T {
    std::fs::read(path)
        .ok()
        .and_then(|b| {
            // Tolerate a UTF-8 byte-order mark (some editors add one).
            let bytes = b.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(&b);
            serde_json::from_slice(bytes).ok()
        })
        .unwrap_or_default()
}

/// Writes then renames, so a crash mid-write never corrupts the file.
fn write_json<T: Serialize>(name: &str, value: &T) {
    let dir = data_dir();
    let _ = std::fs::create_dir_all(&dir);
    if let Ok(json) = serde_json::to_vec(value) {
        let tmp = dir.join(format!("{name}.tmp"));
        if std::fs::write(&tmp, json).is_ok() {
            let _ = std::fs::rename(tmp, dir.join(name));
        }
    }
}

pub fn load() -> Session {
    let mut s: Session = read_json(&data_dir().join("session.json"));
    if s.workspaces.is_empty() {
        s.workspaces.push(Workspace {
            id: 1,
            name: "Home".into(),
            icon: "home".into(),
            color: DEFAULT_ACCENT.into(),
        });
        s.active_workspace = 1;
    }
    for w in &mut s.workspaces {
        // Older versions stored emoji; map them to line icons.
        if !WORKSPACE_ICONS.contains(&w.icon.as_str()) {
            w.icon = if w.name.eq_ignore_ascii_case("home") { "home" } else { "globe" }.into();
        }
        if !w.color.starts_with('#') || w.color == "#7c6cf0" {
            w.color = DEFAULT_ACCENT.into();
        }
    }
    if !s.workspaces.iter().any(|w| w.id == s.active_workspace) {
        s.active_workspace = s.workspaces[0].id;
    }
    let max_id = s.tabs.iter().map(|t| t.id).max().unwrap_or(0);
    s.next_id = s.next_id.max(max_id + 1);
    s
}

pub fn save(s: &Session) {
    write_json("session.json", s);
}

pub fn load_history() -> Vec<HistoryEntry> {
    read_json(&data_dir().join("history.json"))
}

pub fn save_history(h: &[HistoryEntry]) {
    write_json("history.json", &h);
}

pub fn load_searches() -> Vec<crate::search::SearchEntry> {
    read_json(&data_dir().join("searches.json"))
}

pub fn save_searches(s: &[crate::search::SearchEntry]) {
    write_json("searches.json", &s);
}
