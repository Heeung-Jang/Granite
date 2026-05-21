import Foundation
import Testing
@testable import NativeMarkdownCore

@Test
func appStateSelectsAndClearsVault() throws {
    let supportRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let recentStorage = MemoryRecentVaultStorage()
    let state = AppState(engineHealth: EngineHealthStatus(
        state: .loaded,
        abiVersion: 1,
        message: "test"
    ), indexDirectoryResolver: AppOwnedIndexDirectoryResolver(applicationSupportRoot: supportRoot), vaultAccessValidator: AllowingVaultAccessValidator(), recentVaultStorage: recentStorage)
    let url = URL(fileURLWithPath: "/tmp/example-vault", isDirectory: true)

    #expect(state.vaultSelection == .noVault)

    try state.selectVault(url)
    #expect(state.vaultSelection == .selected(url))
    #expect(state.indexLocation != nil)
    #expect(state.recentVaults.map(\.url) == [url])

    state.clearVault()
    #expect(state.vaultSelection == .noVault)
    #expect(state.indexLocation == nil)
    #expect(recentStorage.savedURLs == [url])
}

@Test
func appStateOpensReadClientForSelectedVault() throws {
    let supportRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let client = FakeReadClient()
    let factory = FakeReadClientFactory(clients: [client])
    let state = AppState(
        engineHealth: EngineHealthStatus(state: .loaded, abiVersion: 1, message: "test"),
        indexDirectoryResolver: AppOwnedIndexDirectoryResolver(applicationSupportRoot: supportRoot),
        vaultAccessValidator: AllowingVaultAccessValidator(),
        recentVaultStorage: MemoryRecentVaultStorage(),
        readClientFactory: factory.make
    )
    let vaultURL = URL(fileURLWithPath: "/tmp/read-vault", isDirectory: true)

    try state.selectVault(vaultURL)

    let location = try #require(state.indexLocation)
    #expect(factory.openedMetadataURLs == [location.metadataStoreFile])
    #expect(factory.openedTantivyURLs == [location.tantivyIndexDirectory])
    #expect(state.readAvailability == .ready)
    #expect((state.readClient as? FakeReadClient) === client)
    #expect(state.readGeneration == 1)
}

@Test
func appStatePublishesReadErrorWhenClientOpenFails() throws {
    let supportRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let factory = FakeReadClientFactory(error: FakeReadFactoryError.openFailed)
    let state = AppState(
        engineHealth: EngineHealthStatus(state: .loaded, abiVersion: 1, message: "test"),
        indexDirectoryResolver: AppOwnedIndexDirectoryResolver(applicationSupportRoot: supportRoot),
        vaultAccessValidator: AllowingVaultAccessValidator(),
        recentVaultStorage: MemoryRecentVaultStorage(),
        readClientFactory: factory.make
    )

    try state.selectVault(URL(fileURLWithPath: "/tmp/read-error-vault", isDirectory: true))

    #expect(state.readClient == nil)
    #expect(state.readAvailability == .error("openFailed"))
    #expect(state.readGeneration == 1)
}

@Test
func appStateClosesReadClientOnClearUnavailableAndStaleVault() throws {
    let supportRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let validator = MutableVaultAccessValidator()
    let firstClient = FakeReadClient()
    let factory = FakeReadClientFactory(clients: [firstClient])
    let state = AppState(
        engineHealth: EngineHealthStatus(state: .loaded, abiVersion: 1, message: "test"),
        indexDirectoryResolver: AppOwnedIndexDirectoryResolver(applicationSupportRoot: supportRoot),
        vaultAccessValidator: validator,
        recentVaultStorage: MemoryRecentVaultStorage(),
        readClientFactory: factory.make
    )
    let vaultURL = URL(fileURLWithPath: "/tmp/read-clear-vault", isDirectory: true)

    try state.selectVault(vaultURL)
    state.clearVault()

    #expect(firstClient.closeCount == 1)
    #expect(state.readClient == nil)
    #expect(state.readAvailability == .unavailable)
    #expect(state.readGeneration == 2)

    let secondClient = FakeReadClient()
    factory.clients = [secondClient]
    try state.selectVault(vaultURL)
    validator.issue = .denied(vaultURL)
    try state.selectVault(vaultURL)

    #expect(secondClient.closeCount == 1)
    #expect(state.readClient == nil)
    #expect(state.readAvailability == .unavailable)
    #expect(state.readGeneration == 4)

    validator.issue = nil
    let thirdClient = FakeReadClient()
    factory.clients = [thirdClient]
    try state.selectVault(vaultURL)
    state.markStaleBookmark(for: vaultURL)

    #expect(thirdClient.closeCount == 1)
    #expect(state.readClient == nil)
    #expect(state.readAvailability == .stale)
    #expect(state.readGeneration == 6)
}

@Test
func appStateClosesOldReadClientBeforeVaultSwitch() throws {
    let supportRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let firstClient = FakeReadClient()
    let secondClient = FakeReadClient()
    let factory = FakeReadClientFactory(clients: [firstClient, secondClient])
    let state = AppState(
        engineHealth: EngineHealthStatus(state: .loaded, abiVersion: 1, message: "test"),
        indexDirectoryResolver: AppOwnedIndexDirectoryResolver(applicationSupportRoot: supportRoot),
        vaultAccessValidator: AllowingVaultAccessValidator(),
        recentVaultStorage: MemoryRecentVaultStorage(),
        readClientFactory: factory.make
    )
    let firstURL = URL(fileURLWithPath: "/tmp/read-switch-first", isDirectory: true)
    let secondURL = URL(fileURLWithPath: "/tmp/read-switch-second", isDirectory: true)

    try state.selectVault(firstURL)
    let firstGeneration = state.readGeneration
    try state.selectVault(secondURL)

    #expect(firstClient.closeCount == 1)
    #expect(secondClient.closeCount == 0)
    #expect((state.readClient as? FakeReadClient) === secondClient)
    #expect(state.readGeneration != firstGeneration)
    #expect(state.readGeneration == 2)
    #expect(factory.openedMetadataURLs.count == 2)
}

@Test
func engineHealthDetectsAbiMismatch() {
    let status = EngineHealthStatus.evaluate(
        abiVersion: 2,
        expectedAbiVersion: 1,
        message: "test"
    )

    #expect(status.state == .abiMismatch)
    #expect(status.abiVersion == 2)
}

@Test
func appStatePublishesRequestedSearches() {
    let state = AppState()

    state.requestSearch(query: "#project/native", mode: .body)

    #expect(state.requestedSearch?.id == 1)
    #expect(state.requestedSearch?.query == "#project/native")
    #expect(state.requestedSearch?.mode == .body)
}

