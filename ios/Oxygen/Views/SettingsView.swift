import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: BrowserStore
    @Environment(\.dismiss) private var dismiss
    @State private var memoryMB = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("Search") {
                    Picker("Search engine", selection: $store.settings.searchEngine) {
                        ForEach(SearchEngine.allCases) { Text($0.name).tag($0) }
                    }
                }
                Section {
                    Stepper("Keep up to \(store.settings.maxLoadedTabs) tabs loaded",
                            value: $store.settings.maxLoadedTabs, in: 1...10)
                    Stepper("Unload after \(store.settings.unloadAfterMinutes) min",
                            value: $store.settings.unloadAfterMinutes, in: 1...120)
                    Button("Unload background tabs now") {
                        store.enforceLimits(aggressive: true)
                        memoryMB = MemoryInfo.footprintMB()
                    }
                    LabeledContent("App memory", value: "\(memoryMB) MB")
                } header: {
                    Text("Memory")
                } footer: {
                    Text("Background tabs are unloaded and reload when you open them. Web pages run in separate processes that iOS manages, so the figure above covers the app itself; the loaded-tab limit is what keeps total memory low.")
                }
                Section("Privacy") {
                    Toggle("Block ads and trackers", isOn: $store.settings.blockAds)
                    Button("Clear browsing data", role: .destructive) { store.clearBrowsingData() }
                }
                Section {
                    Toggle("Compact mode", isOn: $store.compact)
                } header: {
                    Text("Layout")
                } footer: {
                    Text("Long-press a link for Glance, split view, or a background tab. On iPad, ⌘T, ⌘W, ⌘L, ⌘⇧T, ⌃Tab, ⌘⌥←/→ and ⌘⌥V work with a keyboard.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .onAppear { memoryMB = MemoryInfo.footprintMB() }
        }
    }
}
