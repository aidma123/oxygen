import Foundation
import SwiftUI
import UIKit
import WebKit

struct Workspace: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var icon: String
    var colorHex: String
}

struct TabRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var url: URL
    var title: String
    var workspaceID: UUID
    var pinned = false
    var essential = false
    /// The page a pinned tab or Essential was pinned on (as on Windows).
    var pinnedURL: URL?

    /// Navigated away from its pinned page.
    var away: Bool { pinnedURL != nil && pinnedURL != url }

    /// Keeps the pinned page in step with the pinned/Essential state.
    mutating func syncPin() {
        if pinned || essential {
            if pinnedURL == nil { pinnedURL = url }
        } else {
            pinnedURL = nil
        }
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        return url.host ?? "New Tab"
    }
}

enum SearchEngine: String, Codable, CaseIterable, Identifiable {
    case duckduckgo, google, bing, brave, startpage

    var id: String { rawValue }

    var name: String {
        switch self {
        case .duckduckgo: return "DuckDuckGo"
        case .google: return "Google"
        case .bing: return "Bing"
        case .brave: return "Brave Search"
        case .startpage: return "Startpage"
        }
    }

    private var base: String {
        switch self {
        case .duckduckgo: return "https://duckduckgo.com/"
        case .google: return "https://www.google.com/search"
        case .bing: return "https://www.bing.com/search"
        case .brave: return "https://search.brave.com/search"
        case .startpage: return "https://www.startpage.com/do/search"
        }
    }

    func url(for query: String) -> URL? {
        var c = URLComponents(string: base)
        c?.queryItems = [URLQueryItem(name: "q", value: query)]
        return c?.url
    }
}

/// Same options, names and defaults as the Windows version where they apply.
struct BrowserSettings: Codable, Equatable {
    var searchEngine: SearchEngine = .duckduckgo
    /// Tabs kept loaded at once, including the ones on screen.
    var maxLoadedTabs = 3
    /// Background tabs are unloaded after this many minutes.
    var unloadAfterMinutes = 10
    var blockAds = true
    /// "system", "light" or "dark".
    var theme = "system"
    /// Interface font id (see `AppFont`).
    var font = "system"
    /// Darken websites that have no dark theme of their own.
    var forceDark = false
    /// Sidebar collapsed to a strip of favicons.
    var collapsed = false
    /// Memory the app tries to stay under (it unloads background tabs above it).
    var memoryBudgetMB = 800
    /// Also use the interface font on websites.
    var fontOnSites = false
    /// Live search suggestions from the search engine while typing.
    var searchSuggestions = true
    /// Shown for parity with Windows; iOS's own AutoFill handles passwords.
    var savePasswords = true
    /// Custom shortcuts: action id -> combo ("" = unbound), as on Windows.
    var keybinds: [String: String] = [:]

    init() {}

    // Missing keys fall back to defaults, so sessions from older versions load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BrowserSettings()
        searchEngine = (try? c.decodeIfPresent(SearchEngine.self, forKey: .searchEngine)) ?? d.searchEngine
        maxLoadedTabs = (try? c.decodeIfPresent(Int.self, forKey: .maxLoadedTabs)) ?? d.maxLoadedTabs
        unloadAfterMinutes = (try? c.decodeIfPresent(Int.self, forKey: .unloadAfterMinutes)) ?? d.unloadAfterMinutes
        blockAds = (try? c.decodeIfPresent(Bool.self, forKey: .blockAds)) ?? d.blockAds
        theme = (try? c.decodeIfPresent(String.self, forKey: .theme)) ?? d.theme
        font = (try? c.decodeIfPresent(String.self, forKey: .font)) ?? d.font
        forceDark = (try? c.decodeIfPresent(Bool.self, forKey: .forceDark)) ?? d.forceDark
        collapsed = (try? c.decodeIfPresent(Bool.self, forKey: .collapsed)) ?? d.collapsed
        memoryBudgetMB = (try? c.decodeIfPresent(Int.self, forKey: .memoryBudgetMB)) ?? d.memoryBudgetMB
        fontOnSites = (try? c.decodeIfPresent(Bool.self, forKey: .fontOnSites)) ?? d.fontOnSites
        searchSuggestions = (try? c.decodeIfPresent(Bool.self, forKey: .searchSuggestions)) ?? d.searchSuggestions
        savePasswords = (try? c.decodeIfPresent(Bool.self, forKey: .savePasswords)) ?? d.savePasswords
        keybinds = (try? c.decodeIfPresent([String: String].self, forKey: .keybinds)) ?? d.keybinds
    }

    var colorScheme: ColorScheme? {
        switch theme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}