@Test
func workspaceSelectionComparesNoteIdentity() {
    let first = FileTreeItem(relativePath: "Folder/Note.md")
    let same = FileTreeItem(relativePath: "Folder/Note.md")
    let second = FileTreeItem(relativePath: "Folder/Other.md")

    #expect(WorkspaceSelection.empty == .empty)
    #expect(WorkspaceSelection.graph == .graph)
    #expect(WorkspaceSelection.note(first) == .note(same))
    #expect(WorkspaceSelection.note(first) != .note(second))
    #expect(WorkspaceSelection.note(first) != .graph)
}

@Test
func appStateSelectingGraphPreservesSelectedFileAndDirtyState() {
    let state = AppState()
    let file = FileTreeItem(relativePath: "Draft.md")

    #expect(state.openFile(file))
    state.updateEditorDirtyState(file: file, isDirty: true)

    state.openGraph(source: .ribbon)

    #expect(state.workspaceSelection == .graph)
    #expect(state.selectedFile == file)
    #expect(state.isEditorDirty(file: file))
    #expect(state.dirtyNavigationWarning == nil)
}

@Test
func appStateClosingGraphRestoresSelectedDirtyNote() {
    let state = AppState()
    let file = FileTreeItem(relativePath: "Draft.md")

    #expect(state.openFile(file))
    state.updateEditorDirtyState(file: file, isDirty: true)
    state.openGraph(source: .ribbon)

    #expect(state.closeWorkspaceSelection())

    #expect(state.workspaceSelection == .note(file))
    #expect(state.selectedFile == file)
    #expect(state.isEditorDirty(file: file))
}

@Test
func appStateDirtyNavigationFromGraphKeepsGraphSelectedWhenCancelled() {
    let state = AppState()
    let dirty = FileTreeItem(relativePath: "Dirty.md")
    let target = FileTreeItem(relativePath: "Target.md")

    #expect(state.openFile(dirty))
    state.updateEditorDirtyState(file: dirty, isDirty: true)
    state.openGraph(source: .keyboard)

    #expect(state.openFile(target) == false)
    #expect(state.workspaceSelection == .graph)
    #expect(state.selectedFile == dirty)

    state.dismissDirtyNavigationWarning()

    #expect(state.workspaceSelection == .graph)
    #expect(state.selectedFile == dirty)
}

@Test
func appStateDiscardingDirtyNavigationFromGraphOpensRequestedNote() {
    let state = AppState()
    let dirty = FileTreeItem(relativePath: "Dirty.md")
    let target = FileTreeItem(relativePath: "Target.md")

    #expect(state.openFile(dirty))
    state.updateEditorDirtyState(file: dirty, isDirty: true)
    state.openGraph(source: .keyboard)
    #expect(state.openFile(target) == false)

    state.discardDirtyChangesAndOpenRequestedFile()

    #expect(state.workspaceSelection == .note(target))
    #expect(state.selectedFile == target)
    #expect(!state.isEditorDirty(file: dirty))
}

@Test
func appStateDoesNotCloseDirtyNoteTabSilently() {
    let state = AppState()
    let file = FileTreeItem(relativePath: "Draft.md")

    #expect(state.openFile(file))
    state.updateEditorDirtyState(file: file, isDirty: true)

    state.closeWorkspaceSelection()

    #expect(state.workspaceSelection == .note(file))
    #expect(state.selectedFile == file)
    #expect(state.isEditorDirty(file: file))
}

@Test
func appStateBlocksCrossNoteNavigationWhileEditorIsDirty() {
    let state = AppState()
    let first = FileTreeItem(relativePath: "First.md")
    let second = FileTreeItem(relativePath: "Second.md")

    #expect(state.openFile(first))
    state.updateEditorDirtyState(file: first, isDirty: true)

    #expect(state.openFile(second) == false)
    #expect(state.selectedFile == first)
    #expect(state.dirtyNavigationWarning == DirtyNavigationWarning(
        dirtyFile: first,
        requestedFile: second
    ))

    state.dismissDirtyNavigationWarning()
    #expect(state.selectedFile == first)
    #expect(state.dirtyNavigationWarning == nil)
}

@Test
func appStateAllowsSameDirtyNoteAndCleanNavigation() {
    let state = AppState()
    let first = FileTreeItem(relativePath: "First.md")
    let second = FileTreeItem(relativePath: "Second.md")

    #expect(state.openFile(first))
    state.updateEditorDirtyState(file: first, isDirty: true)

    #expect(state.openFile(first))
    #expect(state.selectedFile == first)

    state.updateEditorDirtyState(file: first, isDirty: false)
    #expect(state.openFile(second))
    #expect(state.selectedFile == second)
    #expect(state.dirtyNavigationWarning == nil)
}

@Test
func appStateCreatesAndFillsEmptyWorkspaceTabs() {
    let state = AppState()
    let file = FileTreeItem(relativePath: "Codex/First.md")

    state.newEmptyTab()
    state.newEmptyTab()

    #expect(state.workspaceTabs.count == 1)
    #expect(state.activeTab?.isEmpty == true)
    #expect(state.selectedFile == nil)

    #expect(state.openFile(file))

    #expect(state.workspaceTabs.count == 1)
    #expect(state.activeFile == file)
    #expect(state.selectedFile == file)
    #expect(state.workspaceTabs[0].relativePathKey == "Codex/First.md")
}

@Test
func appStateOpensNewTabsAndReusesExistingFileTabs() {
    let state = AppState()
    let first = FileTreeItem(relativePath: "First.md")
    let second = FileTreeItem(relativePath: "Second.md")

    #expect(state.openFile(first))
    #expect(state.openFile(second, disposition: .newTab))
    #expect(state.workspaceTabs.map(\.file) == [first, second])
    #expect(state.selectedFile == second)

    #expect(state.openFile(first, disposition: .newTab))

    #expect(state.workspaceTabs.map(\.file) == [first, second])
    #expect(state.selectedFile == first)
    #expect(state.activeFile == first)
}

@Test
func appStateBlocksDirtyReplacementButAllowsNewTabOpen() {
    let state = AppState()
    let first = FileTreeItem(relativePath: "First.md")
    let second = FileTreeItem(relativePath: "Second.md")

    #expect(state.openFile(first))
    state.updateEditorDirtyState(file: first, isDirty: true)

    #expect(state.openFile(second) == false)
    #expect(state.workspaceTabs.map(\.file) == [first])
    #expect(state.selectedFile == first)
    #expect(state.dirtyNavigationWarning == DirtyNavigationWarning(dirtyFile: first, requestedFile: second))

    #expect(state.openFile(second, disposition: .newTab))
    #expect(state.workspaceTabs.map(\.file) == [first, second])
    #expect(state.selectedFile == second)
    #expect(state.isEditorDirty(file: first))
}

