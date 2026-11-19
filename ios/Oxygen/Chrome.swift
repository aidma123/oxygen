import Combine
import UIKit
import WebKit

/// Hosts the sidebar: the exact same page (ui.html) the Windows version
/// uses, speaking the same messages. This file is the iOS counterpart of the
/// sidebar handling in desktop/src/main.rs.
@MainActor
final class Chrome {
    let webView: WKWebView
    private weak var store: BrowserStore?
    private var ready = false
    private var renderQueued = false
    private var cancellable: AnyCancellable?

    // The page identifies tabs and workspaces by number, as on Windows.
    private var numbers: [UUID: Int] = [:]
    private var uuids: [Int: UUID] = [:]
    private var nextNumber = 1

    init(store: BrowserStore) {
        self.store = store
        let config = WKWebViewConfiguration()
        let ucc = config.userContentController
        ucc.addUserScript(WKUserScript(source: Shared.bridgeJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        ucc.add(ScriptMessageProxy { [weak self] body in
            Task { @MainActor in self?.handle(body) }
        }, name: "ipc")
        webView.loadHTMLString(Shared.sidebarHTML, baseURL: nil)

        // Re-render whenever browser state changes (coalesced to one per frame).
        cancellable = store.objectWillChange.sink { [weak self] _ in
            guard let self, !self.renderQueued else { return }
            self.renderQueued = true
            DispatchQueue.main.async {
                self.renderQueued = false
                self.render()
            }
        }
    }

    private func number(_ id: UUID) -> Int {
        if let n = numbers[id] { return n }
        let n = nextNumber
        nextNumber += 1
        numbers[id] = n
        uuids[n] = id
        return n
    }

    private func uuid(_ value: Any?) -> UUID? {
        guard let n = (value as? NSNumber)?.intValue else { return nil }
        return uuids[n]
    }

    private func call(_ function: String, _ argument: Any) {
        guard ready,
              let data = try? JSONSerialization.data(withJSONObject: argument, options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.zl&&zl.\(function)(\(json))", completionHandler: nil)
    }

    // MARK: - State sent to the page (same shape as Windows)

    func render() {
        guard let store, ready else { return }
        let active = store.activeTabID
        func tab(_ t: TabRecord) -> [String: Any] {
            [
                "id": number(t.id), "url": t.url.absoluteString, "title": t.title,
                "loaded": store.loadedIDs.contains(t.id), "active": t.id == active,
                "essential": t.essential, "pinned": t.pinned,
                "pinnedUrl": t.pinnedURL.map { $0.absoluteString as Any } ?? NSNull(), "away": t.away,
            ]
        }
        let s = store.settings
        let state: [String: Any] = [
            "workspaces": store.workspaces.map {
                ["id": number($0.id), "name": $0.name, "icon": $0.icon, "color": $0.colorHex] as [String: Any]
            },
            "activeWs": number(store.activeWorkspace),
            "essentials": store.essentials.map(tab),
            "pinned": store.pinnedTabs.map(tab),
            "tabs": store.regularTabs.map(tab),
            "activeId": active.map { number($0) as Any } ?? NSNull(),
            "activeUrl": store.activeTab?.url.absoluteString ?? "",
            "split": store.split.map { $0.map(number) as Any } ?? NSNull(),
            "mode": store.mode,
            "mem": store.memoryMB,
            "restartNeeded": false,
            "keyActions": Shared.keyActions(s),
            "extSupported": false,
            "extensions": [Any](),
            "privacyStatus": store.privacyStatus,
            "settings": [
                "search_engine": s.searchEngine.rawValue,
                "memory_budget_mb": s.memoryBudgetMB,
                "max_loaded_tabs": s.maxLoadedTabs,
                "unload_after_mins": s.unloadAfterMinutes,
                "compact": store.compact,
                "collapsed": s.collapsed,
                "block_ads": s.blockAds,
                "sidebar_width": 248,
                "theme": s.theme,
                "font": s.font,
                "force_dark": s.forceDark,
                "font_on_sites": s.fontOnSites,
                "search_suggestions": s.searchSuggestions,
                "save_passwords": s.savePasswords,
                "keybinds": s.keybinds,
            ] as [String: Any],
        ]
        call("render", state)
    }

    func updateMemory() {
        guard let store, ready else { return }
        webView.evaluateJavaScript("window.zl&&zl.mem(\(store.memoryMB),\(store.settings.memoryBudgetMB))", completionHandler: nil)
    }

    func focusAddress(newTab: Bool) {
        webView.evaluateJavaScript("window.zl&&zl.focusUrl(\(newTab))", completionHandler: nil)
    }

    // MARK: - Messages from the page (same protocol as Windows)

    private func handle(_ body: String) {
        guard let store,
              let data = body.data(using: .utf8),
              let v = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = v["t"] as? String else { return }
        let id = uuid(v["id"])
        switch type {
        case "ready":
            ready = true
            render()
            updateMemory()
        case "frame":
            if let color = parseRGB(v["color"] as? String) { store.frameColor = color }
        case "history":
            let list = store.suggestionHistory().map { ["url": $0.url.absoluteString, "title": $0.title] }
            if let a = try? JSONSerialization.data(withJSONObject: list), let b = try? JSONSerialization.data(withJSONObject: Array(store.searches.prefix(100))),
               let la = String(data: a, encoding: .utf8), let lb = String(data: b, encoding: .utf8), ready {
                webView.evaluateJavaScript("window.zl&&zl.history(\(la),\(lb))", completionHandler: nil)
            }
        case "suggest":
            let q = v["q"] as? String ?? ""
            guard store.settings.searchSuggestions, !q.trimmingCharacters(in: .whitespaces).isEmpty else { break }
            let engine = store.settings.searchEngine
            Task { @MainActor [weak self] in
                let list = await Shared.fetchSuggestions(engine: engine, query: q)
                guard let self, self.ready,
                      let qa = try? JSONSerialization.data(withJSONObject: [q]), let la = try? JSONSerialization.data(withJSONObject: list),
                      let qs = String(data: qa, encoding: .utf8), let ls = String(data: la, encoding: .utf8) else { return }
                self.webView.evaluateJavaScript("window.zl&&zl.suggestions(\(qs)[0],\(ls))", completionHandler: nil)
            }
        case "clearData": store.clearData(v["kind"] as? String ?? "")
        case "resetPin": if let id { store.resetPin(id) }
        case "setPinUrl": if let id { store.setPinURL(id) }
        case "action": runAction(v["id"] as? String ?? "")
        case "go":
            store.setPeek(false)
            store.go(v["input"] as? String ?? "", newTab: v["newTab"] as? Bool ?? false)
        case "select": if let id { store.select(id) }
        case "close": if let id { store.close(id) }
        case "clear": store.clearTabs()
        case "back": store.goBack()
        case "forward": store.goForward()
        case "reload": store.reload()
        case "collapse": store.toggleCollapsed()
        case "reloadTab": if let id { store.reloadTab(id) }
        case "pin": if let id { store.togglePin(id) }
        case "essential": if let id { store.toggleEssential(id) }
        case "split": if let id { store.splitWith(id) }
        case "unsplit": store.unsplit()
        case "peek": store.setPeek(v["on"] as? Bool ?? false)
        case "ws": if let id { store.switchWorkspace(id) }
        case "newWs":
            store.addWorkspace(
                name: v["name"] as? String ?? "",
                icon: v["icon"] as? String ?? "globe",
                colorHex: v["color"] as? String ?? WorkspaceStyle.colors[0]
            )
        case "editWs":
            if let id, let ws = store.workspaces.first(where: { $0.id == id }) {
                store.editWorkspace(
                    id,
                    name: v["name"] as? String ?? ws.name,
                    icon: v["icon"] as? String ?? ws.icon,
                    colorHex: v["color"] as? String ?? ws.colorHex
                )
            }
        case "deleteWs": if let id { store.deleteWorkspace(id) }
        case "move":
            if let id { store.moveTab(id, before: uuid(v["before"]), section: v["section"] as? String ?? "tabs") }
        case "moveWs":
            if let id, let ws = uuid(v["ws"]) { store.move(id, toWorkspace: ws) }
        case "unload":
            if let id, !store.visibleIDs().contains(id) { store.unload(id) }
        case "duplicate": if let id { store.duplicate(id) }
        case "settings":
            if let s = v["settings"] as? [String: Any] { applySettings(s) }
        case "tabs":
            store.captureVisibleThumbnails()
            store.showTabs = true
        case "key": handleKey(v["k"] as? String ?? "")
        default: break
        }
    }

    private func applySettings(_ s: [String: Any]) {
        guard let store else { return }
        var new = store.settings
        if let e = (s["search_engine"] as? String).flatMap(SearchEngine.init(rawValue:)) { new.searchEngine = e }
        if let n = (s["memory_budget_mb"] as? NSNumber)?.intValue { new.memoryBudgetMB = n }
        if let n = (s["max_loaded_tabs"] as? NSNumber)?.intValue { new.maxLoadedTabs = n }
        if let n = (s["unload_after_mins"] as? NSNumber)?.intValue { new.unloadAfterMinutes = n }
        if let b = s["block_ads"] as? Bool { new.blockAds = b }
        if let b = s["collapsed"] as? Bool { new.collapsed = b }
        if let t = s["theme"] as? String { new.theme = t }
        if let f = s["font"] as? String { new.font = f }
        if let b = s["force_dark"] as? Bool { new.forceDark = b }
        if let b = s["font_on_sites"] as? Bool { new.fontOnSites = b }
        if let b = s["search_suggestions"] as? Bool { new.searchSuggestions = b }
        if let b = s["save_passwords"] as? Bool { new.savePasswords = b }
        if let k = s["keybinds"] as? [String: String] { new.keybinds = k }
        if new != store.settings { store.settings = new }
        if let b = s["compact"] as? Bool, b != store.compact {
            store.compact = b
            store.peek = false
        }
    }

    /// Keyboard shortcuts, identical to Windows: fixed keys first, then the
    /// user's shortcuts (defaults in keybinds.json). ⌘ arrives as "ctrl".
    func handleKey(_ k: String) {
        guard let store else { return }
        switch k {
        case "escape":
            store.glance = nil
            store.setPeek(false)
        case "f5": runAction("reload")
        default:
            if let action = Shared.action(for: k, store.settings) {
                runAction(action)
            } else if k.hasPrefix("ctrl+"), let n = Int(k.dropFirst(5)) {
                let list = store.orderedTabIDs
                let target = n == 9 ? list.last : (n >= 1 && n <= list.count ? list[n - 1] : nil)
                if let target { store.select(target) }
            }
        }
    }

    func runAction(_ action: String) {
        guard let store else { return }
        switch action {
        case "new_tab": store.requestAddress(newTab: true)
        case "focus_address": store.requestAddress(newTab: false)
        case "close_tab":
            if store.glance != nil { store.glance = nil } else { store.closeActive() }
        case "reopen_tab": store.reopenClosed()
        case "next_tab": store.cycleTab(1)
        case "prev_tab": store.cycleTab(-1)
        case "collapse_sidebar": store.toggleCollapsed()
        case "compact_mode":
            store.compact.toggle()
            store.peek = false
        case "split_view": store.toggleSplit()
        case "prev_workspace": store.cycleWorkspace(-1)
        case "next_workspace": store.cycleWorkspace(1)
        case "add_essential": if let a = store.activeTabID { store.toggleEssential(a) }
        case "reload": store.reload()
        case "back": store.goBack()
        case "forward": store.goForward()
        default: break
        }
    }
    private func parseRGB(_ s: String?) -> UIColor? {
        guard let s, let open = s.firstIndex(of: "(") else { return nil }
        let parts = s[s.index(after: open)...]
            .trimmingCharacters(in: CharacterSet(charactersIn: ")"))
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count >= 3 else { return nil }
        return UIColor(red: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255, alpha: 1)
    }
}
