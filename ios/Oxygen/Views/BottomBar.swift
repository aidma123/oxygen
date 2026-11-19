import SwiftUI

/// Address bar and navigation controls at the bottom of the screen.
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

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.clear).frame(height: 2)
                if let p = store.activeProgress, p > 0, p < 1 {
                    GeometryReader { geo in
                        Rectangle().fill(Color.accentColor).frame(width: geo.size.width * p, height: 2)
                    }
                    .frame(height: 2)
                }
            }
            HStack(spacing: 16) {
                if !focused {
                    Button {
                        // iPad: show/hide the docked sidebar (compact mode). iPhone: open the drawer.
                        if hSize == .regular { store.compact.toggle() } else { store.showSidebar.toggle() }
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                    Button { store.goBack() } label: { Image(systemName: "chevron.left") }
                        .disabled(!store.canGoBack)
                }
                addressField
                if focused {
                    Button("Cancel") { focused = false }
                } else {
                    Button { store.goForward() } label: { Image(systemName: "chevron.right") }
                        .disabled(!store.canGoForward)
                    tabsButton
                    menu
                }
            }
            .font(.system(size: 18, weight: .medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.bar)
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
        HStack(spacing: 6) {
            Image(systemName: store.activeTab?.url.scheme == "https" && !focused ? "lock.fill" : "magnifyingglass")
                .font(.caption)
                .foregroundColor(.secondary)
            TextField("Search or enter address", text: $text)
                .focused($focused)
                .keyboardType(.webSearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .multilineTextAlignment(focused ? .leading : .center)
                .font(.system(size: 16))
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
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
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
                .frame(width: 23, height: 23)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(lineWidth: 1.8))
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
            Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }
}