@Test
func appStateTracksMultipleDirtyTabsAndClearsOnlySavedFile() {
    let state = AppState()
    let first = FileTreeItem(relativePath: "First.md")
    let second = FileTreeItem(relativePath: "Second.md")

    #expect(state.openFile(first))
    #expect(state.openFile(second, disposition: .newTab))
    state.updateEditorDirtyState(file: first, isDirty: true)
    state.updateEditorDirtyState(file: second, isDirty: true)

    state.updateEditorDirtyState(file: second, isDirty: false)

    #expect(state.isEditorDirty(file: first))
    #expect(!state.isEditorDirty(file: second))
    #expect(state.requestAppQuit() == false)
    #expect(state.dirtyLifecycleWarning == DirtyLifecycleWarning(dirtyFile: first, action: .quitApp))
}

@Test
func appStateLifecycleWarningCountsMultipleDirtyTabs() {
    let state = AppState()
    let first = FileTreeItem(relativePath: "First.md")
    let second = FileTreeItem(relativePath: "Second.md")

    #expect(state.openFile(first))
    #expect(state.openFile(second, disposition: .newTab))
    state.updateEditorDirtyState(file: first, isDirty: true)
    state.updateEditorDirtyState(file: second, isDirty: true)

    #expect(state.requestAppQuit() == false)
    #expect(state.dirtyLifecycleWarning == DirtyLifecycleWarning(
        dirtyFile: first,
        action: .quitApp,
        dirtyCount: 2
    ))
    #expect(state.dirtyLifecycleWarning?.isAggregate == true)
}

@Test
func appStateClosesTabsWithNeighborSelectionAndRecentlyClosedRestore() {
    let state = AppState()
    let first = FileTreeItem(relativePath: "First.md")
    let second = FileTreeItem(relativePath: "Second.md")
    let third = FileTreeItem(relativePath: "Third.md")

    #expect(state.openFile(first))
    #expect(state.openFile(second, disposition: .newTab))
    #expect(state.openFile(third, disposition: .newTab))

    #expect(state.requestCloseTab(state.workspaceTabs[1].id))

    #expect(state.workspaceTabs.map(\.file) == [first, third])
    #expect(state.selectedFile == third)
    #expect(state.recentlyClosedTabs.last?.relativePathKey == "Second.md")

    state.restoreRecentlyClosedTab()

    #expect(state.workspaceTabs.map(\.file) == [first, second, third])
    #expect(state.selectedFile == second)
}

@Test
func appStateRestoresRecentlyClosedFinalTab() {
    let state = AppState()
    let file = FileTreeItem(relativePath: "Only.md")

    #expect(state.openFile(file))
    #expect(state.requestCloseActiveTab())

    #expect(state.workspaceTabs.isEmpty)
    #expect(state.selectedFile == nil)
    #expect(state.recentlyClosedTabs.last?.relativePathKey == "Only.md")

    state.restoreRecentlyClosedTab()

    #expect(state.workspaceTabs.map(\.file) == [file])
    #expect(state.selectedFile == file)
}

@Test
func appStateDirtyTabCloseWarningCanCancelOrDiscard() {
    let state = AppState()
    let first = FileTreeItem(relativePath: "First.md")
    let second = FileTreeItem(relativePath: "Second.md")

    #expect(state.openFile(first))
    #expect(state.openFile(second, disposition: .newTab))
    let firstTabID = state.workspaceTabs[0].id
    state.updateEditorDirtyState(file: first, isDirty: true)

    #expect(state.requestCloseTab(firstTabID) == false)
    #expect(state.dirtyTabCloseWarning == DirtyTabCloseWarning(tabID: firstTabID, dirtyFile: first))
    state.dismissDirtyTabCloseWarning()
    #expect(state.workspaceTabs.map(\.file) == [first, second])
    #expect(state.isEditorDirty(file: first))

    #expect(state.requestCloseTab(firstTabID) == false)
    #expect(state.discardDirtyChangesForTabCloseWarning())

    #expect(state.workspaceTabs.map(\.file) == [second])
    #expect(!state.isEditorDirty(file: first))
}

@Test
func appStateMovesAndActivatesTabsByShortcutIndex() {
    let state = AppState()
    let first = FileTreeItem(relativePath: "First.md")
    let second = FileTreeItem(relativePath: "Second.md")
    let third = FileTreeItem(relativePath: "Third.md")

    #expect(state.openFile(first))
    #expect(state.openFile(second, disposition: .newTab))
    #expect(state.openFile(third, disposition: .newTab))

    state.moveTab(from: 2, to: 0)
    #expect(state.workspaceTabs.map(\.file) == [third, first, second])
    #expect(state.selectedFile == third)

    state.activateTab(atShortcutIndex: 2)
    #expect(state.selectedFile == first)
    state.activateTab(atShortcutIndex: 9)
    #expect(state.selectedFile == second)
    state.activateNextTab()
    #expect(state.selectedFile == third)
    state.activatePreviousTab()
    #expect(state.selectedFile == second)
}

@Test
func appStatePersistsNonEmptyWorkspaceTabs() {
    let vaultURL = URL(fileURLWithPath: "/tmp/tab-session-vault", isDirectory: true)
    let tabStore = MemoryWorkspaceTabSessionStore()
    let state = AppState(
        vaultSelection: .selected(vaultURL),
        workspaceTabSessionStore: tabStore
    )
    let first = FileTreeItem(relativePath: "First.md")
    let second = FileTreeItem(relativePath: "Second.md")

    state.newEmptyTab()
    #expect(tabStore.savedSessions[vaultURL.standardizedFileURL.path] == nil)

    #expect(state.openFile(first))
    #expect(state.openFile(second, disposition: .newTab))
    state.activateTab(atShortcutIndex: 1)

    #expect(tabStore.savedSessions[vaultURL.standardizedFileURL.path] == WorkspaceTabSession(
        tabs: ["First.md", "Second.md"],
        activeRelativePath: "First.md"
    ))
}

@Test
func appStateRestoresPersistedWorkspaceTabsAfterVaultSelection() throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let vaultURL = temporaryRoot.appendingPathComponent("vault", isDirectory: true)
    let supportRoot = temporaryRoot.appendingPathComponent("support", isDirectory: true)
    try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
    try "a".write(to: vaultURL.appendingPathComponent("First.md"), atomically: true, encoding: .utf8)
    try "b".write(to: vaultURL.appendingPathComponent("Second.md"), atomically: true, encoding: .utf8)

    let tabStore = MemoryWorkspaceTabSessionStore(sessions: [
        RecentVault.storageKey(for: vaultURL): WorkspaceTabSession(
            tabs: ["Missing.md", "First.md", "Second.md"],
            activeRelativePath: "Second.md"
        )
    ])
    let state = AppState(
        engineHealth: EngineHealthStatus(state: .loaded, abiVersion: 1, message: "test"),
        indexDirectoryResolver: AppOwnedIndexDirectoryResolver(applicationSupportRoot: supportRoot),
        vaultAccessValidator: AllowingVaultAccessValidator(),
        recentVaultStorage: MemoryRecentVaultStorage(),
        workspaceTabSessionStore: tabStore
    )

    try state.selectVault(vaultURL)

    #expect(state.workspaceTabs.map(\.relativePathKey) == ["First.md", "Second.md"])
    #expect(state.selectedFile == FileTreeItem(relativePath: "Second.md"))
}

