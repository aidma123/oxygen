import SwiftUI

/// Zen-style vertical sidebar: Essentials, the workspace's pinned and regular
/// tabs, and the workspace switcher.
struct SidebarView: View {
    @EnvironmentObject private var store: BrowserStore
    @Binding var showSettings: Bool
    @State private var editMode: EditMode = .inactive
    @State private var addingWorkspace = false
    @State private var editingWorkspace = false
    @State private var deletingWorkspace = false
    @State private var nameField = ""
    @State private var iconField = ""

    var body: some View {
        VStack(spacing: 0) {
            essentials
            header
            List {
                if !store.pinnedTabs.isEmpty {
                    Section {
                        ForEach(store.pinnedTabs) { TabRow(tab: $0) }
                            .onMove { store.move(section: .pinned, from: $0, to: $1) }
                    }
                }
                Section {
                    Button { store.requestAddress(newTab: true) } label: {
                        Label("New Tab", systemImage: "plus").foregroundColor(.secondary)
                    }
                    ForEach(store.regularTabs) { TabRow(tab: $0) }
                        .onMove { store.move(section: .regular, from: $0, to: $1) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, $editMode)
            footer
        }
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.16), Color(.secondarySystemBackground)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .alert("New Workspace", isPresented: $addingWorkspace) {
            TextField("Name", text: $nameField)
            TextField("Icon (an emoji)", text: $iconField)
            Button("Create") { store.addWorkspace(name: nameField, icon: iconField) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Edit Workspace", isPresented: $editingWorkspace) {
            TextField("Name", text: $nameField)
            TextField("Icon (an emoji)", text: $iconField)
            Button("Save") { store.editWorkspace(store.activeWorkspace, name: nameField, icon: iconField) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete \(store.activeWorkspaceModel.name) and close its tabs?",
            isPresented: $deletingWorkspace, titleVisibility: .visible
        ) {
            Button("Delete Workspace", role: .destructive) { store.deleteWorkspace(store.activeWorkspace) }
        }
    }

    @ViewBuilder
    private var essentials: some View {
        if !store.essentials.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 8)], spacing: 8) {
                ForEach(store.essentials) { tab in
                    Button { store.select(tab.id) } label: {
                        FaviconView(tab: tab, size: 24)
                            .opacity(store.loadedIDs.contains(tab.id) ? 1 : 0.5)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(store.activeTabID == tab.id ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06))
                            )
                    }
                    .buttonStyle(.plain)
                    .contextMenu { TabMenu(tab: tab) }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(store.activeWorkspaceModel.icon)
            Text(store.activeWorkspaceModel.name).font(.headline)
            Spacer()
            Menu {
                Button {
                    nameField = store.activeWorkspaceModel.name
                    iconField = store.activeWorkspaceModel.icon
                    editingWorkspace = true
                } label: { Label("Edit Workspace", systemImage: "pencil") }
                Button {
                    editMode = editMode == .active ? .inactive : .active
                } label: { Label(editMode == .active ? "Done Reordering" : "Reorder Tabs", systemImage: "arrow.up.arrow.down") }
                if store.workspaces.count > 1 {
                    Button(role: .destructive) { deletingWorkspace = true } label: {
                        Label("Delete Workspace", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle").foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(store.workspaces) { ws in
                        Button { store.switchWorkspace(ws.id) } label: {
                            Text(ws.icon)
                                .font(.system(size: 20))
                                .frame(width: 38, height: 38)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(ws.id == store.activeWorkspace ? Color.primary.opacity(0.1) : Color.clear)
                                )
                                .opacity(ws.id == store.activeWorkspace ? 1 : 0.55)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Button {
                nameField = ""
                iconField = ""
                addingWorkspace = true
            } label: {
                Image(systemName: "plus").frame(width: 38, height: 38)
            }
            Button { showSettings = true } label: {
                Image(systemName: "gearshape").frame(width: 38, height: 38)
            }
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .overlay(Divider(), alignment: .top)
        // Swipe left/right on the workspace bar to change workspace.
        .gesture(DragGesture(minimumDistance: 30).onEnded { value in
            if value.translation.width < -50 { store.cycleWorkspace(1) }
            if value.translation.width > 50 { store.cycleWorkspace(-1) }
        })
    }
}

struct TabRow: View {
    @EnvironmentObject private var store: BrowserStore
    let tab: TabRecord

    var body: some View {
        Button { store.select(tab.id) } label: {
            HStack(spacing: 10) {
                FaviconView(tab: tab, size: 18)
                Text(tab.displayTitle).lineLimit(1)
                Spacer(minLength: 0)
                if store.isInSplit(tab.id) {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
            }
            .opacity(store.loadedIDs.contains(tab.id) ? 1 : 0.55)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 10)
                .fill(store.activeTabID == tab.id ? Color.primary.opacity(0.1) : Color.clear)
                .padding(.horizontal, 6)
        )
        .listRowSeparator(.hidden)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { store.close(tab.id) } label: { Label("Close", systemImage: "xmark") }
        }
        .swipeActions(edge: .leading) {
            Button { store.togglePin(tab.id) } label: { Label(tab.pinned ? "Unpin" : "Pin", systemImage: "pin") }
                .tint(.accentColor)
        }
        .contextMenu { TabMenu(tab: tab) }
    }
}

struct TabMenu: View {
    @EnvironmentObject private var store: BrowserStore
    let tab: TabRecord

    var body: some View {
        Button { store.toggleEssential(tab.id) } label: {
            Label(tab.essential ? "Remove from Essentials" : "Add to Essentials", systemImage: "star")
        }
        if !tab.essential {
            Button { store.togglePin(tab.id) } label: {
                Label(tab.pinned ? "Unpin Tab" : "Pin Tab", systemImage: "pin")
            }
        }
        if let active = store.activeTabID, active != tab.id {
            Button { store.splitWith(tab.id) } label: {
                Label("Split View with Current Tab", systemImage: "rectangle.split.2x1")
            }
        }
        if store.isInSplit(tab.id) {
            Button { store.unsplit() } label: { Label("Close Split View", systemImage: "rectangle") }
        }
        Button { store.duplicate(tab.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        if store.loadedIDs.contains(tab.id) && !store.visibleIDs().contains(tab.id) {
            Button { store.unload(tab.id) } label: { Label("Unload (Free Memory)", systemImage: "moon.zzz") }
        }
        if !tab.essential {
            let others = store.workspaces.filter { $0.id != tab.workspaceID }
            if !others.isEmpty {
                Menu {
                    ForEach(others) { ws in
                        Button("\(ws.icon) \(ws.name)") { store.move(tab.id, toWorkspace: ws.id) }
                    }
                } label: {
                    Label("Move to Workspace", systemImage: "arrow.right.square")
                }
            }
        }
        Divider()
        Button(role: .destructive) { store.close(tab.id) } label: { Label("Close Tab", systemImage: "xmark") }
    }
}