/// Files shared with the Windows version (bundled from desktop/).
enum Shared {
    static func text(_ name: String, _ ext: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return s
    }

    /// The sidebar page, with JetBrains Mono inlined exactly as on Windows.
    static let sidebarHTML: String = {
        let html = text("ui", "html")
        guard let url = Bundle.main.url(forResource: "JetBrainsMono-latin", withExtension: "woff2"),
              let font = try? Data(contentsOf: url) else { return html }
        let face = "@font-face{font-family:'JetBrains Mono';src:url(data:font/woff2;base64,\(font.base64EncodedString())) format('woff2');font-weight:100 800;font-display:block}"
        return html.replacingOccurrences(of: "/*OXYGEN_FONT_FACE*/", with: face)
    }()

    static let contentJS = text("content", "js")
    static let glanceJS = text("glance", "js")

    /// Default shortcuts, from the same keybinds.json as Windows.
    static let defaultKeyActions: [[String: String]] = {
        guard let data = text("keybinds", "json").data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return [] }
        return list
    }()

    /// Every action with the combo currently assigned to it.
    static func keyActions(_ s: BrowserSettings) -> [[String: String]] {
        defaultKeyActions.map { a in
            var a = a
            if let id = a["id"], let custom = s.keybinds[id] { a["combo"] = custom }
            return a
        }
    }

    static func action(for combo: String, _ s: BrowserSettings) -> String? {
        guard !combo.isEmpty else { return nil }
        return keyActions(s).first { $0["combo"] == combo }?["id"]
    }

    static let jetbrainsFace: String = {
        guard let url = Bundle.main.url(forResource: "JetBrainsMono-latin", withExtension: "woff2"),
              let font = try? Data(contentsOf: url) else { return "" }
        return "@font-face{font-family:'JetBrains Mono';src:url(data:font/woff2;base64,\(font.base64EncodedString())) format('woff2');font-weight:100 800;font-display:block}"
    }()

    /// Same as Windows' page setup: which keys are browser shortcuts, and
    /// the font to use on websites.
    static func pageSetupScript(_ s: BrowserSettings) -> String {
        let combos = keyActions(s).compactMap { $0["combo"] }.filter { !$0.isEmpty }
        let keys = (try? JSONSerialization.data(withJSONObject: combos)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        var script = "window.__OXYGEN_KEYS = new Set(\(keys));"
        if s.fontOnSites {
            let family: String
            switch s.font {
            case "jetbrains": family = "'JetBrains Mono', ui-monospace, monospace"
            case "georgia": family = "Georgia, serif"
            case "verdana": family = "Verdana, sans-serif"
            case "cascadia", "consolas": family = "ui-monospace, monospace"
            default: family = "-apple-system, system-ui, sans-serif"
            }
            let cfg: [String: String] = ["family": family, "face": s.font == "jetbrains" ? jetbrainsFace : ""]
            let json = (try? JSONSerialization.data(withJSONObject: cfg)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
            script += "window.__OXYGEN_SITE_FONT=\(json);"
        } else {
            script += "window.__OXYGEN_SITE_FONT=null;"
        }
        return script
    }

    /// Live search suggestions from the engine (OpenSearch JSON), same
    /// endpoints as Windows.
    static func fetchSuggestions(engine: SearchEngine, query: String) async -> [String] {
        let q = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query
        let endpoint: String
        switch engine {
        case .google: endpoint = "https://suggestqueries.google.com/complete/search?client=firefox&q=\(q)"
        case .bing: endpoint = "https://api.bing.com/osjson.aspx?query=\(q)"
        case .brave: endpoint = "https://search.brave.com/api/suggest?q=\(q)"
        case .startpage: endpoint = "https://www.startpage.com/suggestions?q=\(q)&format=opensearch"
        case .duckduckgo: endpoint = "https://duckduckgo.com/ac/?q=\(q)&type=list"
        }
        guard let url = URL(string: endpoint),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              json.count > 1, let list = json[1] as? [String] else { return [] }
        return Array(list.prefix(5))
    }

    /// Gives shared pages the same `window.ipc.postMessage` the Windows webview has.
    static let bridgeJS = """
        window.__OXYGEN_PLATFORM = 'ios';
        window.ipc = { postMessage: (m) => window.webkit.messageHandlers.ipc.postMessage(m) };
        """
}

/// Forwards script messages without the WKUserContentController retaining
/// the real handler (which would leak it).
final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    private let handler: (String, WKWebView?) -> Void
    init(_ handler: @escaping (String) -> Void) { self.handler = { body, _ in handler(body) } }
    /// Also passes the web view that sent the message.
    init(withSender handler: @escaping (String, WKWebView?) -> Void) { self.handler = handler }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? String { handler(body, message.webView) }
    }
}