@Test
func appStateCapsRestoredWorkspaceTabsAroundActivePath() throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let vaultURL = temporaryRoot.appendingPathComponent("vault", isDirectory: true)
    let supportRoot = temporaryRoot.appendingPathComponent("support", isDirectory: true)
    try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)

    let paths = (0..<40).map { "Note-\($0).md" }
    for path in paths {
        try path.write(to: vaultURL.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    let tabStore = MemoryWorkspaceTabSessionStore(sessions: [
        RecentVault.storageKey(for: vaultURL): WorkspaceTabSession(
            tabs: paths,
            activeRelativePath: "Note-30.md"
        )
    ])
    let state = AppState(
        engineHealth: EngineHealthStatus(state: .loaded, abiVersion: 1, message: "test"),
        indexDirectoryResolver: AppOwnedIndexDirectoryResolver(applicationSupportRoot: supportRoot),
        vaultAccessValidator: AllowingVaultAccessValidator(),
        recentVaultStorage: MemoryRecentVaultStorage(),
        workspaceTabSessionStore: tabStore
    )

    try state.selectVault(vaultURL)

    #expect(state.workspaceTabs.count == 25)
    #expect(state.workspaceTabs.map(\.relativePathKey).contains("Note-30.md"))
    #expect(state.selectedFile == FileTreeItem(relativePath: "Note-30.md"))
}

@Test
func appStateAvoidsDuplicateSessionWritesForNoOpActivationAndExistingOpen() {
    let vaultURL = URL(fileURLWithPath: "/tmp/tab-session-write-vault", isDirectory: true)
    let tabStore = MemoryWorkspaceTabSessionStore()
    let state = AppState(
        vaultSelection: .selected(vaultURL),
        workspaceTabSessionStore: tabStore
    )
    let first = FileTreeItem(relativePath: "First.md")

    #expect(state.openFile(first))
    #expect(tabStore.saveCount == 1)

    let activeTabID = state.workspaceTabs[0].id
    state.activateTab(id: activeTabID)
    #expect(tabStore.saveCount == 1)

    #expect(state.openFile(first))
    #expect(tabStore.saveCount == 1)
}

@Test
func appStateCapsRecentlyClosedTabs() {
    let state = AppState()

    for index in 0..<30 {
        #expect(state.openFile(FileTreeItem(relativePath: "Note-\(index).md"), disposition: .newTab))
        #expect(state.requestCloseActiveTab())
    }

    #expect(state.recentlyClosedTabs.count == 25)
    #expect(state.recentlyClosedTabs.first?.relativePathKey == "Note-5.md")
    #expect(state.recentlyClosedTabs.last?.relativePathKey == "Note-29.md")
}

@Test
func appStateCanDiscardDirtyChangesAndOpenRequestedNote() {
    let state = AppState()
    let first = FileTreeItem(relativePath: "First.md")
    let second = FileTreeItem(relativePath: "Second.md")

    #expect(state.openFile(first))
    state.updateEditorDirtyState(file: first, isDirty: true)
    #expect(state.openFile(second) == false)

    state.discardDirtyChangesAndOpenRequestedFile()

    #expect(state.selectedFile == second)
    #expect(state.dirtyNavigationWarning == nil)
    #expect(state.openFile(first))
}

@Test
func appStateClearsDirtyNavigationStateWhenVaultBecomesUnavailable() throws {
    let vaultURL = URL(fileURLWithPath: "/tmp/vault", isDirectory: true)
    let first = FileTreeItem(relativePath: "First.md")
    let second = FileTreeItem(relativePath: "Second.md")
    let state = AppState(
        engineHealth: EngineHealthStatus(state: .loaded, abiVersion: 1, message: "test"),
        vaultAccessValidator: FixedVaultAccessValidator(issue: .missing(vaultURL)),
        recentVaultStorage: MemoryRecentVaultStorage()
    )

    #expect(state.openFile(first))
    state.updateEditorDirtyState(file: first, isDirty: true)
    #expect(state.openFile(second) == false)

    try state.selectVault(vaultURL)

    #expect(state.selectedFile == nil)
    #expect(state.dirtyNavigationWarning == nil)
    #expect(state.openFile(second))
}

@Test
func appStateAllowsCleanLifecycleActions() {
    let state = AppState()

    #expect(state.requestWindowClose())
    #expect(state.requestAppQuit())
    #expect(state.dirtyLifecycleWarning == nil)
}

@Test
func appStateBlocksWindowCloseWhileEditorIsDirty() {
    let state = AppState()
    let file = FileTreeItem(relativePath: "Draft.md")

    #expect(state.openFile(file))
    state.updateEditorDirtyState(file: file, isDirty: true)

    #expect(state.requestWindowClose() == false)
    #expect(state.dirtyLifecycleWarning == DirtyLifecycleWarning(
        dirtyFile: file,
        action: .closeWindow
    ))

    state.dismissDirtyLifecycleWarning()
    #expect(state.dirtyLifecycleWarning == nil)
}

@Test
func appStateBlocksAppQuitWhileEditorIsDirty() {
    let state = AppState()
    let file = FileTreeItem(relativePath: "Draft.md")

    #expect(state.openFile(file))
    state.updateEditorDirtyState(file: file, isDirty: true)

    #expect(state.requestAppQuit() == false)
    #expect(state.dirtyLifecycleWarning == DirtyLifecycleWarning(
        dirtyFile: file,
        action: .quitApp
    ))
}

@Test
func appStateCanDiscardDirtyLifecycleWarning() {
    let state = AppState()
    let first = FileTreeItem(relativePath: "First.md")
    let second = FileTreeItem(relativePath: "Second.md")

    #expect(state.openFile(first))
    state.updateEditorDirtyState(file: first, isDirty: true)
    #expect(state.requestWindowClose() == false)

    #expect(state.discardDirtyChangesForLifecycleWarning() == .closeWindow)
    #expect(state.dirtyLifecycleWarning == nil)
    #expect(state.dirtyNavigationWarning == nil)
    #expect(state.openFile(second))
}

