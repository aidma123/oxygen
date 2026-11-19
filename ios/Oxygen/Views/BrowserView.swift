import SwiftUI

/// Layout shared with the Windows version: a soft blue frame, the sidebar on
/// the left (docked on iPad, a drawer on iPhone) and the page as a rounded
/// card with a small margin.
struct BrowserView: View {
    @EnvironmentObject private var store: BrowserStore
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var showSettings = false

    /// On iPad the sidebar stays docked unless compact mode is on.
    private var dockedSidebar: Bool { hSize == .regular && !store.compact }
    private var margin: CGFloat { hSize == .regular ? 8 : 6 }

    var body: some View {
        HStack(spacing: 0) {
            if dockedSidebar {
                if store.settings.collapsed {
                    SidebarRail(showSettings: $showSettings)
                        .frame(width: 56)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                } else {
                    SidebarView(showSettings: $showSettings)
                        .frame(width: 290)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            VStack(spacing: 0) {
                PagesView()
                    .padding(.leading, dockedSidebar ? 0 : margin)
                    .padding(.trailing, margin)
                    .padding(.top, 2)
                BottomBar(showSettings: $showSettings)
            }
        }
        .background(Color.oxygenFrame(accent: store.accentColor).ignoresSafeArea())
        .overlay {
            if !dockedSidebar && store.showSidebar {
                drawer
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: store.showSidebar)
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: store.compact)
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: store.settings.collapsed)
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
        .font(.app(.body))
        .tint(store.accentColor)
        .preferredColorScheme(store.settings.colorScheme)
    }

    private var drawer: some View {
        ZStack(alignment: .leading) {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { store.showSidebar = false }
                .transition(.opacity)
            SidebarView(showSettings: $showSettings)
                .frame(width: 310)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 20, x: 4)
                .padding(.vertical, 6)
                .padding(.leading, 6)
                .transition(.move(edge: .leading))
                .gesture(DragGesture().onEnded { if $0.translation.width < -60 { store.showSidebar = false } })
        }
    }

    /// Hardware keyboard shortcuts (iPad), matching the Windows ones with ⌘ for Ctrl.
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
            Button("Collapse Sidebar") { store.toggleCollapsed() }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button("Compact Mode") { store.compact.toggle() }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Button("Split View") { store.toggleSplit() }
                .keyboardShortcut("v", modifiers: [.command, .option])
            Button("Add to Essentials") { if let id = store.activeTabID { store.toggleEssential(id) } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Show All Tabs") { store.captureVisibleThumbnails(); store.showTabs = true }
                .keyboardShortcut("\\", modifiers: [.command, .shift])
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

/// The page area: one web view, or two side by side in split view. Each page
/// is its own rounded card, like on Windows.
struct PagesView: View {
    @EnvironmentObject private var store: BrowserStore
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        GeometryReader { geo in
            let ids = store.visibleIDs()
            let wide = geo.size.width > geo.size.height
            let gap: CGFloat = hSize == .regular ? 8 : 6
            let layout = wide ? AnyLayout(HStackLayout(spacing: gap)) : AnyLayout(VStackLayout(spacing: gap))
            if ids.isEmpty {
                StartView()
            } else {
                layout {
                    ForEach(ids, id: \.self) { id in
                        pane(id, split: ids.count > 1)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
                    }
                }
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
                    HStack(spacing: 6) {
                        if let tab = store.tab(id) { FaviconView(tab: tab, size: 12) }
                        Text(store.tab(id)?.displayTitle ?? "")
                            .font(.app(.caption, weight: .semibold))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(focused ? Color.accentColor : Color(.secondarySystemBackground).opacity(0.92)))
                    .foregroundColor(focused ? .white : .primary)
                    .frame(maxWidth: 190)
                }
                .padding(8)
            }
        }
    }
}

struct StartView: View {
    @EnvironmentObject private var store: BrowserStore

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: WorkspaceStyle.symbol(for: store.activeWorkspaceModel.icon))
                .font(.system(size: 30, weight: .light))
                .foregroundColor(.accentColor)
            Text(store.activeWorkspaceModel.name)
                .font(.app(.title3, weight: .semibold))
            Text("No tabs in this workspace yet.")
                .font(.app(.subheadline))
                .foregroundColor(.secondary)
            Button {
                store.requestAddress(newTab: true)
            } label: {
                Label("New Tab", systemImage: "plus")
                    .font(.app(.subheadline, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 9))
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
