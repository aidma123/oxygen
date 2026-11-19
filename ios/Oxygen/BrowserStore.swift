import Combine
import SwiftUI
import UIKit
import WebKit

/// All browser state: workspaces, tabs, settings, and the live web views.
/// Web views exist only for loaded tabs; the rest are plain records that cost
/// almost nothing until you open them.
@MainActor
final class BrowserStore: NSObject, ObservableObject {
    @Published var workspaces: [Workspace] = []
    @Published var tabs: [TabRecord] = []
    @Published var activeWorkspace = UUID()
    @Published var activeTabs: [UUID: UUID] = [:]
    @Published var split: [UUID]?
    @Published var settings = BrowserSettings() {
        didSet { settingsChanged(from: oldValue) }
    }
    @Published var compact = false
    /// The full sidebar is floating over the page (Windows' "peek").
    @Published var peek = false
    /// iPhone portrait: too narrow to dock the full sidebar, so it rests collapsed.
    @Published var narrow = false
    /// Frame colour reported by the shared sidebar page.
    @Published var frameColor: UIColor?
    @Published var memoryMB = 0
    @Published var showSidebar = false
    @Published var showTabs = false
    @Published var glance: GlanceItem?
    @Published var addressRequest: AddressRequest?
    @Published private(set) var loadedIDs: Set<UUID> = []
    @Published private(set) var progress: [UUID: Double] = [:]
    @Published private(set) var backForward: [UUID: (Bool, Bool)] = [:]
    /// Page previews for the tab viewer, kept as compressed JPEG (~25 KB each)
    /// and only decoded while the tab viewer is on screen.
    @Published private(set) var thumbnails: [UUID: Data] = [:]
    /// Visited pages, for address bar suggestions.
    @Published private(set) var history: [HistoryEntry] = []
    /// Searches typed into the address bar, most recent first.
    @Published private(set) var searches: [String] = []
    @Published var privacyStatus = ""
    private var searchesDirty = false

    private var webViews: [UUID: WKWebView] = [:]
    private var historyDirty = false
    /// The shared sidebar (same page as Windows).
    lazy var chrome = Chrome(store: self)

    /// Same modes as the Windows sidebar.
    var mode: String {
        if peek { return "peek" }
        if compact { return "hidden" }
        if settings.collapsed || narrow { return "rail" }
        return "expanded"
    }
    private var observers: [UUID: [NSKeyValueObservation]] = [:]
    private var lastActive: [UUID: Date] = [:]
    private var previouslyVisible: Set<UUID> = []
    private var closedTabs: [TabRecord] = []
    private var ruleList: WKContentRuleList?
    private var cancellables: Set<AnyCancellable> = []
    private var timer: Timer?

    override init() {
        super.init()
        if let s = Persistence.load(), !s.workspaces.isEmpty {
            // Older versions stored emoji icons and a purple accent.
            workspaces = s.workspaces.map { ws in
                var ws = ws
                if WorkspaceStyle.symbols[ws.icon] == nil {
                    ws.icon = ws.name.lowercased() == "home" ? "home" : "globe"
                }
                if ws.colorHex.lowercased() == "#7c6cf0" { ws.colorHex = WorkspaceStyle.colors[0] }
                return ws
            }
            tabs = s.tabs
            activeWorkspace = s.workspaces.contains(where: { $0.id == s.activeWorkspace }) ? s.activeWorkspace : s.workspaces[0].id
            activeTabs = s.activeTabs
            split = s.split
            settings = s.settings
            compact = s.compact
        } else {
            let home = Workspace(name: "Home", icon: "home", colorHex: WorkspaceStyle.colors[0])
            workspaces = [home]
            activeWorkspace = home.id
        }
        history = Persistence.loadHistory()
        searches = Persistence.loadSearches()
        AppFont.current = settings.font

        ContentBlocker.load { [weak self] list in
            Task { @MainActor in
                guard let self, let list else { return }
                self.ruleList = list
                if self.settings.blockAds {
                    for view in self.webViews.values {
                        view.configuration.userContentController.add(list)
                    }
                }
            }
        }

        // iOS is about to kill something: drop every tab that isn't on screen.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.enforceLimits(aggressive: true) }
        }

