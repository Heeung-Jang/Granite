import AppKit
import NativeMarkdownCore
import SwiftUI

struct FileTreeView: View {
    private static let fileTreeItemLimit = 100_000

    var showsHeader = true
    @Binding var selectedFolderPath: String?

    @EnvironmentObject private var appState: AppState
    @Environment(\.appContentZoomScale) private var appContentZoomScale
    @State private var state: FileTreeViewState = .idle
    @State private var selectedFileID: String?
    @State private var expandedFolderIDs: Set<String> = []
    @State private var renameRowID: String?
    @State private var renameTarget: VaultItemOperationTarget?
    @State private var renameText = ""
    @State private var pendingDeletion: FileTreePendingDeletion?
    @State private var operationError: String?
    @FocusState private var focusedRenameRowID: String?

    init(showsHeader: Bool = true, selectedFolderPath: Binding<String?> = .constant(nil)) {
        self.showsHeader = showsHeader
        self._selectedFolderPath = selectedFolderPath
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                header
                    .padding(.horizontal, ObsidianUI.scaled(12, scale: appContentZoomScale))
                    .padding(.vertical, ObsidianUI.scaled(8, scale: appContentZoomScale))

                Divider()
            }

            content
        }
        .task(id: FileTreeTaskKey(
            vaultPath: appState.vaultSelection.url?.path,
            readGeneration: appState.readGeneration,
            overlayRevision: appState.fileTreeOverlayRevision,
            sortMode: appState.fileTreeSortMode
        )) {
            await reload(for: appState.vaultSelection)
        }
        .onChange(of: appState.fileTreeCollapseRequestID) { _, _ in
            expandedFolderIDs = []
            selectedFolderPath = nil
            refreshVisibleRows()
        }
        .onChange(of: appState.selectedFile?.id) { _, newValue in
            selectedFileID = newValue
            if newValue != nil {
                selectedFolderPath = nil
            }
            expandToSelectedFileIfNeeded()
        }
        .alert("File operation failed", isPresented: operationErrorBinding) {
            Button("OK") {
                operationError = nil
            }
        } message: {
            Text(operationError ?? "")
        }
        .alert(item: $pendingDeletion) { deletion in
            Alert(
                title: Text("Move to Trash?"),
                message: Text("Move \"\(deletion.displayName)\" to the Trash?"),
                primaryButton: .destructive(Text("Move to Trash")) {
                    performDelete(deletion)
                },
                secondaryButton: .cancel()
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("File browser")
    }

    private var operationErrorBinding: Binding<Bool> {
        Binding {
            operationError != nil
        } set: { isPresented in
            if !isPresented {
                operationError = nil
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Files")
                .font(.system(size: ObsidianUI.fontSize(13, scale: appContentZoomScale), weight: .semibold))

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
                        .font(.system(size: ObsidianUI.fontSize(13, scale: appContentZoomScale)))
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
                    .font(.system(size: ObsidianUI.fontSize(12, scale: appContentZoomScale)))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, ObsidianUI.scaled(12, scale: appContentZoomScale))
                    .padding(.vertical, ObsidianUI.scaled(6, scale: appContentZoomScale))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(loaded.snapshot.state == .stale ? "File list is stale" : "File list is partial")

                    Divider()
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: ObsidianUI.scaled(1, scale: appContentZoomScale)) {
                        ForEach(loaded.visibleRows) { row in
                            Group {
                                if renameRowID == row.id {
                                    FileTreeRenameRow(
                                        row: row,
                                        isSelected: isSelected(row),
                                        text: $renameText,
                                        commit: commitInlineRename,
                                        cancel: cancelInlineRename
                                    )
                                    .focused($focusedRenameRowID, equals: row.id)
                                    .onAppear {
                                        focusedRenameRowID = row.id
                                    }
                                } else {
                                    Button {
                                        handle(row)
                                    } label: {
                                        FileTreeRow(row: row, isSelected: isSelected(row))
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        contextMenu(for: row)
                                    }
                                }
                            }
                            .padding(.horizontal, ObsidianUI.scaled(8, scale: appContentZoomScale))
                        }
                    }
                    .padding(.vertical, ObsidianUI.scaled(4, scale: appContentZoomScale))
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
            selectedFolderPath = nil
        case .unavailable(let issue):
            state = .unavailable(issue)
            expandedFolderIDs = []
            selectedFolderPath = nil
        case .selected(let vaultURL):
            let timer = AppTelemetryTimer()
            state = .loading
            guard let reader = appState.readClient, appState.readAvailability == .ready else {
                state = appState.readAvailability == .opening
                    ? .loading
                    : .failed(readUnavailableTitle(appState.readAvailability))
                return
            }
            let generation = appState.readGeneration
            let folderTask = Task.detached(priority: .utility) {
                try FileSystemFolderTreeLoader().loadFolderPaths(at: vaultURL)
            }
            do {
                let engineSnapshot = try await EngineFileTreeLoader(reader: reader).loadFileTree(
                    requestID: generation,
                    maxItems: Self.fileTreeItemLimit
                )
                let folderPaths = (try? await folderTask.value) ?? []
                let sortMode = appState.fileTreeSortMode
                let snapshot = FileTreeSnapshot(
                    items: mergedItems(
                        engineSnapshot.items,
                        appState.fileTreeOverlayItems,
                        removedItemIDs: appState.fileTreeOverlayRemovedItemIDs,
                        removedFolderPaths: appState.fileTreeOverlayRemovedFolderPaths
                    ),
                    folderPaths: mergedFolderPaths(
                        folderPaths,
                        appState.fileTreeOverlayFolderPaths,
                        removedFolderPaths: appState.fileTreeOverlayRemovedFolderPaths
                    ),
                    state: engineSnapshot.state
                )
                let modifiedDates = await loadModifiedDates(
                    vaultURL: vaultURL,
                    snapshot: snapshot,
                    sortMode: sortMode
                )

                if Task.isCancelled {
                    return
                }

                let selectedFile = appState.selectedFile
                let outlineBuild = await Task.detached(priority: .userInitiated) {
                    let outline = FileTreeOutline(
                        snapshot: snapshot,
                        sortMode: sortMode,
                        modifiedDates: modifiedDates
                    )
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
                state = snapshot.items.isEmpty && snapshot.folderPaths.isEmpty
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
                folderTask.cancel()
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

    private func loadModifiedDates(
        vaultURL: URL,
        snapshot: FileTreeSnapshot,
        sortMode: FileTreeSortMode
    ) async -> [String: Date] {
        switch sortMode {
        case .nameAscending, .nameDescending:
            return [:]
        case .modifiedNewest, .modifiedOldest:
            return await Task.detached(priority: .utility) {
                let rootURL = vaultURL.standardizedFileURL
                let resourceKeys: Set<URLResourceKey> = [.contentModificationDateKey]
                var dates: [String: Date] = [:]
                for item in snapshot.items {
                    let url = rootURL.appendingPathComponent(item.relativePath, isDirectory: false)
                    if let date = try? url.resourceValues(forKeys: resourceKeys).contentModificationDate {
                        dates[item.relativePath] = date
                    }
                }
                for folderPath in snapshot.folderPaths {
                    let url = rootURL.appendingPathComponent(folderPath, isDirectory: true)
                    if let date = try? url.resourceValues(forKeys: resourceKeys).contentModificationDate {
                        dates[folderPath] = date
                    }
                }
                return dates
            }.value
        }
    }

    private func mergedItems(
        _ engineItems: [FileTreeItem],
        _ overlayItems: [FileTreeItem],
        removedItemIDs: Set<String>,
        removedFolderPaths: Set<String>
    ) -> [FileTreeItem] {
        let filteredEngineItems = engineItems.filter { item in
            !removedItemIDs.contains(item.id) && !isPath(item.relativePath, underAny: removedFolderPaths)
        }
        return Dictionary(
            (filteredEngineItems + overlayItems).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        .values
        .sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    private func mergedFolderPaths(
        _ engineFolders: [String],
        _ overlayFolders: [String],
        removedFolderPaths: Set<String>
    ) -> [String] {
        let filteredEngineFolders = engineFolders.filter { !isPath($0, underAny: removedFolderPaths) }
        return Array(Set(filteredEngineFolders + overlayFolders)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private func isPath(_ path: String, underAny folderPaths: Set<String>) -> Bool {
        folderPaths.contains { folderPath in
            VaultItemOperator.path(path, isSameOrDescendantOf: folderPath)
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
            selectedFolderPath = row.id
            selectedFileID = nil
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
            selectedFolderPath = nil
            selectedFileID = file.id
            let disposition = OpenDispositionResolver.resolve(
                isCommandPressed: NSApp.currentEvent?.modifierFlags.contains(.command) == true
            )
            if !appState.openFile(file, disposition: disposition) {
                selectedFileID = appState.selectedFile?.id
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for row: FileTreeOutlineRow) -> some View {
        switch row.kind {
        case .folder:
            Button("New note") {
                createNote(inFolderPath: row.id)
            }
            Button("New folder") {
                createFolder(inFolderPath: row.id)
            }
            Divider()
            Button("Rename") {
                beginRename(row)
            }
            Button("Move...") {
                moveFolder(row.id)
            }
            Button("Reveal in Finder") {
                revealInFinder(relativePath: row.id)
            }
            Divider()
            Button("Delete", role: .destructive) {
                pendingDeletion = FileTreePendingDeletion.folder(row.id)
            }
        case .file:
            if let file = row.file {
                Button("Open in new tab") {
                    _ = appState.openFile(file, disposition: .newTab)
                }
                Divider()
                Button("Rename") {
                    beginRename(row)
                }
                Button("Move...") {
                    moveFile(file)
                }
                Button("Reveal in Finder") {
                    revealInFinder(relativePath: file.relativePath)
                }
                Divider()
                Button("Delete", role: .destructive) {
                    pendingDeletion = FileTreePendingDeletion.file(file)
                }
            }
        }
    }

    private func beginRename(_ row: FileTreeOutlineRow) {
        renameRowID = row.id
        switch row.kind {
        case .folder:
            renameTarget = .folder(row.id)
            renameText = (row.id as NSString).lastPathComponent
            selectedFolderPath = row.id
            selectedFileID = nil
        case .file:
            guard let file = row.file else {
                cancelInlineRename()
                return
            }
            renameTarget = .file(file)
            renameText = (file.displayName as NSString).deletingPathExtension
            selectedFolderPath = nil
            selectedFileID = file.id
        }
    }

    private func commitInlineRename() {
        guard let target = renameTarget,
              let vaultURL = appState.vaultSelection.url
        else {
            cancelInlineRename()
            return
        }
        let newName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            switch target {
            case .file(let file):
                if let dirtyFile = appState.dirtyFileBlockingOperation(file: file) {
                    throw FileTreeViewOperationError.dirtyFile(dirtyFile.displayName)
                }
                let result = try VaultItemOperator().renameFile(
                    vaultURL: vaultURL,
                    file: file,
                    newDisplayName: newName
                )
                appState.applyRenamedFile(result)
                selectedFileID = result.newFile.id
            case .folder(let folderPath):
                if let dirtyFile = appState.dirtyFileBlockingOperation(folderPath: folderPath) {
                    throw FileTreeViewOperationError.dirtyFile(dirtyFile.displayName)
                }
                let result = try VaultItemOperator().renameFolder(
                    vaultURL: vaultURL,
                    folderPath: folderPath,
                    newName: newName
                )
                appState.applyRenamedFolder(
                    oldPath: result.oldFolderPath,
                    newPath: result.newFolderPath,
                    movedFiles: movedOverlayFiles(oldPath: result.oldFolderPath, newPath: result.newFolderPath)
                )
                if expandedFolderIDs.remove(result.oldFolderPath) != nil {
                    expandedFolderIDs.insert(result.newFolderPath)
                }
                selectedFolderPath = result.newFolderPath
            }
            cancelInlineRename()
        } catch {
            operationError = error.localizedDescription
            focusedRenameRowID = renameRowID
        }
    }

    private func cancelInlineRename() {
        renameRowID = nil
        renameTarget = nil
        renameText = ""
        focusedRenameRowID = nil
    }

    private func createNote(inFolderPath folderPath: String) {
        guard let vaultURL = appState.vaultSelection.url else {
            return
        }
        let parentURL = vaultURL.appendingPathComponent(folderPath, isDirectory: true)
        let name = VaultNameSuggestion().suggestedNoteName(in: parentURL)
        do {
            let item = try VaultItemCreator().createNote(
                vaultURL: vaultURL,
                parentFolderPath: folderPath,
                name: name
            )
            appState.registerCreatedFileTreeItem(item)
            expandedFolderIDs.insert(folderPath)
            selectedFolderPath = nil
            selectedFileID = item.id
            let disposition: WorkspaceTabOpenDisposition = appState.isActiveEditorDirty ? .newTab : .currentTab
            _ = appState.openFile(item, disposition: disposition)
            _ = appState.requestCurrentVaultIndexRebuild()
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func createFolder(inFolderPath folderPath: String) {
        guard let vaultURL = appState.vaultSelection.url else {
            return
        }
        let parentURL = vaultURL.appendingPathComponent(folderPath, isDirectory: true)
        let name = VaultNameSuggestion().suggestedFolderName(in: parentURL)
        do {
            let createdPath = try VaultItemCreator().createFolder(
                vaultURL: vaultURL,
                parentFolderPath: folderPath,
                name: name
            )
            appState.registerCreatedFileTreeFolder(path: createdPath)
            expandedFolderIDs.insert(folderPath)
            selectedFolderPath = createdPath
            selectedFileID = nil
            _ = appState.requestCurrentVaultIndexRebuild()
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func moveFile(_ file: FileTreeItem) {
        guard let vaultURL = appState.vaultSelection.url,
              let destinationFolderPath = chooseDestinationFolder(in: vaultURL)
        else {
            return
        }
        do {
            if let dirtyFile = appState.dirtyFileBlockingOperation(file: file) {
                throw FileTreeViewOperationError.dirtyFile(dirtyFile.displayName)
            }
            let result = try VaultItemOperator().moveFile(
                vaultURL: vaultURL,
                file: file,
                destinationFolderPath: destinationFolderPath
            )
            appState.applyMovedFile(result)
            selectedFileID = result.newFile.id
            selectedFolderPath = nil
            if !destinationFolderPath.isEmpty {
                expandedFolderIDs.insert(destinationFolderPath)
            }
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func moveFolder(_ folderPath: String) {
        guard let vaultURL = appState.vaultSelection.url,
              let destinationFolderPath = chooseDestinationFolder(in: vaultURL)
        else {
            return
        }
        do {
            if let dirtyFile = appState.dirtyFileBlockingOperation(folderPath: folderPath) {
                throw FileTreeViewOperationError.dirtyFile(dirtyFile.displayName)
            }
            let result = try VaultItemOperator().moveFolder(
                vaultURL: vaultURL,
                folderPath: folderPath,
                destinationFolderPath: destinationFolderPath
            )
            appState.applyMovedFolder(
                oldPath: result.oldFolderPath,
                newPath: result.newFolderPath,
                movedFiles: movedOverlayFiles(oldPath: result.oldFolderPath, newPath: result.newFolderPath)
            )
            expandedFolderIDs.remove(result.oldFolderPath)
            expandedFolderIDs.insert(result.newFolderPath)
            if !destinationFolderPath.isEmpty {
                expandedFolderIDs.insert(destinationFolderPath)
            }
            selectedFolderPath = result.newFolderPath
            selectedFileID = nil
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func performDelete(_ deletion: FileTreePendingDeletion) {
        guard let vaultURL = appState.vaultSelection.url else {
            return
        }
        do {
            switch deletion {
            case .file(let file):
                if let dirtyFile = appState.dirtyFileBlockingOperation(file: file) {
                    throw FileTreeViewOperationError.dirtyFile(dirtyFile.displayName)
                }
                let url = try VaultItemOperator().containedURL(vaultURL: vaultURL, relativePath: file.relativePath)
                var trashedURL: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &trashedURL)
                appState.applyDeletedFile(file)
                selectedFileID = appState.selectedFile?.id
            case .folder(let folderPath):
                if let dirtyFile = appState.dirtyFileBlockingOperation(folderPath: folderPath) {
                    throw FileTreeViewOperationError.dirtyFile(dirtyFile.displayName)
                }
                let url = try VaultItemOperator().containedURL(vaultURL: vaultURL, relativePath: folderPath)
                var trashedURL: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &trashedURL)
                appState.applyDeletedFolder(path: folderPath)
                expandedFolderIDs = expandedFolderIDs.filter { !VaultItemOperator.path($0, isSameOrDescendantOf: folderPath) }
                selectedFolderPath = nil
            }
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func revealInFinder(relativePath: String) {
        guard let vaultURL = appState.vaultSelection.url,
              let url = try? VaultItemOperator().containedURL(vaultURL: vaultURL, relativePath: relativePath)
        else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func chooseDestinationFolder(in vaultURL: URL) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = vaultURL
        panel.prompt = "Move"
        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }
        return relativeFolderPath(for: url, vaultURL: vaultURL)
    }

    private func relativeFolderPath(for url: URL, vaultURL: URL) -> String? {
        let rootPath = vaultURL.standardizedFileURL.resolvingSymlinksInPath().path
        let folderPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard folderPath == rootPath || folderPath.hasPrefix("\(rootPath)/") else {
            operationError = "Choose a folder inside the current vault."
            return nil
        }
        guard folderPath != rootPath else {
            return ""
        }
        return String(folderPath.dropFirst(rootPath.count + 1))
    }

    private func movedOverlayFiles(oldPath: String, newPath: String) -> [FileTreeItem] {
        guard case .loaded(let loaded) = state else {
            return []
        }
        return loaded.snapshot.items.compactMap { item in
            guard let movedPath = VaultItemOperator.replacingPrefix(
                in: item.relativePath,
                oldPrefix: oldPath,
                newPrefix: newPath
            ) else {
                return nil
            }
            return FileTreeItem(relativePath: movedPath)
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
    let overlayRevision: UInt64
    let sortMode: FileTreeSortMode
}

private enum FileTreeViewOperationError: LocalizedError {
    case dirtyFile(String)

    var errorDescription: String? {
        switch self {
        case .dirtyFile(let name):
            return "Save or discard changes in \"\(name)\" before changing this item."
        }
    }
}

private enum FileTreePendingDeletion: Identifiable {
    case file(FileTreeItem)
    case folder(String)

    var id: String {
        switch self {
        case .file(let file):
            return "file-\(file.id)"
        case .folder(let folderPath):
            return "folder-\(folderPath)"
        }
    }

    var displayName: String {
        switch self {
        case .file(let file):
            return file.displayName
        case .folder(let folderPath):
            return (folderPath as NSString).lastPathComponent
        }
    }
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
    @Environment(\.appContentZoomScale) private var appContentZoomScale
    let row: FileTreeOutlineRow
    let isSelected: Bool

    var body: some View {
        HStack(spacing: ObsidianUI.scaled(6, scale: appContentZoomScale)) {
            Color.clear
                .frame(width: ObsidianUI.scaled(CGFloat(row.depth) * 16, scale: appContentZoomScale))

            if row.kind == .folder {
                Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: ObsidianUI.fontSize(11, scale: appContentZoomScale)))
                    .foregroundStyle(.secondary)
                    .frame(width: ObsidianUI.scaled(12, scale: appContentZoomScale))
            } else {
                Color.clear
                    .frame(width: ObsidianUI.scaled(12, scale: appContentZoomScale))
            }

            Image(systemName: row.kind == .folder ? "folder" : "doc.text")
                .font(.system(size: ObsidianUI.fontSize(14, scale: appContentZoomScale)))
                .foregroundStyle(.secondary)
                .frame(width: ObsidianUI.scaled(16, scale: appContentZoomScale))

            Text(row.title)
                .font(.system(size: ObsidianUI.fontSize(14, scale: appContentZoomScale)))
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.86))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, ObsidianUI.scaled(6, scale: appContentZoomScale))
        .frame(height: ObsidianUI.scaled(28, scale: appContentZoomScale))
        .background(isSelected ? ObsidianUI.selectedFill : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: ObsidianUI.scaled(5, scale: appContentZoomScale)))
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

private struct FileTreeRenameRow: View {
    @Environment(\.appContentZoomScale) private var appContentZoomScale
    let row: FileTreeOutlineRow
    let isSelected: Bool
    @Binding var text: String
    let commit: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: ObsidianUI.scaled(6, scale: appContentZoomScale)) {
            Color.clear
                .frame(width: ObsidianUI.scaled(CGFloat(row.depth) * 16, scale: appContentZoomScale))

            if row.kind == .folder {
                Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: ObsidianUI.fontSize(11, scale: appContentZoomScale)))
                    .foregroundStyle(.secondary)
                    .frame(width: ObsidianUI.scaled(12, scale: appContentZoomScale))
            } else {
                Color.clear
                    .frame(width: ObsidianUI.scaled(12, scale: appContentZoomScale))
            }

            Image(systemName: row.kind == .folder ? "folder" : "doc.text")
                .font(.system(size: ObsidianUI.fontSize(14, scale: appContentZoomScale)))
                .foregroundStyle(.secondary)
                .frame(width: ObsidianUI.scaled(16, scale: appContentZoomScale))

            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: ObsidianUI.fontSize(14, scale: appContentZoomScale)))
                .onSubmit(commit)
                .onExitCommand(perform: cancel)
                .accessibilityLabel("Rename \(row.title)")
        }
        .padding(.horizontal, ObsidianUI.scaled(6, scale: appContentZoomScale))
        .frame(height: ObsidianUI.scaled(28, scale: appContentZoomScale))
        .background(isSelected ? ObsidianUI.selectedFill : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: ObsidianUI.scaled(5, scale: appContentZoomScale)))
    }
}

private struct EmptyFileTreeState: View {
    @Environment(\.appContentZoomScale) private var appContentZoomScale
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: ObsidianUI.scaled(8, scale: appContentZoomScale)) {
            Image(systemName: systemImage)
                .font(.system(size: ObsidianUI.fontSize(16, scale: appContentZoomScale)))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: ObsidianUI.fontSize(12, scale: appContentZoomScale)))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(ObsidianUI.scaled(16, scale: appContentZoomScale))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}
