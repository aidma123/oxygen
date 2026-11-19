//! Keyboard shortcuts. Defaults live in keybinds.json (shared with the iOS
//! app); the user's changes are stored in Settings::keybinds as
//! action id -> combo ("" means unbound).

use crate::session::Settings;
use serde::{Deserialize, Serialize};
use std::sync::OnceLock;

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct KeyAction {
    pub id: String,
    pub label: String,
    pub combo: String,
}

pub fn defaults() -> &'static [KeyAction] {
    static DEFAULTS: OnceLock<Vec<KeyAction>> = OnceLock::new();
    DEFAULTS.get_or_init(|| serde_json::from_str(include_str!("keybinds.json")).expect("keybinds.json is valid"))
}

/// Every action with the combo currently assigned to it.
pub fn actions(settings: &Settings) -> Vec<KeyAction> {
    defaults()
        .iter()
        .map(|a| KeyAction {
            combo: settings.keybinds.get(&a.id).cloned().unwrap_or_else(|| a.combo.clone()),
            ..a.clone()
        })
        .collect()
}

/// The action bound to a key combo, if any.
pub fn action_for(settings: &Settings, combo: &str) -> Option<String> {
    if combo.is_empty() {
        return None;
    }
    actions(settings).into_iter().find(|a| a.combo == combo).map(|a| a.id)
}

/// Combos pages must pass to the browser instead of handling themselves.
pub fn bound_combos(settings: &Settings) -> Vec<String> {
    actions(settings).into_iter().map(|a| a.combo).filter(|c| !c.is_empty()).collect()
}

/// Script that tells a page which combos are browser shortcuts.
pub fn page_script(settings: &Settings) -> String {
    format!("window.__OXYGEN_KEYS = new Set({});", serde_json::to_string(&bound_combos(settings)).unwrap_or_default())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn overrides_and_unbinding() {
        let mut s = Settings::default();
        assert_eq!(action_for(&s, "ctrl+t").as_deref(), Some("new_tab"));
        s.keybinds.insert("new_tab".into(), "ctrl+shift+n".into());
        assert_eq!(action_for(&s, "ctrl+t"), None);
        assert_eq!(action_for(&s, "ctrl+shift+n").as_deref(), Some("new_tab"));
        s.keybinds.insert("close_tab".into(), String::new());
        assert!(!bound_combos(&s).contains(&"ctrl+w".to_string()));
        assert_eq!(defaults().len(), actions(&s).len());
    }
}
