import NativeMarkdownCore
import SwiftUI

struct FileTreeView: View {
    var showsHeader = true

    @EnvironmentObject private var appState: AppState
    @State private var state: FileTreeViewState = .idle
    @State private var selectedFileID: String?
    @State private var expandedFolderIDs: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                header
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                Divider()
            }

            content
        }
        .task(id: FileTreeTaskKey(
            vaultPath: appState.vaultSelection.url?.path,
            readGeneration: appState.readGeneration
        )) {
            await reload(for: appState.vaultSelection)
        }
        .onChange(of: selectedFileID) { _, newValue in
            guard let item = item(withID: newValue) else {
                return
            }
            if !appState.openFile(item) {
                selectedFileID = appState.selectedFile?.id
            }
        }
        .onChange(of: appState.selectedFile?.id) { _, newValue in
            selectedFileID = newValue
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("File browser")
    }

    private var header: some View {
        HStack {
            Text("Files")
                .font(.headline)

            Spacer()

            if case .loading = state {
                ProgressView()
                    .controlSize(.small)
            } else if case .loaded = state {
                Button {
                    Task {
                        await reload(for: appState.vaultSelection)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh Files")
                .accessibilityLabel("Refresh files")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            EmptyFileTreeState(title: "No Vault Open", systemImage: "folder")
        case .loading:
            EmptyFileTreeState(title: "Loading Files", systemImage: "hourglass")
        case .empty:
            EmptyFileTreeState(title: "No Markdown Files", systemImage: "doc")
        case .unavailable(let issue):
            EmptyFileTreeState(title: issue.displayTitle, systemImage: "exclamationmark.triangle")
        case .failed(let message):
            EmptyFileTreeState(title: message, systemImage: "xmark.octagon")
        case .loaded(let snapshot):
            VStack(spacing: 0) {
                if snapshot.state != .complete {
                    HStack {
                        Image(systemName: snapshot.state == .stale ? "clock.badge.exclamationmark" : "ellipsis")
                        Text(snapshot.state == .stale ? "Stale" : "Partial")
                        Spacer()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(snapshot.state == .stale ? "File list is stale" : "File list is partial")

                    Divider()
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(visibleRows(for: snapshot)) { row in
                            Button {
                                handle(row)
                            } label: {
                                FileTreeRow(row: row, isSelected: isSelected(row))
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 8)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .accessibilityLabel("Markdown files")
            }
        }
    }

    @MainActor
    private func reload(for selection: VaultSelectionState) async {
        selectedFileID = appState.selectedFile?.id

        switch selection {
        case .noVault:
            state = .idle
            expandedFolderIDs = []
        case .unavailable(let issue):
            state = .unavailable(issue)
            expandedFolderIDs = []
        case .selected:
            let timer = AppTelemetryTimer()
            state = .loading
            guard let reader = appState.readClient, appState.readAvailability == .ready else {
                state = appState.readAvailability == .opening
                    ? .loading
                    : .failed(readUnavailableTitle(appState.readAvailability))
                return
            }
            let generation = appState.readGeneration
            do {
                let snapshot = try await EngineFileTreeLoader(reader: reader).loadFileTree(
                    requestID: generation,
                    maxItems: 5_000
                )

                if Task.isCancelled {
                    return
                }

                expandedFolderIDs = defaultExpandedFolders(for: snapshot)
                state = snapshot.items.isEmpty ? .empty : .loaded(snapshot)
                AppTelemetry.sidebarRefreshCompleted(
                    state: snapshot.state,
                    itemCount: snapshot.items.count,
                    durationMilliseconds: timer.elapsedMilliseconds()
                )
            } catch {
                if Task.isCancelled {
                    return
                }
                state = .failed(error.localizedDescription)
                AppTelemetry.sidebarRefreshCompleted(
                    state: nil,
                    itemCount: 0,
                    durationMilliseconds: timer.elapsedMilliseconds()
                )
            }
        }
    }

    private func readUnavailableTitle(_ availability: ReadAvailability) -> String {
        switch availability {
        case .unavailable:
            return "Index Unavailable"
        case .opening:
            return "Opening Index"
        case .ready:
            return "Index Ready"
        case .stale:
            return "Index Stale"
        case .error(let message):
            return message
        }
    }

    private func item(withID id: String?) -> FileTreeItem? {
        guard let id, case .loaded(let snapshot) = state else {
            return nil
        }
        return snapshot.items.first { $0.id == id }
    }

    private func handle(_ row: FileTreeDisplayRow) {
        switch row.kind {
        case .folder:
            if expandedFolderIDs.contains(row.id) {
                expandedFolderIDs.remove(row.id)
            } else {
                expandedFolderIDs.insert(row.id)
            }
        case .file:
            guard let file = row.file else {
                return
            }
            selectedFileID = file.id
            if !appState.openFile(file) {
                selectedFileID = appState.selectedFile?.id
            }
        }
    }

    private func isSelected(_ row: FileTreeDisplayRow) -> Bool {
        guard let file = row.file else {
            return false
        }
        return file.id == selectedFileID
    }

    private func visibleRows(for snapshot: FileTreeSnapshot) -> [FileTreeDisplayRow] {
        let folders = folderPaths(for: snapshot.items)
        let childFolders = Dictionary(grouping: folders) { parentPath(for: $0) }
        let childFiles = Dictionary(grouping: snapshot.items) { $0.parentPath }
        var rows: [FileTreeDisplayRow] = []

        func appendChildren(parent: String, depth: Int) {
            let folders = (childFolders[parent] ?? []).sorted {
                displayName(forFolderPath: $0).localizedStandardCompare(displayName(forFolderPath: $1)) == .orderedAscending
            }
            for folder in folders {
                rows.append(FileTreeDisplayRow(
                    id: folder,
                    kind: .folder,
                    title: displayName(forFolderPath: folder),
                    depth: depth,
                    isExpanded: expandedFolderIDs.contains(folder),
                    file: nil
                ))
                if expandedFolderIDs.contains(folder) {
                    appendChildren(parent: folder, depth: depth + 1)
                }
            }

            let files = (childFiles[parent] ?? []).sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
            for file in files {
                rows.append(FileTreeDisplayRow(
                    id: file.id,
                    kind: .file,
                    title: (file.displayName as NSString).deletingPathExtension,
                    depth: depth,
                    isExpanded: false,
                    file: file
                ))
            }
        }

        appendChildren(parent: "", depth: 0)
        return rows
    }

    private func folderPaths(for items: [FileTreeItem]) -> Set<String> {
        var folders = Set<String>()
        for item in items {
            var current = ""
            for component in item.parentPath.split(separator: "/") {
                current = current.isEmpty ? String(component) : "\(current)/\(component)"
                folders.insert(current)
            }
        }
        return folders
    }

    private func defaultExpandedFolders(for snapshot: FileTreeSnapshot) -> Set<String> {
        var folders = Set<String>()
        for item in snapshot.items {
            if let root = item.parentPath.split(separator: "/").first {
                folders.insert(String(root))
            }
            if appState.selectedFile == item {
                folders.formUnion(ancestorFolders(for: item.parentPath))
            }
        }
        return folders
    }

    private func ancestorFolders(for path: String) -> Set<String> {
        var folders = Set<String>()
        var current = ""
        for component in path.split(separator: "/") {
            current = current.isEmpty ? String(component) : "\(current)/\(component)"
            folders.insert(current)
        }
        return folders
    }

    private func parentPath(for folderPath: String) -> String {
        let parent = (folderPath as NSString).deletingLastPathComponent
        return parent == "." ? "" : parent
    }

    private func displayName(forFolderPath folderPath: String) -> String {
        (folderPath as NSString).lastPathComponent
    }
}

private struct FileTreeTaskKey: Hashable {
    let vaultPath: String?
    let readGeneration: UInt64
}

private enum FileTreeViewState {
    case idle
    case loading
    case loaded(FileTreeSnapshot)
    case empty
    case unavailable(VaultAccessIssue)
    case failed(String)
}

private struct FileTreeDisplayRow: Identifiable {
    enum Kind {
        case folder
        case file
    }

    let id: String
    let kind: Kind
    let title: String
    let depth: Int
    let isExpanded: Bool
    let file: FileTreeItem?
}

private struct FileTreeRow: View {
    let row: FileTreeDisplayRow
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Color.clear
                .frame(width: CGFloat(row.depth) * 16)

            if row.kind == .folder {
                Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            } else {
                Color.clear
                    .frame(width: 12)
            }

            Image(systemName: row.kind == .folder ? "folder" : "doc.text")
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(row.title)
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.86))

            Spacer(minLength: 0)
        }
        .font(.system(size: 14))
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background(isSelected ? ObsidianUI.selectedFill : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch row.kind {
        case .folder:
            return "\(row.title) folder"
        case .file:
            return row.title
        }
    }
}

private struct EmptyFileTreeState: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}
