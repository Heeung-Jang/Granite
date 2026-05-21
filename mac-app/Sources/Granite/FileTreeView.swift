import NativeMarkdownCore
import SwiftUI

struct FileTreeView: View {
    private static let fileTreeItemLimit = 100_000

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
        .onChange(of: appState.selectedFile?.id) { _, newValue in
            selectedFileID = newValue
            expandToSelectedFileIfNeeded()
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
        case .loaded(let loaded):
            VStack(spacing: 0) {
                if loaded.snapshot.state != .complete {
                    HStack {
                        Image(systemName: loaded.snapshot.state == .stale ? "clock.badge.exclamationmark" : "ellipsis")
                        Text(loaded.snapshot.state == .stale ? "Stale" : "Partial")
                        Spacer()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(loaded.snapshot.state == .stale ? "File list is stale" : "File list is partial")

                    Divider()
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(loaded.visibleRows) { row in
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
                    maxItems: Self.fileTreeItemLimit
                )

                if Task.isCancelled {
                    return
                }

                let selectedFile = appState.selectedFile
                let outlineBuild = await Task.detached(priority: .userInitiated) {
                    let outline = FileTreeOutline(snapshot: snapshot)
                    let expandedFolderIDs = outline.defaultExpandedFolderIDs(selectedFile: selectedFile)
                    return FileTreeOutlineBuild(
                        outline: outline,
                        expandedFolderIDs: expandedFolderIDs,
                        visibleRows: outline.visibleRows(expandedFolderIDs: expandedFolderIDs)
                    )
                }.value

                if Task.isCancelled {
                    return
                }

                expandedFolderIDs = outlineBuild.expandedFolderIDs
                state = snapshot.items.isEmpty
                    ? .empty
                    : .loaded(FileTreeLoadedState(
                        snapshot: snapshot,
                        outline: outlineBuild.outline,
                        visibleRows: outlineBuild.visibleRows
                    ))
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
        guard let id, case .loaded(let loaded) = state else {
            return nil
        }
        return loaded.outline.item(withID: id)
    }

    private func handle(_ row: FileTreeOutlineRow) {
        switch row.kind {
        case .folder:
            let isExpanding: Bool
            if expandedFolderIDs.contains(row.id) {
                expandedFolderIDs.remove(row.id)
                isExpanding = false
            } else {
                expandedFolderIDs.insert(row.id)
                isExpanding = true
            }
            applyFolderToggle(rowID: row.id, isExpanded: isExpanding)
        case .file:
            guard let file = row.file else {
                return
            }
            selectedFileID = file.id
            let disposition = OpenDispositionResolver.resolve(
                isCommandPressed: NSApp.currentEvent?.modifierFlags.contains(.command) == true
            )
            if !appState.openFile(file, disposition: disposition) {
                selectedFileID = appState.selectedFile?.id
            }
        }
    }

    private func isSelected(_ row: FileTreeOutlineRow) -> Bool {
        guard let file = row.file else {
            return false
        }
        return file.id == selectedFileID
    }

    private func expandToSelectedFileIfNeeded() {
        guard let selectedFile = item(withID: selectedFileID),
              case .loaded(let loaded) = state
        else {
            return
        }
        let ancestorFolderIDs = loaded.outline.ancestorFolderIDs(for: selectedFile)
        guard !ancestorFolderIDs.isSubset(of: expandedFolderIDs) else {
            return
        }
        expandedFolderIDs.formUnion(ancestorFolderIDs)
        refreshVisibleRows()
    }

    private func applyFolderToggle(rowID: String, isExpanded: Bool) {
        guard case .loaded(var loaded) = state,
              let rowIndex = loaded.visibleRows.firstIndex(where: { $0.id == rowID })
        else {
            refreshVisibleRows()
            return
        }

        let row = loaded.visibleRows[rowIndex]
        loaded.visibleRows[rowIndex] = FileTreeOutlineRow(
            id: row.id,
            kind: row.kind,
            title: row.title,
            depth: row.depth,
            isExpanded: isExpanded,
            file: row.file
        )

        if isExpanded {
            let childRows = loaded.outline.childRows(
                ofFolderID: rowID,
                depth: row.depth + 1,
                expandedFolderIDs: expandedFolderIDs
            )
            loaded.visibleRows.insert(contentsOf: childRows, at: rowIndex + 1)
        } else {
            let removalStart = rowIndex + 1
            var removalEnd = removalStart
            while removalEnd < loaded.visibleRows.count,
                  loaded.visibleRows[removalEnd].depth > row.depth {
                removalEnd += 1
            }
            loaded.visibleRows.removeSubrange(removalStart..<removalEnd)
        }

        state = .loaded(loaded)
    }

    private func refreshVisibleRows() {
        guard case .loaded(var loaded) = state else {
            return
        }
        loaded.visibleRows = loaded.outline.visibleRows(expandedFolderIDs: expandedFolderIDs)
        state = .loaded(loaded)
    }
}

private struct FileTreeTaskKey: Hashable {
    let vaultPath: String?
    let readGeneration: UInt64
}

private enum FileTreeViewState {
    case idle
    case loading
    case loaded(FileTreeLoadedState)
    case empty
    case unavailable(VaultAccessIssue)
    case failed(String)
}

private struct FileTreeLoadedState {
    let snapshot: FileTreeSnapshot
    let outline: FileTreeOutline
    var visibleRows: [FileTreeOutlineRow]
}

private struct FileTreeOutlineBuild: Sendable {
    let outline: FileTreeOutline
    let expandedFolderIDs: Set<String>
    let visibleRows: [FileTreeOutlineRow]
}

private struct FileTreeRow: View {
    let row: FileTreeOutlineRow
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