@Test
func appStateClearsCleanSelectedFile() {
    let state = AppState()
    let file = FileTreeItem(relativePath: "Draft.md")

    #expect(state.openFile(file))
    #expect(state.requestClearSelectedFile())

    #expect(state.selectedFile == nil)
    #expect(state.dirtyEditorActionWarning == nil)
}

@Test
func appStateClearsNoSelectedFileAsNoOp() {
    let state = AppState()

    #expect(state.requestClearSelectedFile())

    #expect(state.selectedFile == nil)
    #expect(state.dirtyEditorActionWarning == nil)
}

@Test
func appStateBlocksClearingDirtySelectedFile() {
    let state = AppState()
    let file = FileTreeItem(relativePath: "Draft.md")

    #expect(state.openFile(file))
    state.updateEditorDirtyState(file: file, isDirty: true)

    #expect(state.requestClearSelectedFile() == false)
    #expect(state.selectedFile == file)
    #expect(state.dirtyEditorActionWarning == DirtyEditorActionWarning(
        dirtyFile: file,
        action: .clearSelection
    ))

    state.dismissDirtyEditorActionWarning()
    #expect(state.selectedFile == file)
    #expect(state.dirtyEditorActionWarning == nil)
}

@Test
func appStateAllowsClearSelectionWhenDirtyFileIsNotSelected() {
    let state = AppState()
    let staleDirtyFile = FileTreeItem(relativePath: "Stale.md")
    let selectedFile = FileTreeItem(relativePath: "Selected.md")

    state.updateEditorDirtyState(file: staleDirtyFile, isDirty: true)
    #expect(state.openFile(selectedFile))

    #expect(state.requestClearSelectedFile())
    #expect(state.selectedFile == nil)
    #expect(state.dirtyEditorActionWarning == nil)
}

@Test
func appStateClosesCleanSelectedVault() {
    let vaultURL = URL(fileURLWithPath: "/tmp/clean-vault", isDirectory: true)
    let state = AppState(vaultSelection: .selected(vaultURL))
    let file = FileTreeItem(relativePath: "Clean.md")

    #expect(state.openFile(file))
    #expect(state.requestCloseVault())

    #expect(state.vaultSelection == .noVault)
    #expect(state.selectedFile == nil)
    #expect(state.dirtyEditorActionWarning == nil)
}

@Test
func appStateCloseVaultIsNoOpWithoutVault() {
    let state = AppState()

    #expect(state.requestCloseVault())

    #expect(state.vaultSelection == .noVault)
    #expect(state.dirtyEditorActionWarning == nil)
}

@Test
func appStateClosesUnavailableVault() {
    let vaultURL = URL(fileURLWithPath: "/tmp/missing-vault", isDirectory: true)
    let issue = VaultAccessIssue.missing(vaultURL)
    let state = AppState(vaultSelection: .unavailable(issue))

    #expect(state.requestCloseVault())

    #expect(state.vaultSelection == .noVault)
    #expect(state.dirtyEditorActionWarning == nil)
}

@Test
func appStateBlocksClosingVaultWithDirtySelectedFile() {
    let vaultURL = URL(fileURLWithPath: "/tmp/dirty-vault", isDirectory: true)
    let state = AppState(vaultSelection: .selected(vaultURL))
    let file = FileTreeItem(relativePath: "Dirty.md")

    #expect(state.openFile(file))
    state.updateEditorDirtyState(file: file, isDirty: true)

    #expect(state.requestCloseVault() == false)
    #expect(state.vaultSelection == .selected(vaultURL))
    #expect(state.selectedFile == file)
    #expect(state.dirtyEditorActionWarning == DirtyEditorActionWarning(
        dirtyFile: file,
        action: .closeVault
    ))

    state.dismissDirtyEditorActionWarning()
    #expect(state.vaultSelection == .selected(vaultURL))
    #expect(state.selectedFile == file)
    #expect(state.dirtyEditorActionWarning == nil)
}

@Test
func appStateBlocksClosingVaultWithAnyDirtyEditorFile() {
    let vaultURL = URL(fileURLWithPath: "/tmp/dirty-unselected-vault", isDirectory: true)
    let state = AppState(vaultSelection: .selected(vaultURL))
    let dirtyFile = FileTreeItem(relativePath: "Dirty.md")
    let selectedFile = FileTreeItem(relativePath: "Selected.md")

    state.updateEditorDirtyState(file: dirtyFile, isDirty: true)
    #expect(state.openFile(selectedFile))

    #expect(state.requestCloseVault() == false)
    #expect(state.vaultSelection == .selected(vaultURL))
    #expect(state.selectedFile == selectedFile)
    #expect(state.dirtyEditorActionWarning == DirtyEditorActionWarning(
        dirtyFile: dirtyFile,
        action: .closeVault
    ))
}

@Test
func appStateCloseVaultWarningCountsMultipleDirtyTabs() {
    let vaultURL = URL(fileURLWithPath: "/tmp/multi-dirty-vault", isDirectory: true)
    let state = AppState(vaultSelection: .selected(vaultURL))
    let first = FileTreeItem(relativePath: "First.md")
    let second = FileTreeItem(relativePath: "Second.md")

    #expect(state.openFile(first))
    #expect(state.openFile(second, disposition: .newTab))
    state.updateEditorDirtyState(file: first, isDirty: true)
    state.updateEditorDirtyState(file: second, isDirty: true)

    #expect(state.requestCloseVault() == false)
    #expect(state.dirtyEditorActionWarning == DirtyEditorActionWarning(
        dirtyFile: first,
        action: .closeVault,
        dirtyCount: 2
    ))
    #expect(state.dirtyEditorActionWarning?.isAggregate == true)
}

@Test
func appStateCanDiscardDirtyClearSelectionWarning() {
    let vaultURL = URL(fileURLWithPath: "/tmp/clear-vault", isDirectory: true)
    let state = AppState(vaultSelection: .selected(vaultURL))
    let file = FileTreeItem(relativePath: "Dirty.md")

    #expect(state.openFile(file))
    state.updateEditorDirtyState(file: file, isDirty: true)
    #expect(state.requestClearSelectedFile() == false)

    #expect(state.discardDirtyChangesForEditorActionWarning() == .clearSelection)

    #expect(state.vaultSelection == .selected(vaultURL))
    #expect(state.selectedFile == nil)
    #expect(state.dirtyEditorActionWarning == nil)
    #expect(state.isEditorDirty(file: file) == false)
}

