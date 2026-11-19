import SwiftUI

/// Same sections and options as the Windows settings panel, where they apply.
struct SettingsView: View {
    @EnvironmentObject private var store: BrowserStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var memoryMB = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("App memory", value: "\(memoryMB) MB")
                        Text("Web pages run in separate processes that iOS manages. The tab limit below keeps their total low.")
                            .font(.app(.caption))
                            .foregroundColor(.secondary)
                    }
                    Stepper("Tabs kept loaded: \(store.settings.maxLoadedTabs)",
                            value: $store.settings.maxLoadedTabs, in: 1...10)
                    Stepper("Unload idle tabs after \(store.settings.unloadAfterMinutes) min",
                            value: $store.settings.unloadAfterMinutes, in: 1...120)
                    Button("Unload background tabs now") {
                        store.enforceLimits(aggressive: true)
                        memoryMB = MemoryInfo.footprintMB()
                    }
                } header: {
                    Text("Memory")
                }

                Section("Appearance") {
                    Picker("Theme", selection: $store.settings.theme) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    Picker("Font", selection: $store.settings.font) {
                        ForEach(AppFont.choices) { choice in
                            Text(choice.name)
                                .font(AppFont.font(.body, id: choice.id))
                                .tag(choice.id)
                        }
                    }
                    Toggle(isOn: $store.settings.forceDark) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Force dark mode on websites")
                            Text("Darkens sites that have no dark theme")
                                .font(.app(.caption))
                                .foregroundColor(.secondary)
                        }
                    }
                    Toggle(isOn: $store.compact) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Compact mode")
                            Text(hSize == .regular ? "Hide the sidebar; open it from the toolbar" : "Hide the sidebar until you open it")
                                .font(.app(.caption))
                                .foregroundColor(.secondary)
                        }
                    }
                    if hSize == .regular {
                        Toggle("Collapse sidebar to icons", isOn: $store.settings.collapsed)
                    }
                }

                Section("Browsing") {
                    Picker("Search engine", selection: $store.settings.searchEngine) {
                        ForEach(SearchEngine.allCases) { Text($0.name).tag($0) }
                    }
                    Toggle("Block ads and trackers", isOn: $store.settings.blockAds)
                    Button("Clear browsing data", role: .destructive) { store.clearBrowsingData() }
                }

                Section {
                    shortcut("Glance at a link", "Long-press, then Glance")
                    shortcut("Open in split view", "Long-press, then Split View")
                    shortcut("Switch workspace", "Swipe the workspace bar")
                    if hSize == .regular {
                        shortcut("New tab / address bar", "⌘T / ⌘L")
                        shortcut("Close / reopen tab", "⌘W / ⌘⇧T")
                        shortcut("Next / previous tab", "⌃Tab / ⌃⇧Tab")
                        shortcut("Switch workspace", "⌘⌥← / ⌘⌥→")
                        shortcut("Collapse sidebar", "⌘⌥S")
                        shortcut("Compact mode", "⌘⌥C")
                        shortcut("Split view", "⌘⌥V")
                        shortcut("Add to Essentials", "⌘⇧E")
                        shortcut("Show all tabs", "⌘⇧\\")
                    }
                } header: {
                    Text(hSize == .regular ? "Gestures and keyboard shortcuts" : "Gestures")
                }
            }
            .font(.app(.body))
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .onAppear { memoryMB = MemoryInfo.footprintMB() }
        }
        .tint(store.accentColor)
        .preferredColorScheme(store.settings.colorScheme)
    }

    private func shortcut(_ action: String, _ keys: String) -> some View {
        LabeledContent(action) {
            Text(keys).font(.app(.subheadline)).foregroundColor(.secondary)
        }
    }
}
