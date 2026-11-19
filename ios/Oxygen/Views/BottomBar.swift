import SwiftUI

/// Address bar and navigation controls at the bottom of the screen. Sits on
/// the frame like the Windows toolbar, with suggestions above it while typing.
struct BottomBar: View {
    @EnvironmentObject private var store: BrowserStore
    @Environment(\.horizontalSizeClass) private var hSize
    @Binding var showSettings: Bool
    @FocusState private var focused: Bool
    @State private var text = ""
    @State private var newTabMode = false

    private var displayText: String {
        guard let tab = store.activeTab else { return "" }
        return tab.url.host.map { $0.replacingOccurrences(of: "www.", with: "", options: .anchored) } ?? tab.url.absoluteString
    }

    private var suggestions: [Suggestion] {
        focused ? store.suggestions(for: text, newTab: newTabMode) : []
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .leading) {
                Color.clear.frame(height: 2)
                if let p = store.activeProgress, p > 0, p < 1 {
                    GeometryReader { geo in
                        Capsule().fill(Color.accentColor).frame(width: geo.size.width * p, height: 2)
                    }
                    .frame(height: 2)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 12)
            .animation(.easeOut(duration: 0.2), value: store.activeProgress ?? 1)
            HStack(spacing: 14) {
                if !focused {
                    Button {
                        // iPad: collapse/expand the docked sidebar. iPhone and compact mode: open the drawer.
                        if hSize == .regular && !store.compact { store.toggleCollapsed() } else { store.showSidebar.toggle() }
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                    Button { store.goBack() } label: { Image(systemName: "arrow.left") }
                        .disabled(!store.canGoBack)
                }
                addressField
                if focused {
                    Button("Cancel") { focused = false }
                        .font(.app(.body))
                } else {
                    Button { store.goForward() } label: { Image(systemName: "arrow.right") }
                        .disabled(!store.canGoForward)
                    tabsButton
                    menu
                }
            }
            .font(.system(size: 17, weight: .regular))
            .foregroundColor(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 8)
        }
        .overlay(alignment: .top) {
            if !suggestions.isEmpty {
                suggestionList
                    .padding(.horizontal, 10)
                    .alignmentGuide(.top) { $0[.bottom] + 4 }
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
            }
        }
        .animation(.easeOut(duration: 0.16), value: focused)
        .onAppear { text = displayText }
        .onChange(of: displayText) { value in
            if !focused { text = value }
        }
        .onChange(of: focused) { isFocused in
            if isFocused {
                text = newTabMode ? "" : (store.activeTab?.url.absoluteString ?? "")
            } else {
                newTabMode = false
                text = displayText
            }
        }
        .onChange(of: store.addressRequest) { request in
            guard let request else { return }
            newTabMode = request.newTab || store.activeTabID == nil
            text = newTabMode ? "" : (store.activeTab?.url.absoluteString ?? "")
            focused = true
        }
    }

    private var addressField: some View {
        HStack(spacing: 8) {
            Image(systemName: store.activeTab?.url.scheme == "https" && !focused ? "lock" : "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary.opacity(0.8))
            TextField("Search or enter address", text: $text)
                .focused($focused)
                .keyboardType(.webSearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .font(.app(.callout))
                .foregroundColor(.primary)
                .onSubmit {
                    store.go(text, newTab: newTabMode)
                    focused = false
                }
            if focused && !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .font(.system(size: 15))
            } else if !focused && store.activeTab != nil {
                Button { store.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(focused ? Color(.systemBackground) : Color.oxygenField)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.accentColor.opacity(focused ? 0.55 : 0), lineWidth: 1)
                )
        )
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if text.trimmingCharacters(in: .whitespaces).isEmpty || (!newTabMode && text == store.activeTab?.url.absoluteString) {
                Text("Recently visited")
                    .font(.app(.caption, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
            }
            ForEach(suggestions) { s in
                Button {
                    store.pick(s, newTab: newTabMode)
                    focused = false
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: s.symbol)
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.title)
                                .font(.app(.callout))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            if case .search = s.kind {
                                Text("Search with \(store.settings.searchEngine.name)")
                                    .font(.app(.caption))
                                    .foregroundColor(.secondary)
                            } else if let host = s.url?.host {
                                Text(host)
                                    .font(.app(.caption))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        if case .tab = s.kind {
                            Text("Switch to tab")
                                .font(.app(.caption))
                                .foregroundColor(.accentColor)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.14), radius: 16, y: 4)
        )
    }

    /// Opens the tab viewer; shows how many tabs the workspace has.
    private var tabsButton: some View {
        Button {
            store.captureVisibleThumbnails()
            store.showTabs = true
        } label: {
            let count = store.pinnedTabs.count + store.regularTabs.count
            Text(count > 99 ? "99+" : "\(count)")
                .font(.system(size: count > 99 ? 9 : 12, weight: .semibold, design: .rounded))
                .frame(width: 22, height: 22)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(lineWidth: 1.6))
        }
        .accessibilityLabel("Show tabs")
    }

    private var menu: some View {
        Menu {
            Button { store.captureVisibleThumbnails(); store.showTabs = true } label: {
                Label("Show All Tabs", systemImage: "square.on.square")
            }
            Button { store.requestAddress(newTab: true) } label: { Label("New Tab", systemImage: "plus") }
            if let tab = store.activeTab {
                ShareLink(item: tab.url) { Label("Share", systemImage: "square.and.arrow.up") }
                Divider()
                Button { store.toggleEssential(tab.id) } label: {
                    Label(tab.essential ? "Remove from Essentials" : "Add to Essentials", systemImage: "star")
                }
                if !tab.essential {
                    Button { store.togglePin(tab.id) } label: {
                        Label(tab.pinned ? "Unpin Tab" : "Pin Tab", systemImage: "pin")
                    }
                }
                Button { store.toggleSplit() } label: {
                    Label(store.isInSplit(tab.id) ? "Close Split View" : "Split View", systemImage: "rectangle.split.2x1")
                }
                Divider()
                Button(role: .destructive) { store.close(tab.id) } label: { Label("Close Tab", systemImage: "xmark") }
            }
            Divider()
            Button { showSettings = true } label: { Label("Settings", systemImage: "slider.horizontal.3") }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 24, height: 24)
        }
    }
}
