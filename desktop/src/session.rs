//! Saved browser state: workspaces, tabs and settings, persisted as JSON.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

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
}

#[derive(Serialize, Deserialize, Clone)]
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
    pub compact: bool,
    pub block_ads: bool,
    pub sidebar_width: f64,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            search_engine: "duckduckgo".into(),
            memory_budget_mb: 800,
            max_loaded_tabs: 4,
            unload_after_mins: 10,
            compact: false,
            block_ads: true,
            sidebar_width: 250.0,
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

pub fn data_dir() -> PathBuf {
    dirs::data_local_dir()
        .unwrap_or_else(std::env::temp_dir)
        .join("ZenLite")
}

fn session_path() -> PathBuf {
    data_dir().join("session.json")
}

pub fn load() -> Session {
    let mut s: Session = std::fs::read(session_path())
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default();
    if s.workspaces.is_empty() {
        s.workspaces.push(Workspace {
            id: 1,
            name: "Home".into(),
            icon: "🏠".into(),
            color: "#7c6cf0".into(),
        });
        s.active_workspace = 1;
    }
    if !s.workspaces.iter().any(|w| w.id == s.active_workspace) {
        s.active_workspace = s.workspaces[0].id;
    }
    let max_id = s.tabs.iter().map(|t| t.id).max().unwrap_or(0);
    s.next_id = s.next_id.max(max_id + 1);
    s
}

pub fn save(s: &Session) {
    let dir = data_dir();
    let _ = std::fs::create_dir_all(&dir);
    if let Ok(json) = serde_json::to_vec_pretty(s) {
        // Write then rename so a crash mid-write never corrupts the session.
        let tmp = dir.join("session.json.tmp");
        if std::fs::write(&tmp, json).is_ok() {
            let _ = std::fs::rename(tmp, session_path());
        }
    }
}
