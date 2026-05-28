import Foundation
import NativeMarkdownCore

struct StartupVaultRestoreProbeReport: Codable, Equatable {
    let validRestore: Bool
    let suppressedSkip: Bool
    let missingUnavailable: Bool
    let currentRemovalSuppressesOlder: Bool
    let tabSessionRestore: Bool
    let temporaryCleanup: Bool

    var passed: Bool {
        validRestore
            && suppressedSkip
            && missingUnavailable
            && currentRemovalSuppressesOlder
            && tabSessionRestore
            && temporaryCleanup
    }
}

@MainActor
enum StartupVaultRestoreProbe {
    static func run() -> StartupVaultRestoreProbeReport {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let validRestore = try probeValidRestore(root: root.appendingPathComponent("valid", isDirectory: true))
            let suppressedSkip = try probeSuppressedSkip(root: root.appendingPathComponent("suppressed", isDirectory: true))
            let missingUnavailable = try probeMissingUnavailable(root: root.appendingPathComponent("missing", isDirectory: true))
            let currentRemovalSuppressesOlder = probeCurrentRemovalSuppressesOlder()
            let tabSessionRestore = try probeTabSessionRestore(root: root.appendingPathComponent("tabs", isDirectory: true))
            let temporaryCleanup = cleanup(root)
            return StartupVaultRestoreProbeReport(
                validRestore: validRestore,
                suppressedSkip: suppressedSkip,
                missingUnavailable: missingUnavailable,
                currentRemovalSuppressesOlder: currentRemovalSuppressesOlder,
                tabSessionRestore: tabSessionRestore,
                temporaryCleanup: temporaryCleanup
            )
        } catch {
            let temporaryCleanup = cleanup(root)
            return StartupVaultRestoreProbeReport(
                validRestore: false,
                suppressedSkip: false,
                missingUnavailable: false,
                currentRemovalSuppressesOlder: false,
                tabSessionRestore: false,
                temporaryCleanup: temporaryCleanup
            )
        }
    }

    static func encodedReport(_ report: StartupVaultRestoreProbeReport = run()) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report),
              let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }

    private static func probeValidRestore(root: URL) throws -> Bool {
        let vaultURL = root.appendingPathComponent("vault", isDirectory: true)
        let supportURL = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        let state = AppState(
            engineHealth: EngineHealthStatus(state: .loaded, abiVersion: 1, message: "probe"),
            indexDirectoryResolver: AppOwnedIndexDirectoryResolver(applicationSupportRoot: supportURL),
            vaultAccessValidator: StartupProbeVaultAccessValidator(),
            recentVaultStorage: StartupProbeRecentVaultStorage(urls: [vaultURL]),
            startupVaultRestoreStorage: StartupProbeRestoreStorage(),
            readClientFactory: { _, _ in StartupProbeReadClient() }
        )

        return try state.restoreLastVaultOnLaunchIfNeeded()
            && state.vaultSelection == .selected(vaultURL)
            && state.recentVaults.map(\.url) == [vaultURL]
    }

    private static func probeSuppressedSkip(root: URL) throws -> Bool {
        let vaultURL = root.appendingPathComponent("vault", isDirectory: true)
        let restoreStorage = StartupProbeRestoreStorage(suppresses: true)
        let state = AppState(
            recentVaultStorage: StartupProbeRecentVaultStorage(urls: [vaultURL]),
            startupVaultRestoreStorage: restoreStorage
        )

        return try state.restoreLastVaultOnLaunchIfNeeded() == false
            && state.vaultSelection == .noVault
            && restoreStorage.suppresses
    }

    private static func probeMissingUnavailable(root: URL) throws -> Bool {
        let missingVaultURL = root.appendingPathComponent("missing-vault", isDirectory: true)
        let supportURL = root.appendingPathComponent("support", isDirectory: true)
        let state = AppState(
            engineHealth: EngineHealthStatus(state: .loaded, abiVersion: 1, message: "probe"),
            indexDirectoryResolver: AppOwnedIndexDirectoryResolver(applicationSupportRoot: supportURL),
            vaultAccessValidator: FileSystemVaultAccessValidator(),
            recentVaultStorage: StartupProbeRecentVaultStorage(urls: [missingVaultURL]),
            startupVaultRestoreStorage: StartupProbeRestoreStorage()
        )

        return try state.restoreLastVaultOnLaunchIfNeeded()
            && state.vaultSelection == .unavailable(.missing(missingVaultURL))
            && state.indexLocation == nil
            && !FileManager.default.fileExists(atPath: supportURL.path)
    }

    private static func probeCurrentRemovalSuppressesOlder() -> Bool {
        let current = URL(fileURLWithPath: "/tmp/startup-current-vault", isDirectory: true)
        let older = URL(fileURLWithPath: "/tmp/startup-older-vault", isDirectory: true)
        let restoreStorage = StartupProbeRestoreStorage()
        let state = AppState(
            vaultSelection: .selected(current),
            recentVaultStorage: StartupProbeRecentVaultStorage(urls: [current, older]),
            startupVaultRestoreStorage: restoreStorage
        )

        state.removeRecentVault(at: current)

        let restoreAttempt = (try? state.restoreLastVaultOnLaunchIfNeeded()) ?? true
        return state.vaultSelection == .noVault
            && state.recentVaults.map(\.url) == [older]
            && restoreStorage.suppresses
            && !restoreAttempt
    }

    private static func probeTabSessionRestore(root: URL) throws -> Bool {
        let vaultURL = root.appendingPathComponent("vault", isDirectory: true)
        let supportURL = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        try "first".write(to: vaultURL.appendingPathComponent("First.md"), atomically: true, encoding: .utf8)
        try "second".write(to: vaultURL.appendingPathComponent("Second.md"), atomically: true, encoding: .utf8)

        let tabStore = StartupProbeTabSessionStore(sessions: [
            sessionKey(for: vaultURL): WorkspaceTabSession(
                tabs: ["Missing.md", "First.md", "Second.md"],
                activeRelativePath: "Second.md"
            )
        ])
        let state = AppState(
            engineHealth: EngineHealthStatus(state: .loaded, abiVersion: 1, message: "probe"),
            indexDirectoryResolver: AppOwnedIndexDirectoryResolver(applicationSupportRoot: supportURL),
            vaultAccessValidator: StartupProbeVaultAccessValidator(),
            recentVaultStorage: StartupProbeRecentVaultStorage(urls: [vaultURL]),
            startupVaultRestoreStorage: StartupProbeRestoreStorage(),
            workspaceTabSessionStore: tabStore,
            readClientFactory: { _, _ in StartupProbeReadClient() }
        )

        return try state.restoreLastVaultOnLaunchIfNeeded()
            && state.workspaceTabs.map(\.relativePathKey) == ["First.md", "Second.md"]
            && state.selectedFile == FileTreeItem(relativePath: "Second.md")
    }

    private static func cleanup(_ root: URL) -> Bool {
        do {
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
            return !FileManager.default.fileExists(atPath: root.path)
        } catch {
            return false
        }
    }

    private static func sessionKey(for vaultURL: URL) -> String {
        vaultURL.standardizedFileURL.path
    }
}

