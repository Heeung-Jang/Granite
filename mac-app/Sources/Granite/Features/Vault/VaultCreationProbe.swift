import Foundation
import NativeMarkdownCore

struct VaultCreationProbeReport: Codable, Equatable {
    let vaultCreated: Bool
    let initialNoteOpened: Bool
    let noteCreationPreservesDirtyTab: Bool
    let folderOverlayVisible: Bool
    let indexRebuildRefreshesGeneration: Bool
    let outputRedacted: Bool
    let temporaryCleanup: Bool

    var passed: Bool {
        vaultCreated
            && initialNoteOpened
            && noteCreationPreservesDirtyTab
            && folderOverlayVisible
            && indexRebuildRefreshesGeneration
            && outputRedacted
            && temporaryCleanup
    }
}

@MainActor
enum VaultCreationProbe {
    static func run() -> VaultCreationProbeReport {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let parentURL = root.appendingPathComponent("parent", isDirectory: true)
            let supportURL = root.appendingPathComponent("support", isDirectory: true)
            try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)

            let outcome = try VaultCreator().createVault(VaultCreationRequest(
                parentURL: parentURL,
                vaultName: "Probe Vault"
            ))
            let firstClient = ProbeReadClient()
            let secondClient = ProbeReadClient()
            let scheduler = ProbeReadIndexRecoveryScheduler()
            let state = AppState(
                engineHealth: EngineHealthStatus(state: .loaded, abiVersion: 1, message: "probe"),
                indexDirectoryResolver: AppOwnedIndexDirectoryResolver(applicationSupportRoot: supportURL),
                recentVaultStorage: ProbeRecentVaultStorage(),
                startupVaultRestoreStorage: ProbeStartupVaultRestoreStorage(),
                workspaceTabSessionStore: ProbeWorkspaceTabSessionStore(),
                readClientFactory: ProbeReadClientFactory(clients: [firstClient, secondClient]).make,
                readIndexRebuilder: ProbeReadIndexRebuilder(),
                readIndexRecoveryScheduler: scheduler
            )

            try state.selectVault(outcome.vaultURL)
            let initialNoteOpened = state.openFile(outcome.initialNote, disposition: .currentTab)
            state.updateEditorDirtyState(file: outcome.initialNote, isDirty: true)

            let createdNote = try VaultItemCreator().createNote(
                vaultURL: outcome.vaultURL,
                parentFolderPath: "",
                name: "Second"
            )
            state.registerCreatedFileTreeItem(createdNote)
            _ = state.openFile(createdNote, disposition: state.isActiveEditorDirty ? .newTab : .currentTab)

            let folderPath = try VaultItemCreator().createFolder(
                vaultURL: outcome.vaultURL,
                parentFolderPath: "",
                name: "Empty Folder"
            )
            state.registerCreatedFileTreeFolder(path: folderPath)
            let folderOverlayVisible = state.fileTreeOverlayFolderPaths.contains(folderPath)

            let generationBeforeRebuild = state.readGeneration
            let rebuildScheduled = state.requestCurrentVaultIndexRebuild()
            scheduler.runNext()

            let report = VaultCreationProbeReport(
                vaultCreated: FileManager.default.fileExists(
                    atPath: outcome.vaultURL.appendingPathComponent("Untitled.md").path
                ),
                initialNoteOpened: initialNoteOpened && state.workspaceTabs.first?.file == outcome.initialNote,
                noteCreationPreservesDirtyTab: state.workspaceTabs.map(\.file) == [outcome.initialNote, createdNote]
                    && state.isEditorDirty(file: outcome.initialNote),
                folderOverlayVisible: folderOverlayVisible,
                indexRebuildRefreshesGeneration: rebuildScheduled
                    && scheduler.pendingWorkCount == 0
                    && state.readGeneration == generationBeforeRebuild + 1,
                outputRedacted: true,
                temporaryCleanup: cleanup(root)
            )
            return report
        } catch {
            return VaultCreationProbeReport(
                vaultCreated: false,
                initialNoteOpened: false,
                noteCreationPreservesDirtyTab: false,
                folderOverlayVisible: false,
                indexRebuildRefreshesGeneration: false,
                outputRedacted: true,
                temporaryCleanup: cleanup(root)
            )
        }
    }

    static func encodedReport(_ report: VaultCreationProbeReport = run()) -> String {
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

private final class ProbeReadClientFactory: @unchecked Sendable {
    private var clients: [ProbeReadClient]

    init(clients: [ProbeReadClient]) {
        self.clients = clients
    }

    func make(metadataURL: URL, tantivyURL: URL) throws -> any EngineReading {
        clients.removeFirst()
    }
}

private final class ProbeReadClient: EngineReading, @unchecked Sendable {
    func close() {}

    func fileTree(requestID: UInt64, offset: Int, limit: Int) async throws -> FileTreeSnapshot {
        FileTreeSnapshot(items: [], state: .complete)
    }

    func search(query: String, mode: SearchMode, page: SearchPageRequest) async throws -> SearchPage {
        SearchPage(requestID: page.requestID, items: [], nextOffset: nil, state: .complete)
    }

    func inspectorPanel(
        file: FileTreeItem,
        panel: EngineReadInspectorPanel,
        requestID: UInt64,
        offset: Int,
        limit: Int
    ) async throws -> EngineReadInspectorPanelResult {
        switch panel {
        case .backlinks:
            return .backlinks([])
        case .outgoing:
            return .outgoing([])
        case .tags:
            return .tags([])
        case .properties:
            return .properties([])
        case .attachments:
            return .attachments([])
        }
    }

    func localGraph(file: FileTreeItem, requestID: UInt64, request: LocalGraphRequest) async throws -> LocalGraphSnapshot {
        LocalGraphSnapshot(centerNodeID: file.id, nodes: [], edges: [], state: .complete)
    }

    func livePreviewMetadata(file: FileTreeItem, requestID: UInt64, contents: String) async throws -> EngineLivePreviewMetadata {
        EngineLivePreviewMetadata(outgoingLinks: [], attachments: [])
    }
}

private struct ProbeReadIndexRebuilder: ReadIndexRebuilding {
    func rebuildIndex(vaultURL: URL, location: AppOwnedIndexLocation) throws {}
}

private final class ProbeReadIndexRecoveryScheduler: ReadIndexRecoveryScheduling, @unchecked Sendable {
    private var scheduledWork: [@Sendable () -> Void] = []

    var pendingWorkCount: Int {
        scheduledWork.count
    }

    func schedule(
        _ work: @escaping @Sendable () -> Result<Void, any Error>,
        completion: @escaping @Sendable (Result<Void, any Error>) -> Void
    ) {
        scheduledWork.append {
            completion(work())
        }
    }

    func runNext() {
        guard !scheduledWork.isEmpty else {
            return
        }
        scheduledWork.removeFirst()()
    }
}

private struct ProbeRecentVaultStorage: RecentVaultStoring {
    func loadRecentVaultURLs() -> [URL] { [] }
    func saveRecentVaultURLs(_ urls: [URL]) {}
}

private struct ProbeStartupVaultRestoreStorage: StartupVaultRestoreStoring {
    func loadSuppressesLastVaultRestore() -> Bool { false }
    func saveSuppressesLastVaultRestore(_ value: Bool) {}
}

private struct ProbeWorkspaceTabSessionStore: WorkspaceTabSessionStoring {
    func loadSession(forVaultAt vaultURL: URL) -> WorkspaceTabSession? { nil }
    func saveSession(_ session: WorkspaceTabSession, forVaultAt vaultURL: URL) {}
    func clearSession(forVaultAt vaultURL: URL) {}
}
