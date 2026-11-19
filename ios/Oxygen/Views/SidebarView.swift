import SwiftUI

/// Zen-style vertical sidebar: Essentials, the workspace's pinned and regular
/// tabs, and the workspace switcher.
struct SidebarView: View {
    @EnvironmentObject private var store: BrowserStore
    @Binding var showSettings: Bool
    @State private var editMode: EditMode = .inactive
    @State private var editor: WorkspaceEditor.Target?
    @State private var deletingWorkspace = false

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
                        HStack(spacing: 10) {
                            Image(systemName: "plus").frame(width: 18)
                            Text("New Tab")
                        }
                        .foregroundColor(.secondary)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    ForEach(store.regularTabs) { TabRow(tab: $0) }
                        .onMove { store.move(section: .regular, from: $0, to: $1) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, $editMode)
            .animation(.easeOut(duration: 0.2), value: store.regularTabs.map(\.id))
            footer
        }
        .background(Color.oxygenFrame(accent: store.accentColor).ignoresSafeArea())
        .sheet(item: $editor) { target in
            WorkspaceEditor(target: target).environmentObject(store)
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
                    let active = store.activeTabID == tab.id
                    Button { store.select(tab.id) } label: {
                        FaviconView(tab: tab, size: 22)
                            .opacity(store.loadedIDs.contains(tab.id) ? 1 : 0.55)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(active ? Color(.systemBackground) : Color.primary.opacity(0.05))
                                    .shadow(color: .black.opacity(active ? 0.08 : 0), radius: 2, y: 1)
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
            Image(systemName: WorkspaceStyle.symbol(for: store.activeWorkspaceModel.icon))
                .foregroundColor(.accentColor)
                .frame(width: 20)
            Text(store.activeWorkspaceModel.name).font(.headline)
            Spacer()
            Menu {
                Button { editor = .edit(store.activeWorkspace) } label: {
                    Label("Edit Workspace", systemImage: "pencil")
                }
                Button {
                    editMode = editMode == .active ? .inactive : .active
                } label: {
                    Label(editMode == .active ? "Done Reordering" : "Reorder Tabs", systemImage: "arrow.up.arrow.down")
                }
                if store.workspaces.count > 1 {
                    Button(role: .destructive) { deletingWorkspace = true } label: {
                        Label("Delete Workspace", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis").foregroundColor(.secondary).frame(width: 30, height: 30)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(store.workspaces) { ws in
                        let active = ws.id == store.activeWorkspace
                        Button { store.switchWorkspace(ws.id) } label: {
                            Image(systemName: WorkspaceStyle.symbol(for: ws.icon))
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(active ? Color(hex: ws.colorHex) : .secondary)
                                .frame(width: 38, height: 38)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(active ? Color.primary.opacity(0.08) : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { editor = .edit(ws.id) } label: { Label("Edit Workspace", systemImage: "pencil") }
                        }
                    }
                }
            }
            Button { editor = .new } label: {
                Image(systemName: "plus").frame(width: 38, height: 38)
            }
            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 38, height: 38)
            }
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // Swipe left/right on the workspace bar to change workspace.
        .gesture(DragGesture(minimumDistance: 30).onEnded { value in
            if value.translation.width < -50 { store.cycleWorkspace(1) }
            if value.translation.width > 50 { store.cycleWorkspace(-1) }
        })
    }
}

/// Create or edit a workspace: name, icon and colour.
struct WorkspaceEditor: View {
    enum Target: Identifiable, Hashable {
        case new
        case edit(UUID)
        var id: String {
            switch self {
            case .new: return "new"
            case .edit(let id): return id.uuidString
            }
        }
    }

    @EnvironmentObject private var store: BrowserStore
    @Environment(\.dismiss) private var dismiss
    let target: Target
    @State private var name = ""
    @State private var icon = "home"
    @State private var color = WorkspaceStyle.colors[0]

    private var editingID: UUID? {
        if case .edit(let id) = target { return id }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Workspace \(store.workspaces.count + 1)", text: $name)
                }
                Section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                        ForEach(WorkspaceStyle.iconOrder, id: \.self) { key in
                            Button { icon = key } label: {
                                Image(systemName: WorkspaceStyle.symbol(for: key))
                                    .font(.system(size: 17))
                                    .frame(maxWidth: .infinity, minHeight: 40)
                                    .foregroundColor(icon == key ? Color(hex: color) : .secondary)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(icon == key ? Color(hex: color).opacity(0.15) : Color.clear)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("Color") {
                    HStack(spacing: 12) {
                        ForEach(WorkspaceStyle.colors, id: \.self) { hex in
                            Button { color = hex } label: {
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 26, height: 26)
                                    .overlay(Circle().stroke(Color(hex: hex), lineWidth: 2).padding(-4).opacity(color == hex ? 1 : 0))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .navigationTitle(editingID == nil ? "New Workspace" : "Edit Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editingID == nil ? "Create" : "Save") {
                        let finalName = name.trimmingCharacters(in: .whitespaces)
                        if let id = editingID {
                            store.editWorkspace(id, name: finalName, icon: icon, colorHex: color)
                        } else {
                            store.addWorkspace(name: finalName, icon: icon, colorHex: color)
                        }
                        dismiss()
                    }
                }
            }
            .onAppear {
                if let id = editingID, let ws = store.workspaces.first(where: { $0.id == id }) {
                    name = ws.name
                    icon = ws.icon
                    color = ws.colorHex
                } else {
                    let n = store.workspaces.count
                    icon = WorkspaceStyle.iconOrder[n % WorkspaceStyle.iconOrder.count]
                    color = WorkspaceStyle.colors[n % WorkspaceStyle.colors.count]
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct TabRow: View {
    @EnvironmentObject private var store: BrowserStore
    let tab: TabRecord

    var body: some View {
        let active = store.activeTabID == tab.id
        Button { store.select(tab.id) } label: {
            HStack(spacing: 10) {
                FaviconView(tab: tab, size: 16)
                    .opacity(store.loadedIDs.contains(tab.id) ? 1 : 0.55)
                Text(tab.displayTitle)
                    .lineLimit(1)
                    .foregroundColor(store.loadedIDs.contains(tab.id) ? .primary : .secondary)
                Spacer(minLength: 0)
                if store.isInSplit(tab.id) {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(active ? Color(.systemBackground) : Color.clear)
                .shadow(color: .black.opacity(active ? 0.06 : 0), radius: 2, y: 1)
                .padding(.horizontal, 8)
                .padding(.vertical, 1)
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
                        Button { store.move(tab.id, toWorkspace: ws.id) } label: {
                            Label(ws.name, systemImage: WorkspaceStyle.symbol(for: ws.icon))
                        }
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
