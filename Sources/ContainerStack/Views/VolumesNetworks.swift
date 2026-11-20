import SwiftUI

// MARK: - Volumes

struct VolumesView: View {
    @EnvironmentObject var state: AppState
    @State private var search = ""
    @State private var showCreateSheet = false
    @State private var browsing: VolumeRecord?

    private var filtered: [VolumeRecord] {
        guard !search.isEmpty else { return state.volumes }
        return state.volumes.filter { $0.name.lowercased().contains(search.lowercased()) }
    }

    /// Volume names referenced by any container mount.
    private var usedVolumeNames: Set<String> {
        var used = Set<String>()
        for c in state.containers {
            for m in c.configuration.mounts ?? [] {
                if let name = m.volumeName {
                    used.insert(name)
                }
            }
        }
        return used
    }

    var body: some View {
        NavigationStack {
            Group {
                if !state.systemState.isRunning && state.initialLoadDone {
                    ServicesStoppedState()
                } else if state.volumes.isEmpty && state.initialLoadDone {
                    EmptyState(
                        icon: "externaldrive",
                        title: "No volumes",
                        message: "Volumes provide persistent storage for containers.",
                        actionLabel: "Create Volume…"
                    ) { showCreateSheet = true }
                } else {
                    list
                }
            }
            .navigationTitle("Volumes")
            .searchable(text: $search, placement: .toolbar, prompt: "Filter volumes")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        showCreateSheet = true
                    } label: {
                        Label("Create Volume", systemImage: "plus")
                    }
                    Menu {
                        Button("Prune Unused Volumes", role: .destructive) {
                            state.perform("volumes") { try await ContainerService.pruneVolumes() }
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showCreateSheet) { CreateVolumeSheet() }
            .sheet(item: $browsing) { VolumeBrowserSheet(volume: $0) }
        }
    }

    private var list: some View {
        VolumeListContent(volumes: filtered, usedNames: usedVolumeNames, browse: { browsing = $0 })
            .refreshIndicator(state.isRefreshing)
    }
}

struct VolumeListContent: View {
    @EnvironmentObject var state: AppState
    let volumes: [VolumeRecord]
    let usedNames: Set<String>
    var scrollable = true
    var browse: (VolumeRecord) -> Void = { _ in }

    @State private var selection: Set<String> = []
    @State private var confirmDelete = false

    private var deleteTargets: [VolumeRecord] {
        ListSelection.targets(volumes, selected: selection, id: \.id)
    }

    var body: some View {
        if scrollable {
            SelectableList(
                selection: $selection,
                visibleIDs: volumes.map(\.id),
                primaryAction: { id in
                    if let volume = volumes.first(where: { $0.id == id }) { browse(volume) }
                },
                deleteAction: { requestDelete() },
                content: {
                    ForEach(volumes) { volume in
                        ListRowContent {
                            VolumeRow(volume: volume, inUse: usedNames.contains(volume.name))
                        }
                        .selectableListRow()
                        .tag(volume.id)
                    }
                },
                menu: { rowMenu($0) }
            )
            .confirmationDialog(
                Text("Delete \(deleteTargets.count) Volumes?",
                     comment: "Confirmation title for deleting selected volumes — the value is the number of volumes."),
                isPresented: $confirmDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    deleteTargets.forEach { volume in
                        state.perform(volume.id) { try await ContainerService.deleteVolume(volume.name) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        } else {
            CardList(items: volumes, scrollable: false) { volume in
                HoverRow(action: { browse(volume) }) {
                    VolumeRow(volume: volume, inUse: usedNames.contains(volume.name))
                }
                .contextMenu { singleMenu(volume) }
            }
        }
    }

    private func requestDelete() {
        guard !deleteTargets.isEmpty else { return }
        confirmDelete = true
    }

    @ViewBuilder
    private func rowMenu(_ ids: Set<String>) -> some View {
        let selected = volumes.filter { ids.contains($0.id) }
        if selected.count == 1, let volume = selected.first {
            singleMenu(volume)
        } else if !selected.isEmpty {
            Button(role: .destructive) { confirmDelete = true } label: {
                Text("Delete \(selected.count) Volumes…",
                     comment: "Bulk context-menu action that asks for confirmation — the value is the number of selected volumes.")
            }
        }
    }

    @ViewBuilder
    private func singleMenu(_ volume: VolumeRecord) -> some View {
        Button("Browse Files…") { browse(volume) }
        Button("Copy Source Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(volume.source ?? "", forType: .string)
        }
        Button("Reveal in Finder") {
            if let src = volume.source {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: src)])
            }
        }
        Divider()
        Button("Delete", role: .destructive) {
            state.perform(volume.id) { try await ContainerService.deleteVolume(volume.name) }
        }
    }
}

