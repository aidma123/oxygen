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

    private var webViews: [UUID: WKWebView] = [:]
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

        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.enforceLimits() }
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

    func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
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
        return view
    }

    private func load(_ id: UUID) {
        guard webViews[id] == nil, let record = tab(id) else { return }
        let view = makeWebView()
        observers[id] = [
            view.observe(\.title, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in self?.update(id) { if let t = wv.title, !t.isEmpty { $0.title = t } } }
            },
            view.observe(\.url, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in self?.update(id) { if let u = wv.url { $0.url = u } } }
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
        view.load(URLRequest(url: record.url))
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

    private func settingsChanged(from old: BrowserSettings) {
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
        refresh()
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
        update(id) { $0.pinned.toggle(); $0.essential = false }
    }

    func toggleEssential(_ id: UUID) {
        let ws = activeWorkspace
        update(id) {
            $0.essential.toggle()
            $0.pinned = false
            if !$0.essential { $0.workspaceID = ws }
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

    func requestAddress(newTab: Bool) {
        showSidebar = false
        addressRequest = AddressRequest(newTab: newTab)
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
        if let url = navigationAction.request.url {
            openTab(url, foreground: navigationAction.navigationType == .linkActivated)
        }
        return nil
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
