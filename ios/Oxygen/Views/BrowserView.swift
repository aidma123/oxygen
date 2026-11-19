import SwiftUI

struct BrowserView: View {
    @EnvironmentObject private var store: BrowserStore
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var showSettings = false

    /// On iPad the sidebar stays docked unless compact mode is on.
    private var dockedSidebar: Bool { hSize == .regular && !store.compact }

    var body: some View {
        HStack(spacing: 0) {
            if dockedSidebar {
                SidebarView(showSettings: $showSettings)
                    .frame(width: 300)
                Divider()
            }
            VStack(spacing: 0) {
                PagesView()
                BottomBar(showSettings: $showSettings)
            }
        }
        .overlay {
            if !dockedSidebar && store.showSidebar {
                drawer
            }
        }
        .animation(.easeOut(duration: 0.22), value: store.showSidebar)
        .animation(.easeOut(duration: 0.22), value: store.compact)
        .sheet(item: $store.glance) { item in
            GlanceView(item: item, store: store)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(store)
        }
        .fullScreenCover(isPresented: $store.showTabs) {
            TabOverviewView().environmentObject(store)
        }
        .background(shortcuts)
        .tint(store.accentColor)
        .preferredColorScheme(store.settings.colorScheme)
    }

    private var drawer: some View {
        ZStack(alignment: .leading) {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture { store.showSidebar = false }
                .transition(.opacity)
            SidebarView(showSettings: $showSettings)
                .frame(width: 320)
                .background(Color(.systemBackground).ignoresSafeArea())
                .transition(.move(edge: .leading))
                .gesture(DragGesture().onEnded { if $0.translation.width < -60 { store.showSidebar = false } })
        }
    }

    /// Hardware keyboard shortcuts (iPad).
    private var shortcuts: some View {
        Group {
            Button("New Tab") { store.requestAddress(newTab: true) }
                .keyboardShortcut("t", modifiers: .command)
            Button("Address") { store.requestAddress(newTab: false) }
                .keyboardShortcut("l", modifiers: .command)
            Button("Close Tab") { store.closeActive() }
                .keyboardShortcut("w", modifiers: .command)
            Button("Reopen Tab") { store.reopenClosed() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("Reload") { store.reload() }
                .keyboardShortcut("r", modifiers: .command)
            Button("Next Tab") { store.cycleTab(1) }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("Previous Tab") { store.cycleTab(-1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            Button("Next Workspace") { store.cycleWorkspace(1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Previous Workspace") { store.cycleWorkspace(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Split View") { store.toggleSplit() }
                .keyboardShortcut("v", modifiers: [.command, .option])
            Button("Compact Mode") { store.compact.toggle() }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Button("Back") { store.goBack() }
                .keyboardShortcut("[", modifiers: .command)
            Button("Forward") { store.goForward() }
                .keyboardShortcut("]", modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The page area: one web view, or two side by side in split view.
struct PagesView: View {
    @EnvironmentObject private var store: BrowserStore

    var body: some View {
        GeometryReader { geo in
            let ids = store.visibleIDs()
            let wide = geo.size.width > geo.size.height
            let layout = wide ? AnyLayout(HStackLayout(spacing: 3)) : AnyLayout(VStackLayout(spacing: 3))
            if ids.isEmpty {
                StartView()
            } else {
                layout {
                    ForEach(ids, id: \.self) { id in
                        pane(id, split: ids.count > 1)
                    }
                }
                .background(Color(.separator))
            }
        }
    }

    @ViewBuilder
    private func pane(_ id: UUID, split: Bool) -> some View {
        ZStack(alignment: .topTrailing) {
            if let view = store.loadedWebView(id) {
                WebViewContainer(webView: view)
            } else {
                Color(.systemBackground)
            }
            if split {
                let focused = store.activeTabID == id
                Button {
                    store.focusPane(id)
                } label: {
                    Text(store.tab(id)?.displayTitle ?? "")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(focused ? Color.accentColor : Color(.secondarySystemBackground)))
                        .foregroundColor(focused ? .white : .primary)
                        .frame(maxWidth: 180)
                }
                .padding(8)
            }
        }
    }
}

struct StartView: View {
    @EnvironmentObject private var store: BrowserStore

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: WorkspaceStyle.symbol(for: store.activeWorkspaceModel.icon))
                .font(.system(size: 34, weight: .light))
                .foregroundColor(.accentColor)
            Text(store.activeWorkspaceModel.name)
                .font(.title3.weight(.semibold))
            Text("No tabs open in this workspace.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Button {
                store.requestAddress(newTab: true)
            } label: {
                Label("New Tab", systemImage: "plus")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .padding(.top, 6)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.oxygenFrame(accent: store.accentColor))
    }
}