        // Every few seconds: measure memory, enforce limits, update the meter.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }

        objectWillChange
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.save() }
            }
            .store(in: &cancellables)

        refresh()
    }

    // MARK: - Derived state

    var activeWorkspaceModel: Workspace {
        workspaces.first(where: { $0.id == activeWorkspace }) ?? workspaces[0]
    }

    var accentColor: Color { Color(hex: activeWorkspaceModel.colorHex) }

    var activeTabID: UUID? {
        guard let id = activeTabs[activeWorkspace], tabs.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    var activeTab: TabRecord? { activeTabID.flatMap(tab) }

    var essentials: [TabRecord] { tabs.filter(\.essential) }

    var pinnedTabs: [TabRecord] {
        tabs.filter { !$0.essential && $0.pinned && $0.workspaceID == activeWorkspace }
    }

    var regularTabs: [TabRecord] {
        tabs.filter { !$0.essential && !$0.pinned && $0.workspaceID == activeWorkspace }
    }

    /// Tabs in sidebar order: Essentials, pinned, then the rest.
    var orderedTabIDs: [UUID] { (essentials + pinnedTabs + regularTabs).map(\.id) }

    var activeProgress: Double? { activeTabID.flatMap { progress[$0] } }
    var canGoBack: Bool { activeTabID.flatMap { backForward[$0]?.0 } ?? false }
    var canGoForward: Bool { activeTabID.flatMap { backForward[$0]?.1 } ?? false }

    func tab(_ id: UUID) -> TabRecord? { tabs.first(where: { $0.id == id }) }
    private func index(_ id: UUID) -> Int? { tabs.firstIndex(where: { $0.id == id }) }

    func visibleIDs() -> [UUID] {
        guard let active = activeTabID else { return [] }
        if let pair = split, pair.count == 2, pair.contains(active), pair.allSatisfy({ tab($0) != nil }) {
            return pair
        }
        return [active]
    }

    func isInSplit(_ id: UUID) -> Bool { split?.contains(id) ?? false }

    func loadedWebView(_ id: UUID) -> WKWebView? { webViews[id] }

    // MARK: - Web views

    private func tick() {
        memoryMB = MemoryInfo.footprintMB()
        enforceLimits(aggressive: memoryMB > settings.memoryBudgetMB)
        chrome.updateMemory()
    }

    /// A page webview with the same injected script as Windows (shortcuts,
    /// Alt+click Glance, single-page-app URL tracking).
    func makeWebView() -> WKWebView {
        makeWebView(script: Shared.contentJS, onMessage: nil)
    }

    func makeWebView(script: String, onMessage: ((String) -> Void)?) -> WKWebView {
        makeWebView(script: script) { body, _ in onMessage?(body) }
    }

    func makeWebView(script: String, onMessage: @escaping (String, WKWebView?) -> Void) -> WKWebView {
        let config = WKWebViewConfiguration()
        let ucc = config.userContentController
        installScripts(ucc, page: script)
        ucc.add(ScriptMessageProxy(withSender: { body, sender in
            Task { @MainActor in onMessage(body, sender) }
        }), name: "ipc")
        config.allowsInlineMediaPlayback = true
        // Media waits for a tap: autoplaying video is a big memory and battery cost.
        config.mediaTypesRequiringUserActionForPlayback = .all
        if settings.blockAds, let list = ruleList {
            config.userContentController.add(list)
        }
        let view = WKWebView(frame: .zero, configuration: config)
        view.allowsBackForwardNavigationGestures = true
        view.navigationDelegate = self
        view.uiDelegate = self
        // Sites with their own dark theme use it; the script darkens the rest.
        if settings.forceDark { view.overrideUserInterfaceStyle = .dark }
        return view
    }

    /// Darkens pages that are still light after loading, leaving images and
    /// video untouched. Pages that are already dark are skipped.
    static let forceDarkScript = WKUserScript(source: """
        (() => {
          const apply = () => {
            if (document.getElementById('__oxygen_dark')) return;
            const bg = (el) => {
              if (!el) return null;
              const m = getComputedStyle(el).backgroundColor.match(/[\\d.]+/g);
              if (!m || (m.length === 4 && +m[3] === 0)) return null;
              return m.map(Number);
            };
            const c = bg(document.body) || bg(document.documentElement) || [255, 255, 255];
            if ((0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]) / 255 < 0.45) return;
            const s = document.createElement('style');
            s.id = '__oxygen_dark';
            s.textContent = 'html{filter:invert(.92) hue-rotate(180deg)!important;background:#fff!important}' +
              'img,video,picture,canvas,iframe,embed,object,svg image,[style*="background-image"]' +
              '{filter:invert(1) hue-rotate(180deg)!important}';
            (document.head || document.documentElement).appendChild(s);
          };
          if (document.readyState === 'loading') addEventListener('DOMContentLoaded', apply); else apply();
        })();
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true)

    /// Bridge, page setup (shortcuts, site font), the page script and forced
    /// dark mode, in that order. Re-run when those settings change.
    func installScripts(_ ucc: WKUserContentController, page: String) {
        ucc.removeAllUserScripts()
        ucc.addUserScript(WKUserScript(source: Shared.bridgeJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.addUserScript(WKUserScript(source: Shared.pageSetupScript(settings), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.addUserScript(WKUserScript(source: page, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if settings.forceDark { ucc.addUserScript(Self.forceDarkScript) }
    }

    private func load(_ id: UUID) {
        guard webViews[id] == nil, let record = tab(id) else { return }
        let view = makeWebView(script: Shared.contentJS) { [weak self] body, sender in
            // Route by the sending view: pop-ups share their opener's handler.
            guard let self else { return }
            self.contentMessage(sender.flatMap { self.webViewID($0) } ?? id, body)
        }
        attach(id, view)
        view.load(URLRequest(url: record.url))
    }

    /// Starts tracking a tab's web view (title, address, progress, history).
    private func attach(_ id: UUID, _ view: WKWebView) {
        observers[id] = [
            view.observe(\.title, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in
                    guard let self, let t = wv.title, !t.isEmpty else { return }
                    self.update(id) { $0.title = t }
                    if let u = wv.url { self.setHistoryTitle(t, for: u) }
                }
            },
            view.observe(\.url, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in
                    guard let self, let u = wv.url else { return }
                    if self.tab(id)?.url != u { self.recordVisit(u, title: wv.title ?? "") }
                    self.update(id) { $0.url = u }
                }
            },
            view.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in self?.progress[id] = wv.estimatedProgress }
            },
            view.observe(\.canGoBack, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in self?.backForward[id] = (wv.canGoBack, wv.canGoForward) }
            },
            view.observe(\.canGoForward, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in self?.backForward[id] = (wv.canGoBack, wv.canGoForward) }
            },
        ]
        webViews[id] = view
        loadedIDs.insert(id)
    }

    func unload(_ id: UUID) {
        guard let view = webViews.removeValue(forKey: id) else { return }
        observers.removeValue(forKey: id)?.forEach { $0.invalidate() }
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.removeFromSuperview()
        loadedIDs.remove(id)
        progress[id] = nil
        backForward[id] = nil
    }

    private func update(_ id: UUID, _ change: (inout TabRecord) -> Void) {
        guard let i = index(id) else { return }
        var t = tabs[i]
        change(&t)
        if t != tabs[i] { tabs[i] = t }
    }

    private func webViewID(_ view: WKWebView) -> UUID? {
        webViews.first(where: { $0.value === view })?.key
    }

    /// Loads what is on screen, then trims what isn't.
    func refresh() {
        let visible = visibleIDs()
        let now = Date()
        for id in visible {
            load(id)
            lastActive[id] = now
        }
        // The idle timer for a tab starts when it leaves the screen. Capture
        // its preview now, while it is still drawn and before it can unload.
        for id in previouslyVisible.subtracting(visible) {
            lastActive[id] = now
            captureThumbnail(id)
        }
        previouslyVisible = Set(visible)
        enforceLimits()
    }

    /// Renders a small preview of a loaded tab for the tab viewer.
    func captureThumbnail(_ id: UUID) {
        guard let view = webViews[id], view.window != nil, view.bounds.width > 1, view.bounds.height > 1 else { return }
        let width: CGFloat = 180
        let scale = width / view.bounds.width
        let height = min(view.bounds.height * scale, width * 4 / 3)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { _ in
            view.drawHierarchy(
                in: CGRect(x: 0, y: 0, width: view.bounds.width * scale, height: view.bounds.height * scale),
                afterScreenUpdates: false
            )
        }
        thumbnails[id] = image.jpegData(compressionQuality: 0.6)
    }

    func captureVisibleThumbnails() {
        for id in visibleIDs() { captureThumbnail(id) }
    }

    /// Unloads least-recently-used background tabs to respect the loaded-tab
    /// cap and idle timeout. `aggressive` unloads every background tab.
    func enforceLimits(aggressive: Bool = false) {
        let visible = Set(visibleIDs())
        let now = Date()
        let idle = TimeInterval(settings.unloadAfterMinutes * 60)
        for id in Array(webViews.keys) where !visible.contains(id) {
            if aggressive || now.timeIntervalSince(lastActive[id] ?? .distantPast) > idle {
                unload(id)
            }
        }
        let background = webViews.keys
            .filter { !visible.contains($0) }
            .sorted { (lastActive[$0] ?? .distantPast) < (lastActive[$1] ?? .distantPast) }
        let allowed = max(0, settings.maxLoadedTabs - visible.count)
        for id in background.prefix(max(0, background.count - allowed)) {
            unload(id)
        }
    }

    // MARK: - History and suggestions

    private func recordVisit(_ url: URL, title: String) {
        guard let scheme = url.scheme, scheme.hasPrefix("http") else { return }
        if let i = history.firstIndex(where: { $0.url == url }) {
            history[i].visits += 1
            history[i].last = Date()
            if !title.isEmpty { history[i].title = title }
        } else {
            history.append(HistoryEntry(url: url, title: title, visits: 1, last: Date()))
        }
        if history.count > 1500 {
            history = Array(rankedHistory().prefix(1000))
        }
        historyDirty = true
    }

    private func setHistoryTitle(_ title: String, for url: URL) {
        guard let i = history.firstIndex(where: { $0.url == url }), history[i].title != title else { return }
        history[i].title = title
        historyDirty = true
    }

    /// Most useful first: visited often and recently (same ranking as Windows).
    private func rankedHistory() -> [HistoryEntry] {
        let now = Date()
        func score(_ h: HistoryEntry) -> Double {
            let days = now.timeIntervalSince(h.last) / 86_400
            return Double(h.visits).squareRoot() / (1 + days * 0.25)
        }
        return history.sorted { score($0) > score($1) }
    }

    /// Address bar suggestions: go to / search, open tabs, then history.
    func suggestions(for input: String, newTab: Bool) -> [Suggestion] {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var out: [Suggestion] = []
        if q.isEmpty || (!newTab && q == activeTab?.url.absoluteString) {
            for h in rankedHistory().prefix(6) {
                out.append(Suggestion(kind: .history, title: h.title.isEmpty ? h.url.absoluteString : h.title, url: h.url, input: h.url.absoluteString))
            }
            return out
        }
        let lower = q.lowercased()
        if AddressParser.isAddress(q), let url = AddressParser.url(from: q, engine: settings.searchEngine) {
            out.append(Suggestion(kind: .go, title: q, url: url, input: q))
        }
        out.append(Suggestion(kind: .search, title: q, url: nil, input: q))
        let open = (essentials + pinnedTabs + regularTabs)
            .filter { $0.id != activeTabID && ($0.title + " " + $0.url.absoluteString).lowercased().contains(lower) }
            .prefix(3)
        for t in open {
            out.append(Suggestion(kind: .tab(t.id), title: t.displayTitle, url: t.url, input: t.url.absoluteString))
        }
        var seen = Set(open.map(\.url))
        for h in rankedHistory() where out.count < 9 {
            guard !seen.contains(h.url), (h.title + " " + h.url.absoluteString).lowercased().contains(lower) else { continue }
            seen.insert(h.url)
            out.append(Suggestion(kind: .history, title: h.title.isEmpty ? h.url.absoluteString : h.title, url: h.url, input: h.url.absoluteString))
        }
        return out
    }

    func pick(_ s: Suggestion, newTab: Bool) {
        if case .tab(let id) = s.kind {
            select(id)
        } else {
            go(s.input, newTab: newTab)
        }
    }

    private func settingsChanged(from old: BrowserSettings) {
        AppFont.current = settings.font
        if old.forceDark != settings.forceDark {
            for (id, view) in webViews {
                installScripts(view.configuration.userContentController, page: Shared.contentJS)
                view.overrideUserInterfaceStyle = settings.forceDark ? .dark : .unspecified
                if visibleIDs().contains(id) { view.reload() }
            }
        }
        // Shortcuts and site font apply to open pages right away.
        if old.keybinds != settings.keybinds || old.font != settings.font || old.fontOnSites != settings.fontOnSites {
            let script = Shared.pageSetupScript(settings) + "window.__oxygenApplyFont&&__oxygenApplyFont();"
            for view in webViews.values {
                installScripts(view.configuration.userContentController, page: Shared.contentJS)
                view.evaluateJavaScript(script, completionHandler: nil)
            }
        }
        if old.blockAds != settings.blockAds, let list = ruleList {
            for view in webViews.values {
                if settings.blockAds {
                    view.configuration.userContentController.add(list)
                } else {
                    view.configuration.userContentController.removeAllContentRuleLists()
                }
            }
        }
        enforceLimits()
    }

    // MARK: - Tabs

    func select(_ id: UUID) {
        guard let t = tab(id) else { return }
        if !t.essential { activeWorkspace = t.workspaceID }
        activeTabs[activeWorkspace] = id
        showSidebar = false
        peek = false
        refresh()
    }

    /// Ranked history for the sidebar's address bar suggestions.
    func suggestionHistory() -> [HistoryEntry] {
        Array(rankedHistory().prefix(300))
    }

    @discardableResult
    func openTab(_ url: URL, foreground: Bool) -> UUID {
        let record = TabRecord(url: url, title: url.host ?? "", workspaceID: activeWorkspace)
        if let active = activeTabID, let i = index(active), !tabs[i].essential {
            tabs.insert(record, at: i + 1)
        } else {
            tabs.append(record)
        }
        // Background tabs stay unloaded until you look at them.
        if foreground { select(record.id) }
        return record.id
    }

    func go(_ input: String, newTab: Bool) {
        guard let url = AddressParser.url(from: input, engine: settings.searchEngine) else { return }
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !AddressParser.isAddress(q) {
            searches.removeAll { $0.caseInsensitiveCompare(q) == .orderedSame }
            searches.insert(q, at: 0)
            if searches.count > 500 { searches.removeLast(searches.count - 500) }
            searchesDirty = true
        }
        if newTab || activeTabID == nil {
            openTab(url, foreground: true)
        } else if let id = activeTabID {
            update(id) { $0.url = url }
            if let view = webViews[id] {
                view.load(URLRequest(url: url))
            } else {
                refresh()
            }
        }
    }

    func close(_ id: UUID) {
        guard let i = index(id) else { return }
        for (ws, active) in activeTabs where active == id {
            let list = orderedIDs(in: ws)
            let pos = list.firstIndex(of: id) ?? 0
            let next = pos + 1 < list.count ? list[pos + 1] : (pos > 0 ? list[pos - 1] : nil)
            activeTabs[ws] = next
        }
        closedTabs.append(tabs[i])
        if closedTabs.count > 25 { closedTabs.removeFirst() }
        unload(id)
        tabs.remove(at: i)
        thumbnails[id] = nil
        if isInSplit(id) { split = nil }
        refresh()
    }

    func closeActive() {
        if let id = activeTabID { close(id) }
    }

    /// Closes every unpinned tab in the current workspace (the Clear button).
    func clearTabs() {
        let ids = regularTabs.map(\.id)
        guard !ids.isEmpty else { return }
        for id in ids {
            if let t = tab(id) { closedTabs.append(t) }
            unload(id)
            thumbnails[id] = nil
        }
        if closedTabs.count > 25 { closedTabs.removeFirst(closedTabs.count - 25) }
        tabs.removeAll { ids.contains($0.id) }
        if activeTabID == nil { activeTabs[activeWorkspace] = orderedTabIDs.first }
        if let pair = split, !pair.allSatisfy({ tab($0) != nil }) { split = nil }
        refresh()
    }

    /// iPad: toggles the sidebar between full width and a strip of favicons.
    /// The sidebar button, as on Windows. On iPhone the full sidebar doesn't
    /// fit beside the page, so the button slides it over the page instead.
    func toggleCollapsed() {
        if narrow && !compact {
            peek.toggle()
        } else if compact {
            compact = false
            settings.collapsed = true
        } else {
            settings.collapsed.toggle()
        }
    }

    func setPeek(_ on: Bool) {
        if peek != on { peek = on }
    }

    func reloadTab(_ id: UUID) {
        webViews[id]?.reload()
    }

    /// Drag-and-drop reordering from the sidebar (same rules as Windows).
    func moveTab(_ id: UUID, before: UUID?, section: String) {
        guard before != id, let i = index(id) else { return }
        var t = tabs.remove(at: i)
        if section == "essentials" {
            t.essential = true
            t.pinned = false
        } else {
            t.essential = false
            t.pinned = section == "pinned"
            t.workspaceID = activeWorkspace
        }
        t.syncPin()
        let pos = before.flatMap { b in tabs.firstIndex { $0.id == b } } ?? tabs.count
        tabs.insert(t, at: pos)
    }

    /// Goes back to the page a pinned tab or Essential was pinned on.
    func resetPin(_ id: UUID) {
        guard let pinned = tab(id)?.pinnedURL else { return }
        update(id) { $0.url = pinned }
        if let view = webViews[id] { view.load(URLRequest(url: pinned)) } else { select(id) }
    }

    /// Makes the tab's current page its pinned page.
    func setPinURL(_ id: UUID) {
        update(id) { $0.pinnedURL = $0.url }
    }

    /// Messages from a page's injected script (shared with Windows).
    private func contentMessage(_ id: UUID, _ body: String) {
        guard let data = body.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        switch msg["t"] as? String {
        case "key": chrome.handleKey(msg["k"] as? String ?? "")
        case "glance":
            if let s = msg["url"] as? String, let url = URL(string: s) { openGlance(url) }
        case "openTab":
            if let s = msg["url"] as? String, let url = URL(string: s) {
                openTab(url, foreground: !(msg["background"] as? Bool ?? false))
            }
        case "url":
            if let s = msg["url"] as? String, let url = URL(string: s), tab(id)?.url != url {
                recordVisit(url, title: tab(id)?.title ?? "")
                update(id) { $0.url = url }
            }
        default: break
        }
    }

    func reopenClosed() {
        guard var t = closedTabs.popLast() else { return }
        if !workspaces.contains(where: { $0.id == t.workspaceID }) { t.workspaceID = activeWorkspace }
        tabs.append(t)
        select(t.id)
    }

    private func orderedIDs(in ws: UUID) -> [UUID] {
        let ess = tabs.filter(\.essential)
        let pinned = tabs.filter { !$0.essential && $0.pinned && $0.workspaceID == ws }
        let rest = tabs.filter { !$0.essential && !$0.pinned && $0.workspaceID == ws }
        return (ess + pinned + rest).map(\.id)
    }

    func cycleTab(_ step: Int) {
        let list = orderedTabIDs
        guard !list.isEmpty else { return }
        let pos = activeTabID.flatMap { list.firstIndex(of: $0) } ?? -step
        let next = ((pos + step) % list.count + list.count) % list.count
        select(list[next])
    }

    func togglePin(_ id: UUID) {
        update(id) { $0.pinned.toggle(); $0.essential = false; $0.syncPin() }
    }

    func toggleEssential(_ id: UUID) {
        let ws = activeWorkspace
        update(id) {
            $0.essential.toggle()
            $0.pinned = false
            if !$0.essential { $0.workspaceID = ws }
            $0.syncPin()
        }
    }

    func duplicate(_ id: UUID) {
        if let t = tab(id) { openTab(t.url, foreground: false) }
    }

    func move(_ id: UUID, toWorkspace ws: UUID) {
        if activeTabID == id {
            let list = orderedTabIDs
            let pos = list.firstIndex(of: id) ?? 0
            activeTabs[activeWorkspace] = pos + 1 < list.count ? list[pos + 1] : (pos > 0 ? list[pos - 1] : nil)
        }
        update(id) { $0.workspaceID = ws; $0.pinned = false }
        if isInSplit(id) { split = nil }
        refresh()
    }

    enum Section { case pinned, regular }

    /// Reorders tabs within the pinned or regular list of the active workspace.
    func move(section: Section, from offsets: IndexSet, to destination: Int) {
        var list = section == .pinned ? pinnedTabs : regularTabs
        list.move(fromOffsets: offsets, toOffset: destination)
        let ids = Set(list.map(\.id))
        guard let firstSlot = tabs.firstIndex(where: { ids.contains($0.id) }) else { return }
        tabs.removeAll { ids.contains($0.id) }
        tabs.insert(contentsOf: list, at: min(firstSlot, tabs.count))
    }

    // MARK: - Split view

    func splitWith(_ id: UUID) {
        guard let active = activeTabID, active != id else { return }
        split = [active, id]
        refresh()
    }

    func toggleSplit() {
        guard let active = activeTabID else { return }
        if isInSplit(active) {
            split = nil
        } else {
            let list = orderedTabIDs
            let pos = list.firstIndex(of: active) ?? 0
            let other = pos + 1 < list.count ? list[pos + 1] : (pos > 0 ? list[pos - 1] : nil)
            guard let other else { return }
            split = [active, other]
        }
        refresh()
    }

    func unsplit() {
        split = nil
        refresh()
    }

    /// Makes one pane of a split the focused one (the address bar follows it).
    func focusPane(_ id: UUID) {
        activeTabs[activeWorkspace] = id
        refresh()
    }

    // MARK: - Workspaces

    func switchWorkspace(_ id: UUID) {
        activeWorkspace = id
        refresh()
    }

    func cycleWorkspace(_ step: Int) {
        guard let pos = workspaces.firstIndex(where: { $0.id == activeWorkspace }) else { return }
        let n = workspaces.count
        switchWorkspace(workspaces[((pos + step) % n + n) % n].id)
    }

    func addWorkspace(name: String, icon: String, colorHex: String) {
        let ws = Workspace(
            name: name.isEmpty ? "Workspace \(workspaces.count + 1)" : name,
            icon: icon,
            colorHex: colorHex
        )
        workspaces.append(ws)
        switchWorkspace(ws.id)
    }

    func editWorkspace(_ id: UUID, name: String, icon: String, colorHex: String) {
        guard let i = workspaces.firstIndex(where: { $0.id == id }) else { return }
        if !name.isEmpty { workspaces[i].name = name }
        workspaces[i].icon = icon
        workspaces[i].colorHex = colorHex
    }

    func deleteWorkspace(_ id: UUID) {
        guard workspaces.count > 1 else { return }
        for t in tabs where !t.essential && t.workspaceID == id {
            unload(t.id)
            thumbnails[t.id] = nil
        }
        tabs.removeAll { !$0.essential && $0.workspaceID == id }
        workspaces.removeAll { $0.id == id }
        activeTabs[id] = nil
        if let pair = split, !pair.allSatisfy({ tab($0) != nil }) { split = nil }
        if activeWorkspace == id { activeWorkspace = workspaces[0].id }
        refresh()
    }

    // MARK: - Navigation

    func goBack() { activeTabID.flatMap { webViews[$0] }?.goBack() }
    func goForward() { activeTabID.flatMap { webViews[$0] }?.goForward() }
    func reload() { activeTabID.flatMap { webViews[$0] }?.reload() }

    /// Focuses the sidebar's address bar, sliding the sidebar out first when
    /// it is collapsed or hidden (same as Ctrl+T on Windows).
    func requestAddress(newTab: Bool) {
        if mode != "expanded" { peek = true }
        chrome.focusAddress(newTab: newTab)
    }

    func openGlance(_ url: URL) {
        glance = GlanceItem(url: url)
    }

    func clearBrowsingData() {
        WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) {}
    }

    /// Same choices as the Windows Privacy settings.
    func clearData(_ kind: String) {
        let store = WKWebsiteDataStore.default()
        switch kind {
        case "history":
            history.removeAll()
            historyDirty = true
            privacyStatus = "History cleared."
        case "searches":
            searches.removeAll()
            searchesDirty = true
            privacyStatus = "Search history cleared."
        case "cache":
            let types: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache]
            store.removeData(ofTypes: types, modifiedSince: .distantPast) { [weak self] in
                Task { @MainActor in self?.privacyStatus = "Cache cleared." }
            }
        case "cookies":
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
                Task { @MainActor in self?.privacyStatus = "Cookies and site data cleared. You may need to sign in to sites again." }
            }
        default: break
        }
    }

    // MARK: - Persistence

    func save() {
        Persistence.save(SessionData(
            workspaces: workspaces,
            tabs: tabs,
            activeWorkspace: activeWorkspace,
            activeTabs: activeTabs,
            split: split,
            settings: settings,
            compact: compact
        ))
        if historyDirty {
            Persistence.saveHistory(history)
            historyDirty = false
        }
        if searchesDirty {
            Persistence.saveSearches(searches)
            searchesDirty = false
        }
    }
}

// MARK: - WebKit delegates

extension BrowserStore: WKNavigationDelegate, WKUIDelegate {
    /// Links that ask for a new window open as tabs instead.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // Pop-ups that ask for a size (sign-in windows like "Sign in with
        // Google") get a real web view connected to their opener, shown as a
        // tab, so they can report back. Other new-window links open in front.
        if windowFeatures.width != nil || windowFeatures.height != nil {
            let view = WKWebView(frame: .zero, configuration: configuration)
            view.allowsBackForwardNavigationGestures = true
            view.navigationDelegate = self
            view.uiDelegate = self
            let url = navigationAction.request.url ?? URL(string: "about:blank")!
            let record = TabRecord(url: url, title: url.host ?? "", workspaceID: activeWorkspace)
            tabs.append(record)
            attach(record.id, view)
            select(record.id)
            return view
        }
        if let url = navigationAction.request.url {
            openTab(url, foreground: true)
        }
        return nil
    }

    /// A pop-up closed itself (e.g. after signing in): close its tab.
    func webViewDidClose(_ webView: WKWebView) {
        if let id = webViewID(webView) { close(id) }
    }

    /// iOS killed the page's process to reclaim memory.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let id = webViewID(webView) else {
            webView.reload()
            return
        }
        if visibleIDs().contains(id) {
            webView.reload()
        } else {
            unload(id)
        }
    }

    /// Long-press menu on links: Glance, open in a new tab, split, copy.
    func webView(
        _ webView: WKWebView,
        contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
        completionHandler: @escaping (UIContextMenuConfiguration?) -> Void
    ) {
        guard let url = elementInfo.linkURL else {
            completionHandler(nil)
            return
        }
        let config = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [
                UIAction(title: "Glance", image: UIImage(systemName: "eye")) { [weak self] _ in
                    Task { @MainActor in self?.openGlance(url) }
                },
                UIAction(title: "Open in New Tab", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
                    Task { @MainActor in self?.openTab(url, foreground: false) }
                },
                UIAction(title: "Open in Split View", image: UIImage(systemName: "rectangle.split.2x1")) { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        let active = self.activeTabID
                        let id = self.openTab(url, foreground: false)
                        if active != nil { self.splitWith(id) }
                    }
                },
                UIAction(title: "Copy Link", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.url = url
                },
            ])
        }
        completionHandler(config)
    }
}
