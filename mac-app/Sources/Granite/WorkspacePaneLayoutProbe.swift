import Foundation
import NativeMarkdownCore

struct WorkspacePaneLayoutProbeReport: Codable, Equatable {
    let defaultLayout: Bool
    let validVaultRestore: Bool
    let unavailableVaultRestore: Bool
    let widthClamp: Bool
    let collapsePersistence: Bool
    let graphRightPaneNonMutation: Bool
    let recentVaultRemovalCleanup: Bool

    var passed: Bool {
        defaultLayout
            && validVaultRestore
            && unavailableVaultRestore
            && widthClamp
            && collapsePersistence
            && graphRightPaneNonMutation
            && recentVaultRemovalCleanup
    }
}

@MainActor
enum WorkspacePaneLayoutProbe {
    static func run() -> WorkspacePaneLayoutProbeReport {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let defaultLayout = AppState().workspacePaneLayout == .default
            let validVaultRestore = try probeValidVaultRestore(root: root.appendingPathComponent("valid", isDirectory: true))
            let unavailableVaultRestore = try probeUnavailableVaultRestore(root: root.appendingPathComponent("unavailable", isDirectory: true))
            let widthClamp = probeWidthClamp()
            let collapsePersistence = probeCollapsePersistence()
            let graphRightPaneNonMutation = probeGraphRightPaneNonMutation()
            let recentVaultRemovalCleanup = probeRecentVaultRemovalCleanup()
            _ = cleanup(root)
            return WorkspacePaneLayoutProbeReport(
                defaultLayout: defaultLayout,
                validVaultRestore: validVaultRestore,
                unavailableVaultRestore: unavailableVaultRestore,
                widthClamp: widthClamp,
                collapsePersistence: collapsePersistence,
                graphRightPaneNonMutation: graphRightPaneNonMutation,
                recentVaultRemovalCleanup: recentVaultRemovalCleanup
            )
        } catch {
            _ = cleanup(root)
            return WorkspacePaneLayoutProbeReport(
                defaultLayout: false,
                validVaultRestore: false,
                unavailableVaultRestore: false,
                widthClamp: false,
                collapsePersistence: false,
                graphRightPaneNonMutation: false,
                recentVaultRemovalCleanup: false
            )
        }
    }

    static func encodedReport(_ report: WorkspacePaneLayoutProbeReport = run()) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report),
              let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }

    private static func probeValidVaultRestore(root: URL) throws -> Bool {
        let vaultURL = root.appendingPathComponent("vault", isDirectory: true)
        let supportURL = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        let layout = WorkspacePaneLayout(leftSidebarWidth: 333, rightSidebarWidth: 444, isLeftSidebarCollapsed: true)
        let store = ProbePaneLayoutStore(layouts: [probePaneLayoutKey(for: vaultURL): layout])
        let state = AppState(
            engineHealth: EngineHealthStatus(state: .loaded, abiVersion: 1, message: "probe"),
            indexDirectoryResolver: AppOwnedIndexDirectoryResolver(applicationSupportRoot: supportURL),
            vaultAccessValidator: ProbeVaultAccessValidator(),
            recentVaultStorage: ProbeRecentVaultStorage(),
            workspacePaneLayoutStore: store,
            readClientFactory: { _, _ in ProbeReadClient() }
        )

        try state.selectVault(vaultURL)
        return state.workspacePaneLayout == layout && store.saveCount == 0
    }

    private static func probeUnavailableVaultRestore(root: URL) throws -> Bool {
        let vaultURL = root.appendingPathComponent("missing-vault", isDirectory: true)
        let layout = WorkspacePaneLayout(leftSidebarWidth: 301, rightSidebarWidth: 402, isRightSidebarCollapsed: true)
        let store = ProbePaneLayoutStore(layouts: [probePaneLayoutKey(for: vaultURL): layout])
        let state = AppState(
            vaultAccessValidator: ProbeVaultAccessValidator(issue: .missing(vaultURL)),
            recentVaultStorage: ProbeRecentVaultStorage(),
            workspacePaneLayoutStore: store
        )

        try state.selectVault(vaultURL)
        return state.vaultSelection == .unavailable(.missing(vaultURL))
            && state.workspacePaneLayout == layout
            && store.saveCount == 0
    }

    private static func probeWidthClamp() -> Bool {
        let vaultURL = URL(fileURLWithPath: "/tmp/probe-pane-width", isDirectory: true)
        let store = ProbePaneLayoutStore()
        let state = AppState(vaultSelection: .selected(vaultURL), workspacePaneLayoutStore: store)

        state.setLeftSidebarWidth(80, availableWidth: 1_200)
        state.setRightSidebarWidth(900, availableWidth: 1_200)

        return state.workspacePaneLayout.leftSidebarWidth == WorkspacePaneLayout.minSidebarWidth
            && state.workspacePaneLayout.rightSidebarWidth == 640
            && store.saveCount == 2
    }

    private static func probeCollapsePersistence() -> Bool {
        let vaultURL = URL(fileURLWithPath: "/tmp/probe-pane-collapse", isDirectory: true)
        let store = ProbePaneLayoutStore()
        let state = AppState(vaultSelection: .selected(vaultURL), workspacePaneLayoutStore: store)

        state.setWorkspacePaneLayout(WorkspacePaneLayout(leftSidebarWidth: 333, rightSidebarWidth: 444))
        state.toggleLeftSidebarCollapsed()
        state.toggleRightSidebarCollapsed()

        return state.workspacePaneLayout.leftSidebarWidth == 333
            && state.workspacePaneLayout.rightSidebarWidth == 444
            && state.workspacePaneLayout.isLeftSidebarCollapsed
            && state.workspacePaneLayout.isRightSidebarCollapsed
            && store.loadLayout(forVaultAt: vaultURL) == state.workspacePaneLayout
    }

    private static func probeGraphRightPaneNonMutation() -> Bool {
        let vaultURL = URL(fileURLWithPath: "/tmp/probe-pane-graph", isDirectory: true)
        let store = ProbePaneLayoutStore()
        let state = AppState(vaultSelection: .selected(vaultURL), workspacePaneLayoutStore: store)
        state.setWorkspacePaneLayout(WorkspacePaneLayout(leftSidebarWidth: 333, rightSidebarWidth: 444))
        let saveCount = store.saveCount

        state.openGraph(source: .ribbon)

        return state.workspaceSelection == .graph
            && !state.workspacePaneLayout.isRightSidebarCollapsed
            && state.workspacePaneLayout.rightSidebarWidth == 444
            && store.saveCount == saveCount
    }

    private static func probeRecentVaultRemovalCleanup() -> Bool {
        let vaultURL = URL(fileURLWithPath: "/tmp/probe-pane-forgotten", isDirectory: true)
        let otherURL = URL(fileURLWithPath: "/tmp/probe-pane-kept", isDirectory: true)
        let store = ProbePaneLayoutStore(layouts: [
            probePaneLayoutKey(for: vaultURL): WorkspacePaneLayout(leftSidebarWidth: 333, rightSidebarWidth: 444),
            probePaneLayoutKey(for: otherURL): WorkspacePaneLayout(leftSidebarWidth: 355, rightSidebarWidth: 466)
        ])
        let state = AppState(
            recentVaultStorage: ProbeRecentVaultStorage(urls: [vaultURL, otherURL]),
            workspacePaneLayoutStore: store
        )

        state.removeRecentVault(at: vaultURL)

        return store.loadLayout(forVaultAt: vaultURL) == nil
            && store.loadLayout(forVaultAt: otherURL) != nil
            && store.clearCount == 1
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

}

