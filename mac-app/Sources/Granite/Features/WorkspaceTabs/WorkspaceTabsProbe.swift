import AppKit
import Foundation
import NativeMarkdownCore

struct WorkspaceTabsProbeReport: Codable, Equatable {
    static let expectedRestoredTabCap = 25

    let open: Bool
    let reuse: Bool
    let dirtySwitch: Bool
    let closeDirtyWarning: Bool
    let restoreClosed: Bool
    let sessionRestore: Bool
    let shortcutSelection: Bool
    let commandRegistryRequiresKeyWindow: Bool
    let emptyActiveDirtyMounted: Bool
    let sessionCap: Bool
    let openTabCount: Int
    let mountedEditorBudget: Int
    let mountedEditorCount: Int
    let dirtyMountedCount: Int
    let cleanMountedCount: Int
    let cleanInactiveMountedCount: Int
    let restoredPathCount: Int
    let skippedPathCount: Int
    let tabSwitchP50Milliseconds: Double
    let tabSwitchP95Milliseconds: Double
    let restoreDurationMilliseconds: Double
    let activeEventCount: Int
    let inactiveEventCount: Int
    let suppressedInactiveEventCount: Int

    var passed: Bool {
        open && reuse && dirtySwitch && closeDirtyWarning && restoreClosed
            && sessionRestore && shortcutSelection && sessionCap
            && commandRegistryRequiresKeyWindow
            && emptyActiveDirtyMounted
            && mountedEditorBudget == WorkspaceMountedEditorPlanner.cleanInactiveBudget
            && mountedEditorCount <= mountedEditorBudget + dirtyMountedCount + 1
            && cleanInactiveMountedCount <= mountedEditorBudget
            && restoredPathCount == Self.expectedRestoredTabCap
            && skippedPathCount > 0
            && tabSwitchP95Milliseconds < 100
            && restoreDurationMilliseconds < 1_000
            && activeEventCount == WorkspaceEditorActivityEvent.allCases.count
            && inactiveEventCount == 0
            && suppressedInactiveEventCount == WorkspaceEditorActivityEvent.allCases.count
    }
}

@MainActor
enum WorkspaceTabsProbe {
    static func run() -> WorkspaceTabsProbeReport {
        let first = FileTreeItem(relativePath: "First.md")
        let second = FileTreeItem(relativePath: "Second.md")
        let third = FileTreeItem(relativePath: "Third.md")
        let state = AppState()

        state.openFile(first)
        let open = state.workspaceTabs.map(\.file) == [first] && state.selectedFile == first

        state.openFile(second, disposition: .newTab)
        state.openFile(first, disposition: .newTab)
        let reuse = state.workspaceTabs.map(\.file) == [first, second] && state.selectedFile == first

        state.updateEditorDirtyState(file: first, isDirty: true)
        let dirtySwitch = state.openFile(third) == false
            && state.selectedFile == first
            && state.openFile(third, disposition: .newTab)
            && state.isEditorDirty(file: first)

        let firstTabID = state.workspaceTabs[0].id
        let closeDirtyWarning = state.requestCloseTab(firstTabID) == false
            && state.dirtyTabCloseWarning?.dirtyFile == first
        state.dismissDirtyTabCloseWarning()

        state.activateTab(atShortcutIndex: 2)
        let shortcutSelection = state.selectedFile == second
        state.requestCloseActiveTab()
        state.restoreRecentlyClosedTab()
        let restoreClosed = state.workspaceTabs.map(\.file).contains(second)

        let session = runSessionRestoreProbe()
        let commandRegistryRequiresKeyWindow = runCommandRegistryProbe()
        let mounted = runMountedEditorProbe()
        let emptyActiveDirtyMounted = runEmptyActiveDirtyMountedProbe()
        let switchTimings = runTabSwitchProbe()
        let eventCounters = runInactiveEventProbe()

        return WorkspaceTabsProbeReport(
            open: open,
            reuse: reuse,
            dirtySwitch: dirtySwitch,
            closeDirtyWarning: closeDirtyWarning,
            restoreClosed: restoreClosed,
            sessionRestore: session.restoredActive,
            shortcutSelection: shortcutSelection,
            commandRegistryRequiresKeyWindow: commandRegistryRequiresKeyWindow,
            emptyActiveDirtyMounted: emptyActiveDirtyMounted,
            sessionCap: session.capped,
            openTabCount: mounted.openTabCount,
            mountedEditorBudget: WorkspaceMountedEditorPlanner.cleanInactiveBudget,
            mountedEditorCount: mounted.mountedEditorCount,
            dirtyMountedCount: mounted.dirtyMountedCount,
            cleanMountedCount: mounted.cleanMountedCount,
            cleanInactiveMountedCount: mounted.cleanInactiveMountedCount,
            restoredPathCount: session.restoredPathCount,
            skippedPathCount: session.skippedPathCount,
            tabSwitchP50Milliseconds: switchTimings.p50,
            tabSwitchP95Milliseconds: switchTimings.p95,
            restoreDurationMilliseconds: session.restoreDurationMilliseconds,
            activeEventCount: eventCounters.activeEventCount,
            inactiveEventCount: eventCounters.inactiveEventCount,
            suppressedInactiveEventCount: eventCounters.suppressedInactiveEventCount
        )
    }