@Test
func appStateCanDiscardDirtyCloseVaultWarning() {
    let vaultURL = URL(fileURLWithPath: "/tmp/discard-close-vault", isDirectory: true)
    let state = AppState(vaultSelection: .selected(vaultURL))
    let file = FileTreeItem(relativePath: "Dirty.md")

    #expect(state.openFile(file))
    state.updateEditorDirtyState(file: file, isDirty: true)
    #expect(state.requestCloseVault() == false)

    #expect(state.discardDirtyChangesForEditorActionWarning() == .closeVault)

    #expect(state.vaultSelection == .noVault)
    #expect(state.selectedFile == nil)
    #expect(state.dirtyEditorActionWarning == nil)
    #expect(state.isEditorDirty(file: file) == false)
}

@Test
func appStateDiscardDirtyEditorActionWithoutWarningIsSafe() {
    let state = AppState()

    #expect(state.discardDirtyChangesForEditorActionWarning() == nil)
}

@Test
func appStateKeepsOnlyEditorActionWarningAfterNavigationWarning() {
    let state = AppState()
    let first = FileTreeItem(relativePath: "First.md")
    let second = FileTreeItem(relativePath: "Second.md")

    #expect(state.openFile(first))
    state.updateEditorDirtyState(file: first, isDirty: true)
    #expect(state.openFile(second) == false)
    #expect(state.dirtyNavigationWarning != nil)

    #expect(state.requestClearSelectedFile() == false)

    #expect(state.dirtyNavigationWarning == nil)
    #expect(state.dirtyLifecycleWarning == nil)
    #expect(state.dirtyEditorActionWarning == DirtyEditorActionWarning(
        dirtyFile: first,
        action: .clearSelection
    ))
}

@Test
func appStateKeepsOnlyLifecycleWarningAfterEditorActionWarning() {
    let state = AppState()
    let file = FileTreeItem(relativePath: "Draft.md")

    #expect(state.openFile(file))
    state.updateEditorDirtyState(file: file, isDirty: true)
    #expect(state.requestClearSelectedFile() == false)

    #expect(state.requestWindowClose() == false)

    #expect(state.dirtyEditorActionWarning == nil)
    #expect(state.dirtyNavigationWarning == nil)
    #expect(state.dirtyLifecycleWarning == DirtyLifecycleWarning(
        dirtyFile: file,
        action: .closeWindow
    ))
}

@Test
func appStateClearsEditorActionWarningWhenDirtyFileBecomesClean() {
    let state = AppState()
    let file = FileTreeItem(relativePath: "Draft.md")

    #expect(state.openFile(file))
    state.updateEditorDirtyState(file: file, isDirty: true)
    #expect(state.requestClearSelectedFile() == false)

    state.updateEditorDirtyState(file: file, isDirty: false)

    #expect(state.dirtyEditorActionWarning == nil)
}

@Test
func appStateClearsEditorActionWarningWhenVaultChanges() throws {
    let vaultURL = URL(fileURLWithPath: "/tmp/new-vault", isDirectory: true)
    let file = FileTreeItem(relativePath: "Draft.md")
    let state = AppState(
        engineHealth: EngineHealthStatus(state: .loaded, abiVersion: 1, message: "test"),
        vaultAccessValidator: FixedVaultAccessValidator(issue: .missing(vaultURL)),
        recentVaultStorage: MemoryRecentVaultStorage()
    )

    #expect(state.openFile(file))
    state.updateEditorDirtyState(file: file, isDirty: true)
    #expect(state.requestClearSelectedFile() == false)

    try state.selectVault(vaultURL)

    #expect(state.selectedFile == nil)
    #expect(state.dirtyEditorActionWarning == nil)
}

@Test
func indexDirectoryResolverCreatesOnlyAppOwnedDirectories() throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let vaultURL = temporaryRoot.appendingPathComponent("vault", isDirectory: true)
    let supportRoot = temporaryRoot.appendingPathComponent("support", isDirectory: true)
    try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)

    let resolver = AppOwnedIndexDirectoryResolver(
        applicationSupportRoot: supportRoot,
        configuration: IndexConfiguration(
            schemaVersion: "schema/v1",
            backendVersion: "sqlite-fts/v1",
            tokenizerConfig: "unicode61 default"
        )
    )

    let location = try resolver.prepareIndexLocation(forVaultAt: vaultURL)

    #expect(location.rootDirectory.path.hasPrefix(supportRoot.path))
    #expect(location.dataDirectory.path.hasPrefix(supportRoot.path))
    #expect(location.metadataStoreFile.path == location.dataDirectory.appendingPathComponent("metadata.sqlite").path)
    #expect(location.tantivyIndexDirectory.path == location.dataDirectory.appendingPathComponent("tantivy").path)
    #expect(location.indexingQueueFile.path.hasPrefix(location.dataDirectory.path))
    #expect(location.metadataFile.path.hasPrefix(location.dataDirectory.path))
    #expect(location.metadataFile.lastPathComponent == "metadata.sqlite")
    #expect(location.rebuildDirectory.path.hasPrefix(supportRoot.path))
    #expect(location.lockFile.path.hasPrefix(supportRoot.path))
    #expect(FileManager.default.fileExists(atPath: location.dataDirectory.path))
    #expect(FileManager.default.fileExists(atPath: location.rebuildDirectory.path))
    #expect(!FileManager.default.fileExists(atPath: location.metadataStoreFile.path))
    #expect(!FileManager.default.fileExists(atPath: location.tantivyIndexDirectory.path))
    #expect(!FileManager.default.fileExists(atPath: location.lockFile.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: vaultURL.path).isEmpty)
    #expect(!location.rootDirectory.path.contains("schema/v1"))
    #expect(!location.rootDirectory.path.contains("sqlite-fts/v1"))
    #expect(!location.rootDirectory.path.contains("unicode61 default"))
}

@Test
func indexConfigurationDefaultsMatchSelectedReadBackend() {
    let configuration = IndexConfiguration()

    #expect(configuration.schemaVersion == "metadata-v1")
    #expect(configuration.backendVersion == "sqlite+tantivy")
    #expect(configuration.tokenizerConfig == "tantivy")
}

@Test
func indexDirectoryResolverKeepsLegacyConfigurationExplicit() throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let vaultURL = temporaryRoot.appendingPathComponent("vault", isDirectory: true)
    let supportRoot = temporaryRoot.appendingPathComponent("support", isDirectory: true)
    try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)

    let legacyConfiguration = IndexConfiguration(
        schemaVersion: "schema-v1",
        backendVersion: "backend-unselected-v1",
        tokenizerConfig: "tokenizer-default-v1"
    )
    let resolver = AppOwnedIndexDirectoryResolver(
        applicationSupportRoot: supportRoot,
        configuration: legacyConfiguration
    )

    let location = try resolver.prepareIndexLocation(forVaultAt: vaultURL)

    #expect(location.configuration == legacyConfiguration)
    #expect(location.rootDirectory.path.contains("schema-v1"))
    #expect(location.rootDirectory.path.contains("backend-unselected-v1"))
    #expect(location.rootDirectory.path.contains("tokenizer-default-v1"))
}