struct HistoryEntry: Codable, Equatable {
    var url: URL
    var title: String
    var visits: Int
    var last: Date
}

/// Interface fonts. Ids match the Windows version where the font exists on iOS.
enum AppFont {
    struct Choice: Identifiable {
        let id: String
        let name: String
    }

    static let choices: [Choice] = [
        Choice(id: "system", name: "San Francisco"),
        Choice(id: "jetbrains", name: "JetBrains Mono"),
        Choice(id: "rounded", name: "SF Rounded"),
        Choice(id: "mono", name: "SF Mono"),
        Choice(id: "serif", name: "New York"),
        Choice(id: "georgia", name: "Georgia"),
        Choice(id: "verdana", name: "Verdana"),
    ]

    /// The selected font id; the store updates it when settings change.
    static var current = "system"

    static func font(_ style: Font.TextStyle, weight: Font.Weight = .regular, id: String = current) -> Font {
        let size = UIFont.preferredFont(forTextStyle: style.uiKit).pointSize
        switch id {
        case "jetbrains": return .custom("JetBrains Mono", size: size * 0.94, relativeTo: style).weight(weight)
        case "georgia": return .custom("Georgia", size: size, relativeTo: style).weight(weight)
        case "verdana": return .custom("Verdana", size: size * 0.92, relativeTo: style).weight(weight)
        case "rounded": return .system(style, design: .rounded).weight(weight)
        case "mono": return .system(style, design: .monospaced).weight(weight)
        case "serif": return .system(style, design: .serif).weight(weight)
        default: return .system(style).weight(weight)
        }
    }
}

extension Font {
    /// A text style in the user's chosen interface font.
    static func app(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        AppFont.font(style, weight: weight)
    }
}

extension Font.TextStyle {
    var uiKit: UIFont.TextStyle {
        switch self {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        default: return .body
        }
    }
}

/// Workspace icons (shared names with the Windows version) and colours.
enum WorkspaceStyle {
    static let iconOrder = [
        "home", "briefcase", "code", "book", "music", "game", "cart", "flask", "globe",
        "heart", "camera", "folder", "chat", "terminal", "leaf", "sparkle", "star", "moon",
    ]
    static let symbols: [String: String] = [
        "home": "house", "briefcase": "briefcase", "code": "chevron.left.forwardslash.chevron.right",
        "book": "book", "music": "music.note", "game": "gamecontroller", "cart": "cart",
        "flask": "flask", "globe": "globe", "heart": "heart", "camera": "camera", "folder": "folder",
        "chat": "bubble.left", "terminal": "terminal", "leaf": "leaf", "sparkle": "sparkles",
        "star": "star", "moon": "moon",
    ]
    /// Soft colours; the first is oxygen's default light blue.
    static let colors = ["#6f9fd8", "#5fb0b4", "#7fb58c", "#d6ad6c", "#d98c9c", "#9d92d8", "#8a9bb0", "#e0937a"]

    static func symbol(for icon: String) -> String { symbols[icon] ?? "globe" }
}

