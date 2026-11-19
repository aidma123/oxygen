import Foundation
import SwiftUI
import UIKit

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

struct BrowserSettings: Codable, Equatable {
    var searchEngine: SearchEngine = .duckduckgo
    /// Tabs kept loaded at once, including the ones on screen.
    var maxLoadedTabs = 3
    /// Background tabs are unloaded after this many minutes.
    var unloadAfterMinutes = 10
    var blockAds = true
    /// "light", "dark" or nil for the system setting. Optional so sessions
    /// saved by older versions still load.
    var theme: String?

    var colorScheme: ColorScheme? {
        switch theme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
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
    /// The soft blue frame behind the sidebar, tinted by the workspace colour.
    static func oxygenFrame(accent: Color) -> some View {
        ZStack {
            Color(UIColor { $0.userInterfaceStyle == .dark
                ? UIColor(red: 0.08, green: 0.106, blue: 0.141, alpha: 1)
                : UIColor(red: 0.914, green: 0.941, blue: 0.973, alpha: 1) })
            accent.opacity(0.08)
        }
    }
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

enum AddressParser {
    /// Turns address-bar input into a URL: the address itself or a search.
    static func url(from input: String, engine: SearchEngine) -> URL? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let lower = s.lowercased()
        let schemes = ["http://", "https://", "about:", "file://", "data:"]
        if schemes.contains(where: { lower.hasPrefix($0) }), let u = URL(string: s) {
            return u
        }
        let local = lower.hasPrefix("localhost") || lower.hasPrefix("127.0.0.1")
        let looksLikeHost = !s.contains(where: { $0.isWhitespace })
            && (s.contains(".") || local)
            && !s.hasPrefix(".") && !s.hasSuffix(".")
        if looksLikeHost, let u = URL(string: (local ? "http://" : "https://") + s) {
            return u
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
        let url = fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(session) {
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