@Test
func indexDirectoryResolverUsesLegacyLocationWhenPreferredMetadataIsMissing() throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let vaultURL = temporaryRoot.appendingPathComponent("vault", isDirectory: true)
    let preferredRoot = temporaryRoot.appendingPathComponent("Granite", isDirectory: true)
    let legacyRoot = temporaryRoot.appendingPathComponent("NativeMarkdownMacApp", isDirectory: true)
    try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)

    let legacyLocation = try AppOwnedIndexDirectoryResolver(
        applicationSupportRoot: legacyRoot
    ).prepareIndexLocation(forVaultAt: vaultURL)
    try Data("legacy".utf8).write(to: legacyLocation.metadataStoreFile)

    let resolver = AppOwnedIndexDirectoryResolver(
        applicationSupportRoot: preferredRoot,
        legacyApplicationSupportRoots: [legacyRoot]
    )

    let location = try resolver.prepareIndexLocation(forVaultAt: vaultURL)

    #expect(location.rootDirectory.path == legacyLocation.rootDirectory.path)
    #expect(location.metadataStoreFile.path == legacyLocation.metadataStoreFile.path)
    #expect(!FileManager.default.fileExists(atPath: preferredRoot.path))
}

@Test
func indexDirectoryResolverPrefersGraniteLocationWhenMetadataExists() throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let vaultURL = temporaryRoot.appendingPathComponent("vault", isDirectory: true)
    let preferredRoot = temporaryRoot.appendingPathComponent("Granite", isDirectory: true)
    let legacyRoot = temporaryRoot.appendingPathComponent("NativeMarkdownMacApp", isDirectory: true)
    try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)

    let preferredLocation = try AppOwnedIndexDirectoryResolver(
        applicationSupportRoot: preferredRoot
    ).prepareIndexLocation(forVaultAt: vaultURL)
    try Data("preferred".utf8).write(to: preferredLocation.metadataStoreFile)

    let legacyLocation = try AppOwnedIndexDirectoryResolver(
        applicationSupportRoot: legacyRoot
    ).prepareIndexLocation(forVaultAt: vaultURL)
    try Data("legacy".utf8).write(to: legacyLocation.metadataStoreFile)

    let resolver = AppOwnedIndexDirectoryResolver(
        applicationSupportRoot: preferredRoot,
        legacyApplicationSupportRoots: [legacyRoot]
    )

    let location = try resolver.prepareIndexLocation(forVaultAt: vaultURL)

    #expect(location.rootDirectory.path == preferredLocation.rootDirectory.path)
    #expect(location.metadataStoreFile.path == preferredLocation.metadataStoreFile.path)
}

@Test
func indexDirectoryResolverRejectsSupportRootInsideVault() throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let vaultURL = temporaryRoot.appendingPathComponent("vault", isDirectory: true)
    try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
    let badSupportRoot = vaultURL.appendingPathComponent(".native-index", isDirectory: true)
    let resolver = AppOwnedIndexDirectoryResolver(applicationSupportRoot: badSupportRoot)

    var rejected = false
    do {
        _ = try resolver.prepareIndexLocation(forVaultAt: vaultURL)
    } catch IndexDirectoryError.applicationSupportInsideVault {
        rejected = true
    }

    #expect(rejected)
    #expect(try FileManager.default.contentsOfDirectory(atPath: vaultURL.path).isEmpty)
}

@Test
func indexDirectoryResolverRejectsLegacySupportRootInsideVault() throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let vaultURL = temporaryRoot.appendingPathComponent("vault", isDirectory: true)
    let supportRoot = temporaryRoot.appendingPathComponent("support", isDirectory: true)
    let badLegacyRoot = vaultURL.appendingPathComponent(".legacy-index", isDirectory: true)
    try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
    let resolver = AppOwnedIndexDirectoryResolver(
        applicationSupportRoot: supportRoot,
        legacyApplicationSupportRoots: [badLegacyRoot]
    )

    var rejected = false
    do {
        _ = try resolver.prepareIndexLocation(forVaultAt: vaultURL)
    } catch IndexDirectoryError.applicationSupportInsideVault {
        rejected = true
    }

    #expect(rejected)
    #expect(try FileManager.default.contentsOfDirectory(atPath: vaultURL.path).isEmpty)
}

@Test
func inaccessibleVaultStatesDoNotCreateIndexDirectories() throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let supportRoot = temporaryRoot.appendingPathComponent("support", isDirectory: true)
    let vaultURL = temporaryRoot.appendingPathComponent("vault", isDirectory: true)
    try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)

    for issue in [
        VaultAccessIssue.denied(vaultURL),
        VaultAccessIssue.readOnly(vaultURL),
        VaultAccessIssue.staleBookmark(vaultURL)
    ] {
        let state = AppState(
            engineHealth: EngineHealthStatus(state: .loaded, abiVersion: 1, message: "test"),
            indexDirectoryResolver: AppOwnedIndexDirectoryResolver(applicationSupportRoot: supportRoot),
            vaultAccessValidator: FixedVaultAccessValidator(issue: issue)
        )

        try state.selectVault(vaultURL)

        #expect(state.vaultSelection == .unavailable(issue))
        #expect(state.indexLocation == nil)
        #expect(!FileManager.default.fileExists(atPath: supportRoot.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: vaultURL.path).isEmpty)
    }
}

@Test
func missingVaultDoesNotCreateIndexDirectories() throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let supportRoot = temporaryRoot.appendingPathComponent("support", isDirectory: true)
    let missingVaultURL = temporaryRoot.appendingPathComponent("missing-vault", isDirectory: true)
    let state = AppState(
        engineHealth: EngineHealthStatus(state: .loaded, abiVersion: 1, message: "test"),
        indexDirectoryResolver: AppOwnedIndexDirectoryResolver(applicationSupportRoot: supportRoot),
        vaultAccessValidator: FileSystemVaultAccessValidator()
    )

    try state.selectVault(missingVaultURL)

    #expect(state.vaultSelection == .unavailable(.missing(missingVaultURL)))
    #expect(state.indexLocation == nil)
    #expect(!FileManager.default.fileExists(atPath: supportRoot.path))
}

@Test
func appStateCanRepresentStaleBookmark() {
    let state = AppState(
        engineHealth: EngineHealthStatus(state: .loaded, abiVersion: 1, message: "test"),
        vaultAccessValidator: AllowingVaultAccessValidator(),
        recentVaultStorage: MemoryRecentVaultStorage()
    )
    let url = URL(fileURLWithPath: "/tmp/stale-vault", isDirectory: true)

    state.markStaleBookmark(for: url)

    #expect(state.vaultSelection == .unavailable(.staleBookmark(url)))
    #expect(state.indexLocation == nil)
    #expect(state.recentVaults.map(\.url) == [url])
}