private func probePaneLayoutKey(for vaultURL: URL) -> String {
    vaultURL.standardizedFileURL.path
}

private struct ProbeVaultAccessValidator: VaultAccessValidating {
    var issue: VaultAccessIssue?

    init(issue: VaultAccessIssue? = nil) {
        self.issue = issue
    }

    func validateVault(at url: URL) -> VaultAccessIssue? {
        issue
    }
}

private final class ProbeRecentVaultStorage: RecentVaultStoring {
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

private final class ProbePaneLayoutStore: WorkspacePaneLayoutStoring {
    private var layouts: [String: WorkspacePaneLayout]
    private(set) var saveCount = 0
    private(set) var clearCount = 0

    init(layouts: [String: WorkspacePaneLayout] = [:]) {
        self.layouts = layouts
    }

    func loadLayout(forVaultAt vaultURL: URL) -> WorkspacePaneLayout? {
        layouts[probePaneLayoutKey(for: vaultURL)]
    }

    func saveLayout(_ layout: WorkspacePaneLayout, forVaultAt vaultURL: URL) {
        saveCount += 1
        layouts[probePaneLayoutKey(for: vaultURL)] = layout
    }

    func clearLayout(forVaultAt vaultURL: URL) {
        clearCount += 1
        layouts.removeValue(forKey: probePaneLayoutKey(for: vaultURL))
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

    func livePreviewMetadata(
        file: FileTreeItem,
        requestID: UInt64,
        contents: String
    ) async throws -> EngineLivePreviewMetadata {
        EngineLivePreviewMetadata(outgoingLinks: [], attachments: [])
    }
}
