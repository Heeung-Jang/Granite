import Foundation
import NativeMarkdownCore

struct FileTreeActionsProbeReport: Codable, Equatable {
    let fileRenameUpdatesState: Bool
    let fileMoveUpdatesState: Bool
    let folderRenameUpdatesOpenTab: Bool
    let deleteClosesOpenTab: Bool
    let dirtyFolderBlocksOperation: Bool
    let tabHistoryWorks: Bool
    let readingModeToggles: Bool
    let temporaryCleanup: Bool

    var passed: Bool {
        fileRenameUpdatesState
            && fileMoveUpdatesState
            && folderRenameUpdatesOpenTab
            && deleteClosesOpenTab
            && dirtyFolderBlocksOperation
            && tabHistoryWorks
            && readingModeToggles
            && temporaryCleanup
    }
}

@MainActor
enum FileTreeActionsProbe {
    static func run() -> FileTreeActionsProbeReport {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try "A".write(to: root.appendingPathComponent("Alpha.md"), atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("Folder", isDirectory: true),
                withIntermediateDirectories: true
            )
            try "B".write(to: root.appendingPathComponent("Folder/Beta.md"), atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("Inbox", isDirectory: true),
                withIntermediateDirectories: true
            )

            let state = AppState(
                vaultSelection: .selected(root),
                engineHealth: EngineHealthStatus(state: .loaded, abiVersion: 1, message: "probe"),
                recentVaultStorage: FileTreeActionsProbeRecentVaultStorage(),
                startupVaultRestoreStorage: FileTreeActionsProbeStartupVaultRestoreStorage(),
                workspaceTabSessionStore: FileTreeActionsProbeWorkspaceTabSessionStore(),
                workspacePaneLayoutStore: FileTreeActionsProbePaneLayoutStore(),
                fileTreeSortModeStore: FileTreeActionsProbeSortModeStore()
            )
            let itemOperator = VaultItemOperator()

            let alpha = FileTreeItem(relativePath: "Alpha.md")
            _ = state.openFile(alpha, disposition: .currentTab)
            let renamedAlpha = try itemOperator.renameFile(vaultURL: root, file: alpha, newDisplayName: "Renamed Alpha")
            state.applyRenamedFile(renamedAlpha)
            let fileRenameUpdatesState = state.selectedFile == renamedAlpha.newFile
                && state.fileTreeOverlayRemovedItemIDs.contains(alpha.id)
                && state.fileTreeOverlayItems.contains(renamedAlpha.newFile)
                && FileManager.default.fileExists(atPath: root.appendingPathComponent("Renamed Alpha.md").path)

            let beta = FileTreeItem(relativePath: "Folder/Beta.md")
            _ = state.openFile(beta, disposition: .currentTab)
            let canNavigateBack = state.activeTabCanNavigateBack
            state.navigateActiveTabBack()
            let navigatedBack = state.selectedFile == renamedAlpha.newFile
            state.navigateActiveTabForward()
            let navigatedForward = state.selectedFile == beta
            let tabHistoryWorks = canNavigateBack && navigatedBack && navigatedForward

            state.toggleActiveTabReadingView()
            let readingModeToggles = state.activeTabViewMode == .reading

            state.updateEditorDirtyState(file: beta, isDirty: true)
            let dirtyFolderBlocksOperation = state.dirtyFileBlockingOperation(folderPath: "Folder") == beta
            state.updateEditorDirtyState(file: beta, isDirty: false)

            let renamedFolder = try itemOperator.renameFolder(vaultURL: root, folderPath: "Folder", newName: "Renamed Folder")
            state.applyRenamedFolder(oldPath: renamedFolder.oldFolderPath, newPath: renamedFolder.newFolderPath)
            let movedBeta = FileTreeItem(relativePath: "Renamed Folder/Beta.md")
            let folderRenameUpdatesOpenTab = state.selectedFile == movedBeta
                && state.fileTreeOverlayRemovedFolderPaths.contains("Folder")
                && FileManager.default.fileExists(atPath: root.appendingPathComponent("Renamed Folder/Beta.md").path)

            let movedAlpha = try itemOperator.moveFile(
                vaultURL: root,
                file: renamedAlpha.newFile,
                destinationFolderPath: "Inbox"
            )
            state.applyMovedFile(movedAlpha)
            let fileMoveUpdatesState = state.fileTreeOverlayRemovedItemIDs.contains(renamedAlpha.newFile.id)
                && state.fileTreeOverlayItems.contains(movedAlpha.newFile)
                && FileManager.default.fileExists(atPath: root.appendingPathComponent("Inbox/Renamed Alpha.md").path)
            _ = state.openFile(movedAlpha.newFile, disposition: .newTab)
            state.applyDeletedFile(movedAlpha.newFile)
            let deleteClosesOpenTab = !state.workspaceTabs.contains { $0.file == movedAlpha.newFile }

            return FileTreeActionsProbeReport(
                fileRenameUpdatesState: fileRenameUpdatesState,
                fileMoveUpdatesState: fileMoveUpdatesState,
                folderRenameUpdatesOpenTab: folderRenameUpdatesOpenTab,
                deleteClosesOpenTab: deleteClosesOpenTab,
                dirtyFolderBlocksOperation: dirtyFolderBlocksOperation,
                tabHistoryWorks: tabHistoryWorks,
                readingModeToggles: readingModeToggles,
                temporaryCleanup: cleanup(root)
            )
        } catch {
            return FileTreeActionsProbeReport(
                fileRenameUpdatesState: false,
                fileMoveUpdatesState: false,
                folderRenameUpdatesOpenTab: false,
                deleteClosesOpenTab: false,
                dirtyFolderBlocksOperation: false,
                tabHistoryWorks: false,
                readingModeToggles: false,
                temporaryCleanup: cleanup(root)
            )
        }
    }

    static func encodedReport(_ report: FileTreeActionsProbeReport = run()) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report),
              let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }

    private static func cleanup(_ root: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: root)
            return !FileManager.default.fileExists(atPath: root.path)
        } catch {
            return false
        }
    }
}

private struct FileTreeActionsProbeRecentVaultStorage: RecentVaultStoring {
    func loadRecentVaultURLs() -> [URL] { [] }
    func saveRecentVaultURLs(_ urls: [URL]) {}
}

private struct FileTreeActionsProbeStartupVaultRestoreStorage: StartupVaultRestoreStoring {
    func loadSuppressesLastVaultRestore() -> Bool { false }
    func saveSuppressesLastVaultRestore(_ value: Bool) {}
}

private struct FileTreeActionsProbeWorkspaceTabSessionStore: WorkspaceTabSessionStoring {
    func loadSession(forVaultAt vaultURL: URL) -> WorkspaceTabSession? { nil }
    func saveSession(_ session: WorkspaceTabSession, forVaultAt vaultURL: URL) {}
    func clearSession(forVaultAt vaultURL: URL) {}
}

private struct FileTreeActionsProbePaneLayoutStore: WorkspacePaneLayoutStoring {
    func loadLayout(forVaultAt vaultURL: URL) -> WorkspacePaneLayout? { nil }
    func saveLayout(_ layout: WorkspacePaneLayout, forVaultAt vaultURL: URL) {}
    func clearLayout(forVaultAt vaultURL: URL) {}
}

private struct FileTreeActionsProbeSortModeStore: FileTreeSortModeStoring {
    func loadSortMode(forVaultAt vaultURL: URL) -> FileTreeSortMode { .nameAscending }
    func saveSortMode(_ mode: FileTreeSortMode, forVaultAt vaultURL: URL) {}
    func clearSortMode(forVaultAt vaultURL: URL) {}
}