private struct StartupProbeVaultAccessValidator: VaultAccessValidating {
    func validateVault(at url: URL) -> VaultAccessIssue? {
        nil
    }
}

private final class StartupProbeRecentVaultStorage: RecentVaultStoring {
    private var urls: [URL]

    init(urls: [URL] = []) {
        self.urls = urls
    }

    func loadRecentVaultURLs() -> [URL] {
        urls
    }

    func saveRecentVaultURLs(_ urls: [URL]) {
        self.urls = urls
    }
}

private final class StartupProbeRestoreStorage: StartupVaultRestoreStoring {
    var suppresses: Bool

    init(suppresses: Bool = false) {
        self.suppresses = suppresses
    }

    func loadSuppressesLastVaultRestore() -> Bool {
        suppresses
    }

    func saveSuppressesLastVaultRestore(_ value: Bool) {
        suppresses = value
    }
}

private final class StartupProbeTabSessionStore: WorkspaceTabSessionStoring {
    private var sessions: [String: WorkspaceTabSession]

    init(sessions: [String: WorkspaceTabSession]) {
        self.sessions = sessions
    }

    func loadSession(forVaultAt vaultURL: URL) -> WorkspaceTabSession? {
        sessions[vaultURL.standardizedFileURL.path]
    }

    func saveSession(_ session: WorkspaceTabSession, forVaultAt vaultURL: URL) {
        sessions[vaultURL.standardizedFileURL.path] = session
    }

    func clearSession(forVaultAt vaultURL: URL) {
        sessions.removeValue(forKey: vaultURL.standardizedFileURL.path)
    }
}

private final class StartupProbeReadClient: EngineReading, @unchecked Sendable {
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

    func livePreviewMetadata(
        file: FileTreeItem,
        requestID: UInt64,
        contents: String
    ) async throws -> EngineLivePreviewMetadata {
        EngineLivePreviewMetadata(outgoingLinks: [], attachments: [])
    }
}