    static func encodedReport(_ report: WorkspaceTabsProbeReport = run()) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report),
              let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }

    private static func runSessionRestoreProbe() -> (
        restoredActive: Bool,
        capped: Bool,
        restoredPathCount: Int,
        skippedPathCount: Int,
        restoreDurationMilliseconds: Double
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let vaultURL = root.appendingPathComponent("vault", isDirectory: true)
        let supportURL = root.appendingPathComponent("support", isDirectory: true)
        try? FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let paths = (0..<40).map { "Note-\($0).md" }
        for path in paths {
            try? path.write(to: vaultURL.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }

        let sessionStore = ProbeWorkspaceTabSessionStore(sessions: [
            sessionKey(for: vaultURL): WorkspaceTabSession(
                tabs: paths,
                activeRelativePath: "Note-30.md"
            )
        ])
        let state = AppState(
            engineHealth: EngineHealthStatus(state: .loaded, abiVersion: 1, message: "probe"),
            indexDirectoryResolver: AppOwnedIndexDirectoryResolver(applicationSupportRoot: supportURL),
            vaultAccessValidator: ProbeVaultAccessValidator(),
            recentVaultStorage: ProbeRecentVaultStorage(),
            workspaceTabSessionStore: sessionStore,
            readClientFactory: { _, _ in ProbeReadClient() }
        )

        do {
            let start = CFAbsoluteTimeGetCurrent()
            try state.selectVault(vaultURL)
            let duration = (CFAbsoluteTimeGetCurrent() - start) * 1_000
            let restoredPathCount = state.workspaceTabs.count
            let skippedPathCount = max(0, paths.count - restoredPathCount)
            return (
                restoredActive: state.selectedFile == FileTreeItem(relativePath: "Note-30.md"),
                capped: restoredPathCount == WorkspaceTabsProbeReport.expectedRestoredTabCap,
                restoredPathCount: restoredPathCount,
                skippedPathCount: skippedPathCount,
                restoreDurationMilliseconds: duration
            )
        } catch {
            return (false, false, 0, paths.count, .infinity)
        }
    }

    private static func runMountedEditorProbe() -> WorkspaceMountedEditorPlan {
        let state = AppState()
        let files = (0..<30).map { FileTreeItem(relativePath: "Mounted-\($0).md") }
        for file in files {
            _ = state.openFile(file, disposition: .newTab)
        }
        state.updateEditorDirtyState(file: files[3], isDirty: true)
        state.updateEditorDirtyState(file: files[7], isDirty: true)

        return WorkspaceMountedEditorPlanner.reconcile(
            tabs: state.workspaceTabs,
            activeTabID: state.activeTabID,
            existingMountedTabIDs: state.workspaceTabs.map(\.id)
        ) { tab in
            guard let file = tab.file else {
                return false
            }
            return state.isEditorDirty(file: file)
        }
    }

    private static func runCommandRegistryProbe() -> Bool {
        let workspaceWindow = NSWindow()
        let otherWindow = NSWindow()
        var didInvoke = false
        let action = WorkspaceTabAction(
            isAvailable: true,
            newTab: {
                didInvoke = true
            },
            closeActiveTab: {},
            restoreClosedTab: {},
            activateNextTab: {},
            activatePreviousTab: {},
            activateTabAtShortcutIndex: { _ in }
        )

        WorkspaceTabCommandRegistry.shared.register(action: action, for: workspaceWindow)
        let blockedForOtherWindow = WorkspaceTabCommandRegistry.shared.action(for: otherWindow) == nil
        let allowedForWorkspaceWindow = WorkspaceTabCommandRegistry.shared.action(for: workspaceWindow) != nil
        WorkspaceTabCommandRegistry.shared.action(for: otherWindow)?.newTab()
        let didNotInvokeForOtherWindow = didInvoke == false
        WorkspaceTabCommandRegistry.shared.unregister(window: workspaceWindow)
        return blockedForOtherWindow && allowedForWorkspaceWindow && didNotInvokeForOtherWindow
    }

    private static func runEmptyActiveDirtyMountedProbe() -> Bool {
        let state = AppState()
        let dirtyFile = FileTreeItem(relativePath: "Dirty.md")
        _ = state.openFile(dirtyFile)
        let dirtyTabID = state.activeTabID
        state.updateEditorDirtyState(file: dirtyFile, isDirty: true)
        state.newEmptyTab()

        let plan = WorkspaceMountedEditorPlanner.reconcile(
            tabs: state.workspaceTabs,
            activeTabID: state.activeTabID,
            existingMountedTabIDs: dirtyTabID.map { [$0] } ?? []
        ) { tab in
            guard let file = tab.file else {
                return false
            }
            return state.isEditorDirty(file: file)
        }
        return dirtyTabID.map(plan.mountedTabIDs.contains) == true
    }

    private static func runTabSwitchProbe() -> (p50: Double, p95: Double) {
        let state = AppState()
        for index in 0..<30 {
            _ = state.openFile(FileTreeItem(relativePath: "Switch-\(index).md"), disposition: .newTab)
        }

        let timings = (0..<60).map { _ in
            let start = CFAbsoluteTimeGetCurrent()
            state.activateNextTab()
            return (CFAbsoluteTimeGetCurrent() - start) * 1_000
        }
        return (
            p50: percentile(timings, fraction: 0.50),
            p95: percentile(timings, fraction: 0.95)
        )
    }

    private static func runInactiveEventProbe() -> WorkspaceEditorActivityCounters {
        var counters = WorkspaceEditorActivityCounters()
        for event in WorkspaceEditorActivityEvent.allCases {
            _ = WorkspaceEditorActivityGate.shouldRun(event, isActive: false, counters: &counters)
            _ = WorkspaceEditorActivityGate.shouldRun(event, isActive: true, counters: &counters)
        }
        return counters
    }

    private static func percentile(_ values: [Double], fraction: Double) -> Double {
        guard !values.isEmpty else {
            return 0
        }
        let sorted = values.sorted()
        let boundedFraction = min(max(0, fraction), 1)
        let index = Int((Double(sorted.count - 1) * boundedFraction).rounded())
        return sorted[index]
    }

    private static func sessionKey(for vaultURL: URL) -> String {
        vaultURL.standardizedFileURL.path
    }
}

private struct ProbeVaultAccessValidator: VaultAccessValidating {
    func validateVault(at url: URL) -> VaultAccessIssue? {
        nil
    }
}

private final class ProbeRecentVaultStorage: RecentVaultStoring {
    private var urls: [URL] = []

    func loadRecentVaultURLs() -> [URL] {
        urls
    }

    func saveRecentVaultURLs(_ urls: [URL]) {
        self.urls = urls
    }
}

private final class ProbeWorkspaceTabSessionStore: WorkspaceTabSessionStoring {
    private var sessions: [String: WorkspaceTabSession]

    init(sessions: [String: WorkspaceTabSession]) {
        self.sessions = sessions
    }

    func loadSession(forVaultAt vaultURL: URL) -> WorkspaceTabSession? {
        sessions[sessionKey(for: vaultURL)]
    }

    func saveSession(_ session: WorkspaceTabSession, forVaultAt vaultURL: URL) {
        sessions[sessionKey(for: vaultURL)] = session
    }

    func clearSession(forVaultAt vaultURL: URL) {
        sessions.removeValue(forKey: sessionKey(for: vaultURL))
    }

    private func sessionKey(for vaultURL: URL) -> String {
        vaultURL.standardizedFileURL.path
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