struct VolumeRow: View {
    @EnvironmentObject var state: AppState
    let volume: VolumeRecord
    let inUse: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.fill")
                .foregroundStyle(.purple)
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(volume.name).font(.body.weight(.medium))
                    if inUse {
                        Text("in use")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.green.opacity(0.12), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            // Space in use on the right, like an image's size; the subtitle
            // carries the configured maximum.
            VStack(alignment: .trailing, spacing: 2) {
                if let used = state.volumeUsage[volume.name] {
                    Text(formatBytes(used)).font(.callout).foregroundStyle(.secondary)
                }
                Text(relativeDate(volume.created))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if state.busyIDs.contains(volume.id) {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 5)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let format = volume.format { parts.append(format) }
        if let size = volume.sizeInBytes {
            parts.append(String(localized: "max \(formatBytes(size))",
                                comment: "Volume size limit — the value is the maximum size."))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Networks

struct NetworksView: View {
    @EnvironmentObject var state: AppState
    @State private var search = ""
    @State private var showCreateSheet = false

    private var filtered: [NetworkRecord] {
        guard !search.isEmpty else { return state.networks }
        return state.networks.filter { $0.name.lowercased().contains(search.lowercased()) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !state.systemState.isRunning && state.initialLoadDone {
                    ServicesStoppedState()
                } else {
                    list
                }
            }
            .navigationTitle("Networks")
            .searchable(text: $search, placement: .toolbar, prompt: "Filter networks")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        showCreateSheet = true
                    } label: {
                        Label("Create Network", systemImage: "plus")
                    }
                    Menu {
                        Button("Prune Unused Networks", role: .destructive) {
                            state.perform("networks") { try await ContainerService.pruneNetworks() }
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showCreateSheet) { CreateNetworkSheet() }
        }
    }

    private var list: some View {
        NetworkListContent(networks: filtered)
            .refreshIndicator(state.isRefreshing)
    }
}

struct NetworkListContent: View {
    @EnvironmentObject var state: AppState
    let networks: [NetworkRecord]
    var scrollable = true

    @State private var selection: Set<String> = []
    @State private var confirmDelete = false

    /// Built-in networks can't be deleted, so they are not bulk targets.
    private var deleteTargets: [NetworkRecord] {
        ListSelection.targets(networks, selected: selection, id: \.id) { !$0.isBuiltin }
    }

    var body: some View {
        if scrollable {
            SelectableList(
                selection: $selection,
                visibleIDs: networks.map(\.id),
                deleteAction: { requestDelete() },
                content: {
                    ForEach(networks) { network in
                        ListRowContent {
                            NetworkRow(network: network)
                        }
                        .selectableListRow()
                        .tag(network.id)
                    }
                },
                menu: { rowMenu($0) }
            )
            .confirmationDialog(
                Text("Delete \(deleteTargets.count) Networks?",
                     comment: "Confirmation title for deleting selected networks — the value is the number of networks."),
                isPresented: $confirmDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    deleteTargets.forEach { network in
                        state.perform(network.id) { try await ContainerService.deleteNetwork(network.name) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        } else {
            CardList(items: networks, scrollable: false) { network in
                HoverRow {
                    NetworkRow(network: network)
                }
                .contextMenu { singleMenu(network) }
            }
        }
    }

    private func requestDelete() {
        guard !deleteTargets.isEmpty else { return }
        confirmDelete = true
    }

    @ViewBuilder
    private func rowMenu(_ ids: Set<String>) -> some View {
        let selected = networks.filter { ids.contains($0.id) }
        if selected.count == 1, let network = selected.first {
            singleMenu(network)
        } else {
            let deletable = selected.filter { !$0.isBuiltin }
            if !deletable.isEmpty {
                Button(role: .destructive) { confirmDelete = true } label: {
                    Text("Delete \(deletable.count) Networks…",
                         comment: "Bulk context-menu action that asks for confirmation — the value is the number of selected networks.")
                }
            }
        }
    }

    @ViewBuilder
    private func singleMenu(_ network: NetworkRecord) -> some View {
        if let subnet = network.subnet {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(subnet, forType: .string)
            } label: {
                Text("Copy Subnet (\(subnet))",
                     comment: "Context menu action — the value is the network's subnet.")
            }
        }
        if !network.isBuiltin {
            Divider()
            Button("Delete", role: .destructive) {
                state.perform(network.id) { try await ContainerService.deleteNetwork(network.name) }
            }
        }
    }
}

struct NetworkRow: View {
    @EnvironmentObject var state: AppState
    let network: NetworkRecord

    private var attachedCount: Int {
        state.containers.filter { c in
            c.status?.networks?.contains { $0.network == network.name } ?? false
        }.count
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "network")
                .foregroundStyle(.teal)
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(network.name).font(.body.weight(.medium))
                    if network.isBuiltin {
                        Text("built-in")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                Text([network.subnet, network.mode]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if attachedCount > 0 {
                Text("\(attachedCount) containers",
                     comment: "Network row — the value is the number of containers attached to the network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if state.busyIDs.contains(network.id) {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 5)
    }
}


/// Browse a volume's contents by mounting it into a throwaway helper container
/// and reusing the Files tab. The helper is created on appear and deleted on
/// dismiss.
struct VolumeBrowserSheet: View {
    @Environment(\.dismiss) private var dismiss
    let volume: VolumeRecord

    @State private var helperID: String?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Volume: \(volume.name)",
                     comment: "Volume browser sheet title — the value is the volume name.")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(16)
            Divider()
            Group {
                if let error {
                    EmptyState(icon: "exclamationmark.triangle", title: "Couldn't open volume", errorMessage: error)
                } else if let helperID {
                    ContainerFilesTab(
                        containerID: helperID, isRunning: true,
                        notRunningMessage: "The helper container stopped.")
                } else {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Mounting volume…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(width: 640, height: 520)
        .task {
            do { helperID = try await VolumeBrowser.open(volumeName: volume.name) }
            catch { self.error = (error as? CLIError)?.message ?? error.localizedDescription }
        }
        .onDisappear {
            if let helperID { Task { await VolumeBrowser.close(helperID) } }
        }
    }
}