extension Color {
    /// The soft blue frame behind the sidebar and page card, tinted by the
    /// workspace colour. Same colours as the Windows version.
    static func oxygenFrame(accent: Color) -> some View {
        ZStack {
            Color(UIColor { $0.userInterfaceStyle == .dark
                ? UIColor(red: 0.082, green: 0.106, blue: 0.141, alpha: 1)
                : UIColor(red: 0.914, green: 0.941, blue: 0.973, alpha: 1) })
            accent.opacity(0.09)
        }
    }

    /// Background of the selected tab row / Essentials tile.
    static let oxygenSelected = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.78, green: 0.86, blue: 1, alpha: 0.1)
        : UIColor.white })
    /// Hover/idle tile background.
    static let oxygenTile = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.78, green: 0.86, blue: 1, alpha: 0.06)
        : UIColor(red: 0.16, green: 0.31, blue: 0.51, alpha: 0.065) })
    /// Address field background.
    static let oxygenField = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.78, green: 0.86, blue: 1, alpha: 0.07)
        : UIColor(white: 1, alpha: 0.65) })
}

struct SessionData: Codable {
    var workspaces: [Workspace]
    var tabs: [TabRecord]
    var activeWorkspace: UUID
    var activeTabs: [UUID: UUID]
    var split: [UUID]?
    var settings: BrowserSettings
    var compact: Bool
}

struct GlanceItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// A request for the address bar to take focus.
struct AddressRequest: Equatable {
    let id = UUID()
    let newTab: Bool
}

/// One row in the address bar suggestions.
struct Suggestion: Identifiable, Hashable {
    enum Kind: Hashable {
        case go, search, tab(UUID), history
    }
    let id = UUID()
    let kind: Kind
    let title: String
    let url: URL?
    let input: String

    var symbol: String {
        switch kind {
        case .go: return "globe"
        case .search: return "magnifyingglass"
        case .tab: return "square.on.square"
        case .history: return "clock"
        }
    }
}

enum AddressParser {
    private static let schemes = ["http://", "https://", "about:", "file://", "data:"]

    /// Whether input is an address rather than a search.
    static func isAddress(_ input: String) -> Bool {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased()
        if schemes.contains(where: { lower.hasPrefix($0) }) { return true }
        let local = lower.hasPrefix("localhost") || lower.hasPrefix("127.0.0.1")
        return !s.isEmpty && !s.contains(where: { $0.isWhitespace })
            && (s.contains(".") || local)
            && !s.hasPrefix(".") && !s.hasSuffix(".")
    }

    /// Turns address-bar input into a URL: the address itself or a search.
    static func url(from input: String, engine: SearchEngine) -> URL? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let lower = s.lowercased()
        if schemes.contains(where: { lower.hasPrefix($0) }), let u = URL(string: s) {
            return u
        }
        if isAddress(s) {
            let local = lower.hasPrefix("localhost") || lower.hasPrefix("127.0.0.1")
            if let u = URL(string: (local ? "http://" : "https://") + s) { return u }
        }
        return engine.url(for: s)
    }
}

enum Persistence {
    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("session.json")
    }

    static func load() -> SessionData? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SessionData.self, from: data)
    }

    static func save(_ session: SessionData) {
        write(session, to: fileURL)
    }

    static var historyURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("history.json") }

    static func loadHistory() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: historyURL) else { return [] }
        return (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
    }

    static func saveHistory(_ history: [HistoryEntry]) {
        write(history, to: historyURL)
    }

    static var searchesURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("searches.json") }

    /// Searches typed into the address bar, most recent first.
    static func loadSearches() -> [String] {
        guard let data = try? Data(contentsOf: searchesURL) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    static func saveSearches(_ searches: [String]) {
        write(searches, to: searchesURL)
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(value) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

enum MemoryInfo {
    /// This app's own memory footprint in MB (what iOS counts against the app).
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.phys_footprint / 1_048_576)
    }
}

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt64(s, radix: 16) ?? 0x7c6cf0
        self.init(
            red: Double((v >> 16) & 0xff) / 255,
            green: Double((v >> 8) & 0xff) / 255,
            blue: Double(v & 0xff) / 255
        )
    }
}