@Test
func appStatePersistsDeduplicatedRecentVaults() throws {
    let supportRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storage = MemoryRecentVaultStorage()
    let state = AppState(
        engineHealth: EngineHealthStatus(state: .loaded, abiVersion: 1, message: "test"),
        indexDirectoryResolver: AppOwnedIndexDirectoryResolver(applicationSupportRoot: supportRoot),
        vaultAccessValidator: AllowingVaultAccessValidator(),
        recentVaultStorage: storage,
        maxRecentVaults: 2
    )
    let first = URL(fileURLWithPath: "/tmp/first-vault", isDirectory: true)
    let second = URL(fileURLWithPath: "/tmp/second-vault", isDirectory: true)
    let third = URL(fileURLWithPath: "/tmp/third-vault", isDirectory: true)

    try state.selectVault(first)
    try state.selectVault(second)
    try state.selectVault(first)
    try state.selectVault(third)

    #expect(state.recentVaults.map(\.url) == [third, first])
    #expect(storage.savedURLs == [third, first])
}

@Test
func appStateRemovingRecentVaultClearsStoredTabSession() {
    let vaultURL = URL(fileURLWithPath: "/tmp/session-forgotten-vault", isDirectory: true)
    let recentStorage = MemoryRecentVaultStorage(urls: [vaultURL])
    let tabStore = MemoryWorkspaceTabSessionStore(sessions: [
        RecentVault.storageKey(for: vaultURL): WorkspaceTabSession(
            tabs: ["A.md"],
            activeRelativePath: "A.md"
        )
    ])
    let state = AppState(
        recentVaultStorage: recentStorage,
        workspaceTabSessionStore: tabStore
    )

    state.removeRecentVault(at: vaultURL)

    #expect(state.recentVaults.isEmpty)
    #expect(recentStorage.savedURLs.isEmpty)
    #expect(tabStore.loadSession(forVaultAt: vaultURL) == nil)
    #expect(tabStore.clearCount == 1)
}

@Test
func openingUnavailableRecentVaultDoesNotCreateIndexAndCanRemoveIt() throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let supportRoot = temporaryRoot.appendingPathComponent("support", isDirectory: true)
    let missingVaultURL = temporaryRoot.appendingPathComponent("missing-vault", isDirectory: true)
    let storage = MemoryRecentVaultStorage(urls: [missingVaultURL])
    let state = AppState(
        engineHealth: EngineHealthStatus(state: .loaded, abiVersion: 1, message: "test"),
        indexDirectoryResolver: AppOwnedIndexDirectoryResolver(applicationSupportRoot: supportRoot),
        vaultAccessValidator: FixedVaultAccessValidator(issue: .missing(missingVaultURL)),
        recentVaultStorage: storage
    )

    try state.openRecentVault(state.recentVaults[0])

    #expect(state.vaultSelection == .unavailable(.missing(missingVaultURL)))
    #expect(state.indexLocation == nil)
    #expect(!FileManager.default.fileExists(atPath: supportRoot.path))

    state.removeRecentVault(at: missingVaultURL)

    #expect(state.vaultSelection == .noVault)
    #expect(state.recentVaults.isEmpty)
    #expect(storage.savedURLs.isEmpty)
}

@Test
func vaultAccessIssuesExposeRecoveryMessages() {
    let url = URL(fileURLWithPath: "/tmp/vault", isDirectory: true)
    let issues = [
        VaultAccessIssue.denied(url),
        VaultAccessIssue.staleBookmark(url),
        VaultAccessIssue.missing(url),
        VaultAccessIssue.unmounted(url),
        VaultAccessIssue.readOnly(url)
    ]

    for issue in issues {
        #expect(!issue.displayTitle.isEmpty)
        #expect(!issue.recoveryMessage.isEmpty)
    }
}

private struct AllowingVaultAccessValidator: VaultAccessValidating {
    func validateVault(at url: URL) -> VaultAccessIssue? {
        nil
    }
}

private struct FixedVaultAccessValidator: VaultAccessValidating {
    let issue: VaultAccessIssue

    func validateVault(at url: URL) -> VaultAccessIssue? {
        issue
    }
}

private final class MutableVaultAccessValidator: VaultAccessValidating {
    var issue: VaultAccessIssue?

    func validateVault(at url: URL) -> VaultAccessIssue? {
        issue
    }
}

private enum FakeReadFactoryError: Error {
    case openFailed
}

private final class FakeReadClientFactory: @unchecked Sendable {
    var clients: [FakeReadClient]
    let error: (any Error)?
    private(set) var openedMetadataURLs: [URL] = []
    private(set) var openedTantivyURLs: [URL] = []

    init(clients: [FakeReadClient] = [], error: (any Error)? = nil) {
        self.clients = clients
        self.error = error
    }

    func make(metadataURL: URL, tantivyURL: URL) throws -> any EngineReading {
        openedMetadataURLs.append(metadataURL)
        openedTantivyURLs.append(tantivyURL)
        if let error {
            throw error
        }
        return clients.removeFirst()
    }
}

private final class FakeReadClient: EngineReading, @unchecked Sendable {
    private(set) var closeCount = 0

    func close() {
        closeCount += 1
    }

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

private final class MemoryRecentVaultStorage: RecentVaultStoring {
    private(set) var savedURLs: [URL]

    init(urls: [URL] = []) {
        self.savedURLs = urls
    }

    func loadRecentVaultURLs() -> [URL] {
        savedURLs
    }

    func saveRecentVaultURLs(_ urls: [URL]) {
        savedURLs = urls
    }
}

private final class MemoryWorkspaceTabSessionStore: WorkspaceTabSessionStoring {
    private(set) var savedSessions: [String: WorkspaceTabSession] = [:]
    private(set) var saveCount = 0
    private(set) var clearCount = 0

    init(sessions: [String: WorkspaceTabSession] = [:]) {
        self.savedSessions = sessions
    }

    func loadSession(forVaultAt vaultURL: URL) -> WorkspaceTabSession? {
        savedSessions[RecentVault.storageKey(for: vaultURL)]
    }

    func saveSession(_ session: WorkspaceTabSession, forVaultAt vaultURL: URL) {
        saveCount += 1
        savedSessions[RecentVault.storageKey(for: vaultURL)] = session
    }

    func clearSession(forVaultAt vaultURL: URL) {
        clearCount += 1
        savedSessions.removeValue(forKey: RecentVault.storageKey(for: vaultURL))
    }
}
