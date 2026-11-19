//! Search memory and live search suggestions.

use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Clone)]
pub struct SearchEntry {
    pub query: String,
    pub count: u32,
    /// Seconds since the Unix epoch.
    pub last: u64,
}

const MAX_SEARCHES: usize = 500;

/// Remembers a search (most recent first).
pub fn remember(searches: &mut Vec<SearchEntry>, query: &str, now: u64) {
    let q = query.trim();
    if q.is_empty() {
        return;
    }
    let count = match searches.iter().position(|s| s.query.eq_ignore_ascii_case(q)) {
        Some(i) => searches.remove(i).count + 1,
        None => 1,
    };
    searches.insert(0, SearchEntry { query: q.to_string(), count, last: now });
    searches.truncate(MAX_SEARCHES);
}

/// The search engine's suggestion endpoint (OpenSearch JSON: ["q", [..]]).
fn suggest_url(engine: &str, q: &str) -> String {
    let q = crate::percent_encode(q);
    match engine {
        "google" => format!("https://suggestqueries.google.com/complete/search?client=firefox&q={q}"),
        "bing" => format!("https://api.bing.com/osjson.aspx?query={q}"),
        "brave" => format!("https://search.brave.com/api/suggest?q={q}"),
        "startpage" => format!("https://www.startpage.com/suggestions?q={q}&format=opensearch"),
        _ => format!("https://duckduckgo.com/ac/?q={q}&type=list"),
    }
}

/// Fetches live suggestions. Blocking; call from a background thread.
pub fn fetch_suggestions(engine: &str, q: &str) -> Vec<String> {
    let url = suggest_url(engine, q);
    let mut cmd = std::process::Command::new("curl.exe");
    cmd.args(["-fsSL", "--max-time", "3", &url]);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000); // no console window
    }
    let Ok(out) = cmd.output() else { return Vec::new() };
    parse_suggestions(&out.stdout)
}

pub fn parse_suggestions(body: &[u8]) -> Vec<String> {
    serde_json::from_slice::<serde_json::Value>(body)
        .ok()
        .and_then(|v| v.get(1).and_then(|l| l.as_array()).cloned())
        .map(|list| list.iter().filter_map(|s| s.as_str().map(str::to_string)).take(5).collect())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn remembers_most_recent_first() {
        let mut s = Vec::new();
        remember(&mut s, "rust", 1);
        remember(&mut s, "zen browser", 2);
        remember(&mut s, "Rust", 3);
        assert_eq!(s[0].query, "Rust");
        assert_eq!(s[0].count, 2);
        assert_eq!(s.len(), 2);
    }

    #[test]
    fn parses_opensearch() {
        assert_eq!(parse_suggestions(br#"["ox",["oxygen","oxford"]]"#), vec!["oxygen", "oxford"]);
        assert!(parse_suggestions(b"garbage").is_empty());
    }
}
