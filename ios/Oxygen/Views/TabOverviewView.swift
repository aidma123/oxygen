import SwiftUI

/// Grid of the current workspace's tabs with page previews.
struct TabOverviewView: View {
    @EnvironmentObject private var store: BrowserStore
    @Environment(\.dismiss) private var dismiss
    @State private var editor: WorkspaceEditor.Target?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if !store.essentials.isEmpty {
                        section("Essentials", tabs: store.essentials)
                    }
                    if !store.pinnedTabs.isEmpty {
                        section("Pinned", tabs: store.pinnedTabs)
                    }
                    if store.regularTabs.isEmpty && store.pinnedTabs.isEmpty {
                        empty
                    } else if !store.regularTabs.isEmpty {
                        section(store.pinnedTabs.isEmpty ? nil : "Tabs", tabs: store.regularTabs)
                    }
                }
                .padding(16)
                .animation(.spring(response: 0.32, dampingFraction: 0.86), value: store.orderedTabIDs)
            }
            .background(Color.oxygenFrame(accent: store.accentColor).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { workspaceSwitcher }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .bottomBar) {
                    Text("\(store.pinnedTabs.count + store.regularTabs.count) tabs")
                        .font(.app(.footnote))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button {
                        dismiss()
                        store.requestAddress(newTab: true)
                    } label: {
                        Label("New Tab", systemImage: "plus")
                    }
                }
            }
        }
        .tint(store.accentColor)
        .sheet(item: $editor) { WorkspaceEditor(target: $0).environmentObject(store) }
    }

    private var workspaceSwitcher: some View {
        Menu {
            ForEach(store.workspaces) { ws in
                Button { store.switchWorkspace(ws.id) } label: {
                    Label(ws.name, systemImage: WorkspaceStyle.symbol(for: ws.icon))
                }
            }
            Divider()
            Button { editor = .new } label: { Label("New Workspace", systemImage: "plus") }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: WorkspaceStyle.symbol(for: store.activeWorkspaceModel.icon))
                    .foregroundColor(.accentColor)
                Text(store.activeWorkspaceModel.name).font(.app(.headline)).foregroundColor(.primary)
                Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundColor(.secondary)
            }
        }
    }

    private func section(_ title: String?, tabs: [TabRecord]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title.uppercased())
                    .font(.app(.caption, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.leading, 4)
            }
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(tabs) { tab in
                    TabCard(tab: tab) {
                        store.select(tab.id)
                        dismiss()
                    }
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.on.square")
                .font(.system(size: 34, weight: .light))
                .foregroundColor(.accentColor)
            Text("No tabs in \(store.activeWorkspaceModel.name)")
                .font(.app(.headline))
            Text("Open a new tab to get started.")
                .font(.app(.subheadline))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}

/// One tab: page preview (or favicon when there is none), title and close button.
struct TabCard: View {
    @EnvironmentObject private var store: BrowserStore
    let tab: TabRecord
    let open: () -> Void

    var body: some View {
        let active = store.activeTabID == tab.id
        Button(action: open) {
            VStack(spacing: 0) {
                preview
                    .frame(maxWidth: .infinity)
                    .aspectRatio(3 / 4, contentMode: .fit)
                    .clipped()
                HStack(spacing: 8) {
                    FaviconView(tab: tab, size: 14)
                    Text(tab.displayTitle)
                        .font(.app(.caption, weight: .medium))
                        .lineLimit(1)
                        .foregroundColor(.primary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(Color.oxygenSelected)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(active ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: active ? 2.5 : 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        }
        .buttonStyle(CardPressStyle())
        .overlay(alignment: .topTrailing) {
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { store.close(tab.id) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.black.opacity(0.45)))
            }
            .padding(8)
        }
        .contextMenu { TabMenu(tab: tab) }
    }

    @ViewBuilder
    private var preview: some View {
        if let data = store.thumbnails[tab.id], let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            ZStack {
                Color(.systemBackground)
                VStack(spacing: 10) {
                    FaviconView(tab: tab, size: 36)
                    Text(tab.url.host ?? "")
                        .font(.app(.caption2))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                }
            }
        }
    }
}

private struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
