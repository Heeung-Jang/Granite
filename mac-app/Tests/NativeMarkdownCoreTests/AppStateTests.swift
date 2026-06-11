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
    let recoveryScheduler = FakeReadIndexRecoveryScheduler()
    let state = AppState(
        engineHealth: EngineHealthStatus(state: .loaded, abiVersion: 1, message: "test"),
        indexDirectoryResolver: AppOwnedIndexDirectoryResolver(applicationSupportRoot: supportRoot),
        vaultAccessValidator: AllowingVaultAccessValidator(),
        recentVaultStorage: MemoryRecentVaultStorage(),
        readClientFactory: factory.make,
        readIndexRecoveryScheduler: recoveryScheduler
    )
    let vaultURL = URL(fileURLWithPath: "/tmp/read-vault", isDirectory: true)

    try state.selectVault(vaultURL)

    let location = try #require(state.indexLocation)
    #expect(factory.openedMetadataURLs == [location.metadataStoreFile])
    #expect(factory.openedTantivyURLs == [location.tantivyIndexDirectory])
    #expect(state.readAvailability == .ready)
    #expect((state.readClient as? FakeReadClient) === client)
    #expect(state.readGeneration == 1)
    #expect(recoveryScheduler.pendingWorkCount == 0)
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
func appStateRebuildsReadIndexForRecoverableOpenErrors() throws {
    for code in ["missing_metadata", "missing_tantivy_index", "schema_mismatch", "backend_mismatch"] {
        let supportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let client = FakeReadClient()
        let factory = FakeReadClientFactory(
            clients: [client],
            errors: [engineReadOpenError(code: code)]
        )
        let rebuilder = FakeReadIndexRebuilder()
        let recoveryScheduler = FakeReadIndexRecoveryScheduler()
        let state = AppState(
            engineHealth: EngineHealthStatus(state: .loaded, abiVersion: 1, message: "test"),
            indexDirectoryResolver: AppOwnedIndexDirectoryResolver(applicationSupportRoot: supportRoot),
            vaultAccessValidator: AllowingVaultAccessValidator(),
            recentVaultStorage: MemoryRecentVaultStorage(),
            readClientFactory: factory.make,
            readIndexRebuilder: rebuilder,
            readIndexRecoveryScheduler: recoveryScheduler
        )
        let vaultURL = URL(fileURLWithPath: "/tmp/read-rebuild-\(code)", isDirectory: true)

        try state.selectVault(vaultURL)

        let location = try #require(state.indexLocation)
        #expect(factory.openedMetadataURLs == [location.metadataStoreFile])
        #expect(factory.openedTantivyURLs == [location.tantivyIndexDirectory])
        #expect(rebuilder.rebuiltVaultURLs.isEmpty)
        #expect(rebuilder.rebuiltLocations.isEmpty)
        #expect(state.readAvailability == .opening)
        #expect(state.readClient == nil)
        #expect(recoveryScheduler.pendingWorkCount == 1)

        recoveryScheduler.runNext()

        #expect(factory.openedMetadataURLs == [location.metadataStoreFile, location.metadataStoreFile])
        #expect(factory.openedTantivyURLs == [location.tantivyIndexDirectory, location.tantivyIndexDirectory])
        #expect(rebuilder.rebuiltVaultURLs == [vaultURL.standardizedFileURL])
        #expect(rebuilder.rebuiltLocations == [location])
        #expect(state.readAvailability == .ready)
        #expect((state.readClient as? FakeReadClient) === client)
        #expect(state.readGeneration == 1)
        #expect(recoveryScheduler.pendingWorkCount == 0)
    }
}

@Test
func appStateDoesNotRebuildReadIndexForNonrecoverableOpenErrors() throws {
    let supportRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let factory = FakeReadClientFactory(error: engineReadOpenError(code: "tokenizer_mismatch"))
    let rebuilder = FakeReadIndexRebuilder()
    let recoveryScheduler = FakeReadIndexRecoveryScheduler()
    let state = AppState(
        engineHealth: EngineHealthStatus(state: .loaded, abiVersion: 1, message: "test"),
        indexDirectoryResolver: AppOwnedIndexDirectoryResolver(applicationSupportRoot: supportRoot),
        vaultAccessValidator: AllowingVaultAccessValidator(),
        recentVaultStorage: MemoryRecentVaultStorage(),
        readClientFactory: factory.make,
        readIndexRebuilder: rebuilder,
        readIndexRecoveryScheduler: recoveryScheduler
    )

    try state.selectVault(URL(fileURLWithPath: "/tmp/read-nonrecoverable-vault", isDirectory: true))

    #expect(state.readClient == nil)
    #expect(rebuilder.rebuiltVaultURLs.isEmpty)
    #expect(recoveryScheduler.pendingWorkCount == 0)
    #expect(factory.openedMetadataURLs.count == 1)
    if case .error(let message) = state.readAvailability {
        #expect(message.contains("tokenizer_mismatch"))
    } else {
        #expect(Bool(false))
    }
}

@Test
func appStateSanitizesReadIndexRecoveryFailureMessage() throws {
    let supportRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let factory = FakeReadClientFactory(errors: [engineReadOpenError(code: "missing_metadata")])
    let rebuilder = FakeReadIndexRebuilder(error: engineReadOpenError(code: "missing_metadata"))
    let recoveryScheduler = FakeReadIndexRecoveryScheduler()
    let state = AppState(
        engineHealth: EngineHealthStatus(state: .loaded, abiVersion: 1, message: "test"),
        indexDirectoryResolver: AppOwnedIndexDirectoryResolver(applicationSupportRoot: supportRoot),
        vaultAccessValidator: AllowingVaultAccessValidator(),
        recentVaultStorage: MemoryRecentVaultStorage(),
        readClientFactory: factory.make,
        readIndexRebuilder: rebuilder,
        readIndexRecoveryScheduler: recoveryScheduler
    )

    try state.selectVault(URL(fileURLWithPath: "/tmp/read-recovery-fails-vault", isDirectory: true))

    #expect(state.readClient == nil)
    #expect(state.readAvailability == .opening)
    #expect(recoveryScheduler.pendingWorkCount == 1)

    recoveryScheduler.runNext()

    #expect(state.readClient == nil)
    #expect(state.readAvailability == .error("read index rebuild failed: missing_metadata"))
    #expect(recoveryScheduler.pendingWorkCount == 0)
}

@Test
func appStateIgnoresStaleReadIndexRecoveryAfterVaultSwitch() throws {
    let supportRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let secondClient = FakeReadClient()
    let factory = FakeReadClientFactory(
        clients: [secondClient],
        errors: [engineReadOpenError(code: "missing_metadata")]
    )
    let rebuilder = FakeReadIndexRebuilder()
    let recoveryScheduler = FakeReadIndexRecoveryScheduler()
    let state = AppState(
        engineHealth: EngineHealthStatus(state: .loaded, abiVersion: 1, message: "test"),
        indexDirectoryResolver: AppOwnedIndexDirectoryResolver(applicationSupportRoot: supportRoot),
        vaultAccessValidator: AllowingVaultAccessValidator(),
        recentVaultStorage: MemoryRecentVaultStorage(),
        readClientFactory: factory.make,
        readIndexRebuilder: rebuilder,
        readIndexRecoveryScheduler: recoveryScheduler
    )
    let firstVault = URL(fileURLWithPath: "/tmp/read-stale-first", isDirectory: true)
    let secondVault = URL(fileURLWithPath: "/tmp/read-stale-second", isDirectory: true)

    try state.selectVault(firstVault)
    let firstLocation = try #require(state.indexLocation)

    #expect(state.vaultSelection == .selected(firstVault))
    #expect(state.readAvailability == .opening)
    #expect(recoveryScheduler.pendingWorkCount == 1)

    try state.selectVault(secondVault)
    let secondLocation = try #require(state.indexLocation)

    #expect(state.vaultSelection == .selected(secondVault))
    #expect(state.readAvailability == .ready)
    #expect((state.readClient as? FakeReadClient) === secondClient)
    #expect(state.readGeneration == 2)

    recoveryScheduler.runNext()

    #expect(rebuilder.rebuiltVaultURLs == [firstVault.standardizedFileURL])
    #expect(rebuilder.rebuiltLocations == [firstLocation])
    #expect(factory.openedMetadataURLs == [
        firstLocation.metadataStoreFile,
        secondLocation.metadataStoreFile
    ])
    #expect(factory.openedTantivyURLs == [
        firstLocation.tantivyIndexDirectory,
        secondLocation.tantivyIndexDirectory
    ])
    #expect(state.vaultSelection == .selected(secondVault))
    #expect(state.readAvailability == .ready)
    #expect((state.readClient as? FakeReadClient) === secondClient)
    #expect(state.readGeneration == 2)
}

@Test
func appStateIgnoresStaleReadIndexRecoveryAfterClearVault() throws {
    let supportRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let factory = FakeReadClientFactory(errors: [engineReadOpenError(code: "missing_metadata")])
    let rebuilder = FakeReadIndexRebuilder()
    let recoveryScheduler = FakeReadIndexRecoveryScheduler()
    let state = AppState(
        engineHealth: EngineHealthStatus(state: .loaded, abiVersion: 1, message: "test"),
        indexDirectoryResolver: AppOwnedIndexDirectoryResolver(applicationSupportRoot: supportRoot),
        vaultAccessValidator: AllowingVaultAccessValidator(),
        recentVaultStorage: MemoryRecentVaultStorage(),
        readClientFactory: factory.make,
        readIndexRebuilder: rebuilder,
        readIndexRecoveryScheduler: recoveryScheduler
    )
    let vaultURL = URL(fileURLWithPath: "/tmp/read-stale-clear", isDirectory: true)

    try state.selectVault(vaultURL)
    let location = try #require(state.indexLocation)

    #expect(state.vaultSelection == .selected(vaultURL))
    #expect(state.readAvailability == .opening)
    #expect(recoveryScheduler.pendingWorkCount == 1)

    state.clearVault()
    #expect(state.vaultSelection == .noVault)
    #expect(state.readAvailability == .unavailable)
    #expect(state.readGeneration == 2)

    recoveryScheduler.runNext()

    #expect(rebuilder.rebuiltVaultURLs == [vaultURL.standardizedFileURL])
    #expect(rebuilder.rebuiltLocations == [location])
    #expect(factory.openedMetadataURLs == [location.metadataStoreFile])
    #expect(factory.openedTantivyURLs == [location.tantivyIndexDirectory])
    #expect(state.vaultSelection == .noVault)
    #expect(state.readClient == nil)
    #expect(state.readAvailability == .unavailable)
    #expect(state.readGeneration == 2)
}

@Test
func appStateExplicitlyRebuildsCurrentVaultIndexAndPublishesRefreshGeneration() throws {
    let supportRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let firstClient = FakeReadClient()
    let secondClient = FakeReadClient()
    let factory = FakeReadClientFactory(clients: [firstClient, secondClient])
    let rebuilder = FakeReadIndexRebuilder()
    let recoveryScheduler = FakeReadIndexRecoveryScheduler()
    let state = AppState(
        engineHealth: EngineHealthStatus(state: .loaded, abiVersion: 1, message: "test"),
        indexDirectoryResolver: AppOwnedIndexDirectoryResolver(applicationSupportRoot: supportRoot),
        vaultAccessValidator: AllowingVaultAccessValidator(),
        recentVaultStorage: MemoryRecentVaultStorage(),
        readClientFactory: factory.make,
        readIndexRebuilder: rebuilder,
        readIndexRecoveryScheduler: recoveryScheduler
    )
    let vaultURL = URL(fileURLWithPath: "/tmp/read-explicit-rebuild", isDirectory: true)

    try state.selectVault(vaultURL)
    let location = try #require(state.indexLocation)
    #expect(state.readAvailability == .ready)
    #expect(state.readGeneration == 1)
    state.registerCreatedFileTreeItem(FileTreeItem(relativePath: "Created.md"))
    state.registerCreatedFileTreeFolder(path: "Empty")

    #expect(state.requestCurrentVaultIndexRebuild())

    #expect(firstClient.closeCount == 0)
    #expect(state.readAvailability == .ready)
    #expect((state.readClient as? FakeReadClient) === firstClient)
    #expect(state.readGeneration == 1)
    #expect(recoveryScheduler.pendingWorkCount == 1)

    recoveryScheduler.runNext()

    #expect(rebuilder.rebuiltVaultURLs == [vaultURL.standardizedFileURL])
    #expect(rebuilder.rebuiltLocations == [location])
    #expect(firstClient.closeCount == 1)
    #expect((state.readClient as? FakeReadClient) === secondClient)
    #expect(state.readAvailability == .ready)
    #expect(state.readGeneration == 2)
    #expect(state.fileTreeOverlayItems.isEmpty)
    #expect(state.fileTreeOverlayFolderPaths.isEmpty)
}

@Test
func appStateExplicitRebuildFailureKeepsCurrentReadClientAndOverlays() throws {
    let supportRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let firstClient = FakeReadClient()
    let factory = FakeReadClientFactory(clients: [firstClient])
    let rebuilder = FakeReadIndexRebuilder(error: engineReadOpenError(code: "missing_metadata"))
    let recoveryScheduler = FakeReadIndexRecoveryScheduler()
    let state = AppState(
        engineHealth: EngineHealthStatus(state: .loaded, abiVersion: 1, message: "test"),
        indexDirectoryResolver: AppOwnedIndexDirectoryResolver(applicationSupportRoot: supportRoot),
        vaultAccessValidator: AllowingVaultAccessValidator(),
        recentVaultStorage: MemoryRecentVaultStorage(),
        readClientFactory: factory.make,
        readIndexRebuilder: rebuilder,
        readIndexRecoveryScheduler: recoveryScheduler
    )
    let vaultURL = URL(fileURLWithPath: "/tmp/read-explicit-rebuild-failure", isDirectory: true)
    let createdItem = FileTreeItem(relativePath: "Created.md")

    try state.selectVault(vaultURL)
    let location = try #require(state.indexLocation)
    state.registerCreatedFileTreeItem(createdItem)
    state.registerCreatedFileTreeFolder(path: "Empty")

    #expect(state.requestCurrentVaultIndexRebuild())
    recoveryScheduler.runNext()

    #expect(rebuilder.rebuiltVaultURLs == [vaultURL.standardizedFileURL])
    #expect(rebuilder.rebuiltLocations == [location])
    #expect(firstClient.closeCount == 0)
    #expect((state.readClient as? FakeReadClient) === firstClient)
    #expect(state.readAvailability == .ready)
    #expect(state.readGeneration == 1)
    #expect(state.fileTreeOverlayItems == [createdItem])
    #expect(state.fileTreeOverlayFolderPaths == ["Empty"])
}

@Test
func appStateExplicitRebuildReturnsFalseWithoutSelectedVault() {
    let state = AppState()

    #expect(!state.requestCurrentVaultIndexRebuild())
    #expect(state.readAvailability == .unavailable)
}

@Test
func appStateWatchesSelectedVaultAndDebouncesAutoIndexRefresh() throws {
    let supportRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let firstClient = FakeReadClient()
    let secondClient = FakeReadClient()
    let factory = FakeReadClientFactory(clients: [firstClient, secondClient])
    let rebuilder = FakeReadIndexRebuilder()
    let recoveryScheduler = FakeReadIndexRecoveryScheduler()
    let watcher = FakeVaultChangeWatcher()
    let refreshScheduler = FakeVaultIndexRefreshScheduler()
    let state = AppState(
        engineHealth: EngineHealthStatus(state: .loaded, abiVersion: 1, message: "test"),
        indexDirectoryResolver: AppOwnedIndexDirectoryResolver(applicationSupportRoot: supportRoot),
        vaultAccessValidator: AllowingVaultAccessValidator(),
        recentVaultStorage: MemoryRecentVaultStorage(),
        readClientFactory: factory.make,
        readIndexRebuilder: rebuilder,
        readIndexRecoveryScheduler: recoveryScheduler,
        vaultChangeWatcher: watcher,
        vaultIndexRefreshScheduler: refreshScheduler,
        vaultIndexRefreshDebounceInterval: 0.25
    )
    let vaultURL = URL(fileURLWithPath: "/tmp/read-auto-refresh", isDirectory: true)

    try state.selectVault(vaultURL)
    let location = try #require(state.indexLocation)

    #expect(watcher.startedVaultURLs == [vaultURL.standardizedFileURL])
    watcher.emitChange()

    #expect(refreshScheduler.scheduledDelays == [0.25])
    #expect(recoveryScheduler.pendingWorkCount == 0)

    refreshScheduler.runPending()

    #expect(recoveryScheduler.pendingWorkCount == 1)
    recoveryScheduler.runNext()

    #expect(rebuilder.rebuiltVaultURLs == [vaultURL.standardizedFileURL])
    #expect(rebuilder.rebuiltLocations == [location])
    #expect(firstClient.closeCount == 1)
    #expect((state.readClient as? FakeReadClient) === secondClient)
    #expect(state.readGeneration == 2)
}

@Test
func appStateQueuesOneMoreAutoRefreshWhenVaultChangesDuringRebuild() throws {
    let supportRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let firstClient = FakeReadClient()
    let secondClient = FakeReadClient()
    let thirdClient = FakeReadClient()
    let factory = FakeReadClientFactory(clients: [firstClient, secondClient, thirdClient])
    let rebuilder = FakeReadIndexRebuilder()
    let recoveryScheduler = FakeReadIndexRecoveryScheduler()
    let watcher = FakeVaultChangeWatcher()
    let refreshScheduler = FakeVaultIndexRefreshScheduler()
    let state = AppState(
        engineHealth: EngineHealthStatus(state: .loaded, abiVersion: 1, message: "test"),
        indexDirectoryResolver: AppOwnedIndexDirectoryResolver(applicationSupportRoot: supportRoot),
        vaultAccessValidator: AllowingVaultAccessValidator(),
        recentVaultStorage: MemoryRecentVaultStorage(),
        readClientFactory: factory.make,
        readIndexRebuilder: rebuilder,
        readIndexRecoveryScheduler: recoveryScheduler,
        vaultChangeWatcher: watcher,
        vaultIndexRefreshScheduler: refreshScheduler,
        vaultIndexRefreshDebounceInterval: 0
    )
    let vaultURL = URL(fileURLWithPath: "/tmp/read-auto-refresh-coalesced", isDirectory: true)

    try state.selectVault(vaultURL)
    watcher.emitChange()
    refreshScheduler.runPending()
    watcher.emitChange()
    refreshScheduler.runPending()

    #expect(recoveryScheduler.pendingWorkCount == 1)

    recoveryScheduler.runNext()

    #expect(recoveryScheduler.pendingWorkCount == 1)
    #expect(rebuilder.rebuiltVaultURLs == [vaultURL.standardizedFileURL])
    #expect((state.readClient as? FakeReadClient) === secondClient)
    #expect(state.readGeneration == 2)

    recoveryScheduler.runNext()

    #expect(rebuilder.rebuiltVaultURLs == [vaultURL.standardizedFileURL, vaultURL.standardizedFileURL])
    #expect((state.readClient as? FakeReadClient) === thirdClient)
    #expect(state.readGeneration == 3)
}

@Test
func appStateCancelsAutoRefreshWatcherAndDebounceWhenVaultClears() throws {
    let supportRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let watcher = FakeVaultChangeWatcher()
    let refreshScheduler = FakeVaultIndexRefreshScheduler()
    let recoveryScheduler = FakeReadIndexRecoveryScheduler()
    let state = AppState(
        engineHealth: EngineHealthStatus(state: .loaded, abiVersion: 1, message: "test"),
        indexDirectoryResolver: AppOwnedIndexDirectoryResolver(applicationSupportRoot: supportRoot),
        vaultAccessValidator: AllowingVaultAccessValidator(),
        recentVaultStorage: MemoryRecentVaultStorage(),
        readClientFactory: FakeReadClientFactory(clients: [FakeReadClient()]).make,
        readIndexRecoveryScheduler: recoveryScheduler,
        vaultChangeWatcher: watcher,
        vaultIndexRefreshScheduler: refreshScheduler
    )
    let vaultURL = URL(fileURLWithPath: "/tmp/read-auto-refresh-clear", isDirectory: true)

    try state.selectVault(vaultURL)
    watcher.emitChange()
    #expect(refreshScheduler.pendingActionCount == 1)

    state.clearVault()

    #expect(watcher.activeWatch?.cancelCount == 1)
    #expect(refreshScheduler.pendingActionCount == 0)
    refreshScheduler.runPending()
    #expect(recoveryScheduler.pendingWorkCount == 0)
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
func appStateSnapshotsOnlyActiveOwnedEditorBuffer() throws {
    let state = AppState()
    let file = FileTreeItem(relativePath: "Folder/Note.md")
    let owner = UUID()

    #expect(state.openFile(file))
    let tabID = try #require(state.activeTabID)
    state.registerActiveEditorBufferProvider(
        vaultID: "vault-a",
        ownerID: owner,
        tabID: tabID,
        fileID: file.id,
        revision: 1
    ) {
        "draft contents"
    }

    let snapshot = state.snapshotForActiveEditor(expectedOwnerID: owner, tabID: tabID, fileID: file.id)

    #expect(snapshot?.contents == "draft contents")
    #expect(snapshot?.revision == 1)
    #expect(snapshot?.fileID == file.id)
    #expect(state.snapshotForActiveEditor(expectedOwnerID: UUID(), tabID: tabID, fileID: file.id) == nil)
}

@Test
func appStateRejectsStaleEditorBufferUpdatesAndClears() throws {
    let state = AppState()
    let first = FileTreeItem(relativePath: "First.md")
    let second = FileTreeItem(relativePath: "Second.md")
    let owner = UUID()
    let staleOwner = UUID()

    #expect(state.openFile(first))
    let firstTabID = try #require(state.activeTabID)
    state.registerActiveEditorBufferProvider(
        vaultID: "vault",
        ownerID: owner,
        tabID: firstTabID,
        fileID: first.id,
        revision: 1
    ) {
        "first"
    }

    state.updateActiveEditorBufferRevision(
        ownerID: staleOwner,
        tabID: firstTabID,
        fileID: first.id,
        revision: 99
    )
    #expect(state.activeEditorBufferDescriptor?.revision == 1)

    #expect(state.openFile(second, disposition: .newTab))
    let secondTabID = try #require(state.activeTabID)
    state.clearActiveEditorBufferProvider(ownerID: owner, tabID: firstTabID, fileID: first.id)
    #expect(state.activeEditorBufferDescriptor == nil)

    state.registerActiveEditorBufferProvider(
        vaultID: "vault",
        ownerID: owner,
        tabID: firstTabID,
        fileID: first.id,
        revision: 2
    ) {
        "stale"
    }
    #expect(state.activeEditorBufferDescriptor == nil)

    state.registerActiveEditorBufferProvider(
        vaultID: "vault",
        ownerID: owner,
        tabID: secondTabID,
        fileID: second.id,
        revision: 1
    ) {
        "second"
    }
    #expect(state.snapshotForActiveEditor(expectedOwnerID: owner, tabID: secondTabID, fileID: second.id)?.contents == "second")
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
    let startupStorage = MemoryStartupVaultRestoreStorage()
    let state = AppState(
        vaultSelection: .unavailable(issue),
        startupVaultRestoreStorage: startupStorage
    )

    #expect(state.requestCloseVault())

    #expect(state.vaultSelection == .noVault)
    #expect(state.dirtyEditorActionWarning == nil)
    #expect(startupStorage.suppressesLastVaultRestore)
    #expect(startupStorage.savedValues == [true])
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

    #expect(configuration.schemaVersion == "metadata-v3")
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
func indexDirectoryResolverIgnoresLegacyMetadataFromPreviousSchemaVersion() throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let vaultURL = temporaryRoot.appendingPathComponent("vault", isDirectory: true)
    let preferredRoot = temporaryRoot.appendingPathComponent("Granite", isDirectory: true)
    let legacyRoot = temporaryRoot.appendingPathComponent("NativeMarkdownMacApp", isDirectory: true)
    try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)

    let previousSchemaLocation = try AppOwnedIndexDirectoryResolver(
        applicationSupportRoot: legacyRoot,
        configuration: IndexConfiguration(schemaVersion: "metadata-v1")
    ).prepareIndexLocation(forVaultAt: vaultURL)
    try Data("legacy".utf8).write(to: previousSchemaLocation.metadataStoreFile)

    let resolver = AppOwnedIndexDirectoryResolver(
        applicationSupportRoot: preferredRoot,
        legacyApplicationSupportRoots: [legacyRoot]
    )

    let location = try resolver.prepareIndexLocation(forVaultAt: vaultURL)

    #expect(location.rootDirectory.path.hasPrefix(preferredRoot.path))
    #expect(location.configuration.schemaVersion == "metadata-v3")
    #expect(location.metadataStoreFile.path != previousSchemaLocation.metadataStoreFile.path)
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
func appStateRestoresLastRecentVaultOnLaunch() throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let vaultURL = temporaryRoot.appendingPathComponent("vault", isDirectory: true)
    let supportRoot = temporaryRoot.appendingPathComponent("support", isDirectory: true)
    try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    let recentStorage = MemoryRecentVaultStorage(urls: [vaultURL])
    let startupStorage = MemoryStartupVaultRestoreStorage()
    let factory = FakeReadClientFactory(clients: [FakeReadClient()])
    let state = AppState(
        engineHealth: EngineHealthStatus(state: .loaded, abiVersion: 1, message: "test"),
        indexDirectoryResolver: AppOwnedIndexDirectoryResolver(applicationSupportRoot: supportRoot),
        vaultAccessValidator: AllowingVaultAccessValidator(),
        recentVaultStorage: recentStorage,
        startupVaultRestoreStorage: startupStorage,
        readClientFactory: factory.make
    )

    #expect(try state.restoreLastVaultOnLaunchIfNeeded())

    #expect(state.vaultSelection == .selected(vaultURL))
    #expect(state.recentVaults.map(\.url) == [vaultURL])
    #expect(recentStorage.savedURLs == [vaultURL])
    #expect(startupStorage.suppressesLastVaultRestore == false)
    #expect(startupStorage.savedValues == [false])

    #expect(try state.restoreLastVaultOnLaunchIfNeeded() == false)
}

@Test
func appStateSkipsSuppressedLastVaultRestore() throws {
    let vaultURL = URL(fileURLWithPath: "/tmp/suppressed-vault", isDirectory: true)
    let startupStorage = MemoryStartupVaultRestoreStorage(suppresses: true)
    let state = AppState(
        recentVaultStorage: MemoryRecentVaultStorage(urls: [vaultURL]),
        startupVaultRestoreStorage: startupStorage
    )

    #expect(try state.restoreLastVaultOnLaunchIfNeeded() == false)

    #expect(state.vaultSelection == .noVault)
    #expect(startupStorage.suppressesLastVaultRestore)
    #expect(startupStorage.savedValues.isEmpty)
}

@Test
func appStateSkipsLastVaultRestoreWhenVaultAlreadyOpen() throws {
    let vaultURL = URL(fileURLWithPath: "/tmp/already-open-vault", isDirectory: true)
    let recentURL = URL(fileURLWithPath: "/tmp/recent-vault", isDirectory: true)
    let state = AppState(
        vaultSelection: .selected(vaultURL),
        recentVaultStorage: MemoryRecentVaultStorage(urls: [recentURL])
    )

    #expect(try state.restoreLastVaultOnLaunchIfNeeded() == false)

    #expect(state.vaultSelection == .selected(vaultURL))
}

@Test
func appStateRestoresWorkspaceTabsDuringLastVaultLaunch() throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let vaultURL = temporaryRoot.appendingPathComponent("vault", isDirectory: true)
    let supportRoot = temporaryRoot.appendingPathComponent("support", isDirectory: true)
    try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
    try "a".write(to: vaultURL.appendingPathComponent("First.md"), atomically: true, encoding: .utf8)
    try "b".write(to: vaultURL.appendingPathComponent("Second.md"), atomically: true, encoding: .utf8)
    defer {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    let tabStore = MemoryWorkspaceTabSessionStore(sessions: [
        RecentVault.storageKey(for: vaultURL): WorkspaceTabSession(
            tabs: ["Missing.md", "First.md", "Second.md"],
            activeRelativePath: "Second.md"
        )
    ])
    let factory = FakeReadClientFactory(clients: [FakeReadClient()])
    let state = AppState(
        engineHealth: EngineHealthStatus(state: .loaded, abiVersion: 1, message: "test"),
        indexDirectoryResolver: AppOwnedIndexDirectoryResolver(applicationSupportRoot: supportRoot),
        vaultAccessValidator: AllowingVaultAccessValidator(),
        recentVaultStorage: MemoryRecentVaultStorage(urls: [vaultURL]),
        startupVaultRestoreStorage: MemoryStartupVaultRestoreStorage(),
        workspaceTabSessionStore: tabStore,
        readClientFactory: factory.make
    )

    #expect(try state.restoreLastVaultOnLaunchIfNeeded())

    #expect(state.workspaceTabs.map(\.relativePathKey) == ["First.md", "Second.md"])
    #expect(state.selectedFile == FileTreeItem(relativePath: "Second.md"))
}

@Test
func appStateLastVaultRestoreReadErrorKeepsSelectedVault() throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let vaultURL = temporaryRoot.appendingPathComponent("vault", isDirectory: true)
    let supportRoot = temporaryRoot.appendingPathComponent("support", isDirectory: true)
    try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    let startupStorage = MemoryStartupVaultRestoreStorage()
    let factory = FakeReadClientFactory(error: FakeReadFactoryError.openFailed)
    let state = AppState(
        engineHealth: EngineHealthStatus(state: .loaded, abiVersion: 1, message: "test"),
        indexDirectoryResolver: AppOwnedIndexDirectoryResolver(applicationSupportRoot: supportRoot),
        vaultAccessValidator: AllowingVaultAccessValidator(),
        recentVaultStorage: MemoryRecentVaultStorage(urls: [vaultURL]),
        startupVaultRestoreStorage: startupStorage,
        readClientFactory: factory.make
    )

    #expect(try state.restoreLastVaultOnLaunchIfNeeded())

    #expect(state.vaultSelection == .selected(vaultURL))
    #expect(state.readAvailability == .error("openFailed"))
    #expect(!startupStorage.suppressesLastVaultRestore)
}

@Test
func appStateLastVaultRestoreMissingVaultDoesNotCreateIndexDirectories() throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let supportRoot = temporaryRoot.appendingPathComponent("support", isDirectory: true)
    let missingVaultURL = temporaryRoot.appendingPathComponent("missing-vault", isDirectory: true)
    let startupStorage = MemoryStartupVaultRestoreStorage()
    let state = AppState(
        engineHealth: EngineHealthStatus(state: .loaded, abiVersion: 1, message: "test"),
        indexDirectoryResolver: AppOwnedIndexDirectoryResolver(applicationSupportRoot: supportRoot),
        vaultAccessValidator: FileSystemVaultAccessValidator(),
        recentVaultStorage: MemoryRecentVaultStorage(urls: [missingVaultURL]),
        startupVaultRestoreStorage: startupStorage
    )
    defer {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    #expect(try state.restoreLastVaultOnLaunchIfNeeded())

    #expect(state.vaultSelection == .unavailable(.missing(missingVaultURL)))
    #expect(state.indexLocation == nil)
    #expect(!FileManager.default.fileExists(atPath: supportRoot.path))
    #expect(!startupStorage.suppressesLastVaultRestore)
}

@Test
func appStateLastVaultRestoreDoesNotRetryAfterThrownOpen() throws {
    let vaultURL = URL(fileURLWithPath: "/tmp/throwing-restore-vault", isDirectory: true)
    let state = AppState(
        indexDirectoryResolver: ThrowingIndexDirectoryResolver(),
        vaultAccessValidator: AllowingVaultAccessValidator(),
        recentVaultStorage: MemoryRecentVaultStorage(urls: [vaultURL]),
        startupVaultRestoreStorage: MemoryStartupVaultRestoreStorage()
    )

    #expect(throws: ThrowingIndexDirectoryResolverError.failed) {
        try state.restoreLastVaultOnLaunchIfNeeded()
    }

    #expect(try state.restoreLastVaultOnLaunchIfNeeded() == false)
    #expect(state.vaultSelection == .noVault)
}

@Test
func appStateVaultSelectionClearsStartupRestoreSuppression() throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let supportRoot = temporaryRoot.appendingPathComponent("support", isDirectory: true)
    let startupStorage = MemoryStartupVaultRestoreStorage(suppresses: true)
    let factory = FakeReadClientFactory(clients: [FakeReadClient()])
    let state = AppState(
        engineHealth: EngineHealthStatus(state: .loaded, abiVersion: 1, message: "test"),
        indexDirectoryResolver: AppOwnedIndexDirectoryResolver(applicationSupportRoot: supportRoot),
        vaultAccessValidator: AllowingVaultAccessValidator(),
        recentVaultStorage: MemoryRecentVaultStorage(),
        startupVaultRestoreStorage: startupStorage,
        readClientFactory: factory.make
    )
    defer {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    try state.selectVault(temporaryRoot.appendingPathComponent("selected-vault", isDirectory: true))

    #expect(!startupStorage.suppressesLastVaultRestore)
    #expect(startupStorage.savedValues == [false])
}

@Test
func appStateUnavailableAndStaleVaultClearStartupRestoreSuppression() throws {
    let vaultURL = URL(fileURLWithPath: "/tmp/unavailable-vault", isDirectory: true)
    let startupStorage = MemoryStartupVaultRestoreStorage(suppresses: true)
    let state = AppState(
        vaultAccessValidator: FixedVaultAccessValidator(issue: .missing(vaultURL)),
        recentVaultStorage: MemoryRecentVaultStorage(),
        startupVaultRestoreStorage: startupStorage
    )

    try state.selectVault(vaultURL)
    #expect(!startupStorage.suppressesLastVaultRestore)

    startupStorage.suppressesLastVaultRestore = true
    state.markStaleBookmark(for: vaultURL)
    #expect(!startupStorage.suppressesLastVaultRestore)
    #expect(startupStorage.savedValues == [false, false])
}

@Test
func appStateCleanCloseVaultSuppressesStartupRestore() {
    let vaultURL = URL(fileURLWithPath: "/tmp/clean-close-suppression-vault", isDirectory: true)
    let startupStorage = MemoryStartupVaultRestoreStorage()
    let state = AppState(
        vaultSelection: .selected(vaultURL),
        startupVaultRestoreStorage: startupStorage
    )

    #expect(state.requestCloseVault())

    #expect(state.vaultSelection == .noVault)
    #expect(startupStorage.suppressesLastVaultRestore)
    #expect(startupStorage.savedValues == [true])
}

@Test
func appStateNoVaultCloseDoesNotChangeStartupRestoreSuppression() {
    let startupStorage = MemoryStartupVaultRestoreStorage(suppresses: true)
    let state = AppState(startupVaultRestoreStorage: startupStorage)

    #expect(state.requestCloseVault())

    #expect(startupStorage.suppressesLastVaultRestore)
    #expect(startupStorage.savedValues.isEmpty)
}

@Test
func appStateDirtyBlockedCloseVaultSuppressesOnlyAfterConfirmation() {
    let vaultURL = URL(fileURLWithPath: "/tmp/dirty-close-suppression-vault", isDirectory: true)
    let startupStorage = MemoryStartupVaultRestoreStorage()
    let state = AppState(
        vaultSelection: .selected(vaultURL),
        startupVaultRestoreStorage: startupStorage
    )
    let file = FileTreeItem(relativePath: "Dirty.md")

    #expect(state.openFile(file))
    state.updateEditorDirtyState(file: file, isDirty: true)

    #expect(state.requestCloseVault() == false)
    #expect(!startupStorage.suppressesLastVaultRestore)
    #expect(startupStorage.savedValues.isEmpty)

    #expect(state.discardDirtyChangesForEditorActionWarning() == .closeVault)
    #expect(startupStorage.suppressesLastVaultRestore)
    #expect(startupStorage.savedValues == [true])
}

@Test
func appStateDirtyClearSelectionDoesNotSuppressStartupRestore() {
    let vaultURL = URL(fileURLWithPath: "/tmp/dirty-clear-selection-vault", isDirectory: true)
    let startupStorage = MemoryStartupVaultRestoreStorage()
    let state = AppState(
        vaultSelection: .selected(vaultURL),
        startupVaultRestoreStorage: startupStorage
    )
    let file = FileTreeItem(relativePath: "Dirty.md")

    #expect(state.openFile(file))
    state.updateEditorDirtyState(file: file, isDirty: true)
    #expect(state.requestClearSelectedFile() == false)

    #expect(state.discardDirtyChangesForEditorActionWarning() == .clearSelection)

    #expect(!startupStorage.suppressesLastVaultRestore)
    #expect(startupStorage.savedValues.isEmpty)
}

@Test
func appStateRemovingCurrentRecentVaultSuppressesStartupRestore() throws {
    let current = URL(fileURLWithPath: "/tmp/current-recent-vault", isDirectory: true)
    let older = URL(fileURLWithPath: "/tmp/older-recent-vault", isDirectory: true)
    let startupStorage = MemoryStartupVaultRestoreStorage()
    let state = AppState(
        vaultSelection: .selected(current),
        recentVaultStorage: MemoryRecentVaultStorage(urls: [current, older]),
        startupVaultRestoreStorage: startupStorage
    )

    state.removeRecentVault(at: current)

    #expect(state.vaultSelection == .noVault)
    #expect(state.recentVaults.map(\.url) == [older])
    #expect(startupStorage.suppressesLastVaultRestore)
    #expect(try state.restoreLastVaultOnLaunchIfNeeded() == false)
}

@Test
func appStateRemovingNonCurrentRecentVaultDoesNotSuppressStartupRestore() {
    let current = URL(fileURLWithPath: "/tmp/current-recent-vault", isDirectory: true)
    let older = URL(fileURLWithPath: "/tmp/older-recent-vault", isDirectory: true)
    let startupStorage = MemoryStartupVaultRestoreStorage()
    let state = AppState(
        vaultSelection: .selected(current),
        recentVaultStorage: MemoryRecentVaultStorage(urls: [current, older]),
        startupVaultRestoreStorage: startupStorage
    )

    state.removeRecentVault(at: older)

    #expect(state.vaultSelection == .selected(current))
    #expect(state.recentVaults.map(\.url) == [current])
    #expect(!startupStorage.suppressesLastVaultRestore)
    #expect(startupStorage.savedValues.isEmpty)
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
func appStateStartsWithDefaultPaneLayout() {
    let state = AppState()

    #expect(state.workspacePaneLayout == .default)
}

@Test
func appStateLoadsSavedPaneLayoutWhenSelectingValidVault() throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let vaultURL = temporaryRoot.appendingPathComponent("vault", isDirectory: true)
    let supportRoot = temporaryRoot.appendingPathComponent("support", isDirectory: true)
    try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }
    let layout = WorkspacePaneLayout(leftSidebarWidth: 333, rightSidebarWidth: 444, isLeftSidebarCollapsed: true)
    let paneStore = MemoryWorkspacePaneLayoutStore(layouts: [
        RecentVault.storageKey(for: vaultURL): layout
    ])
    let state = AppState(
        engineHealth: EngineHealthStatus(state: .loaded, abiVersion: 1, message: "test"),
        indexDirectoryResolver: AppOwnedIndexDirectoryResolver(applicationSupportRoot: supportRoot),
        vaultAccessValidator: AllowingVaultAccessValidator(),
        recentVaultStorage: MemoryRecentVaultStorage(),
        workspacePaneLayoutStore: paneStore,
        readClientFactory: { _, _ in FakeReadClient() }
    )

    try state.selectVault(vaultURL)

    #expect(state.workspacePaneLayout == layout)
    #expect(paneStore.saveCount == 0)
}

@Test
func appStateLoadsSavedPaneLayoutWhenSelectingUnavailableVault() throws {
    let vaultURL = URL(fileURLWithPath: "/tmp/unavailable-pane-vault", isDirectory: true)
    let layout = WorkspacePaneLayout(leftSidebarWidth: 301, rightSidebarWidth: 402, isRightSidebarCollapsed: true)
    let paneStore = MemoryWorkspacePaneLayoutStore(layouts: [
        RecentVault.storageKey(for: vaultURL): layout
    ])
    let state = AppState(
        vaultAccessValidator: FixedVaultAccessValidator(issue: .missing(vaultURL)),
        recentVaultStorage: MemoryRecentVaultStorage(),
        workspacePaneLayoutStore: paneStore
    )

    try state.selectVault(vaultURL)

    #expect(state.vaultSelection == .unavailable(.missing(vaultURL)))
    #expect(state.workspacePaneLayout == layout)
    #expect(paneStore.saveCount == 0)
}

@Test
func appStateFallsBackToDefaultPaneLayoutForVaultWithoutSavedLayout() throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let vaultURL = temporaryRoot.appendingPathComponent("vault", isDirectory: true)
    let supportRoot = temporaryRoot.appendingPathComponent("support", isDirectory: true)
    try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }
    let state = AppState(
        engineHealth: EngineHealthStatus(state: .loaded, abiVersion: 1, message: "test"),
        indexDirectoryResolver: AppOwnedIndexDirectoryResolver(applicationSupportRoot: supportRoot),
        vaultAccessValidator: AllowingVaultAccessValidator(),
        recentVaultStorage: MemoryRecentVaultStorage(),
        workspacePaneLayoutStore: MemoryWorkspacePaneLayoutStore(),
        readClientFactory: { _, _ in FakeReadClient() }
    )

    try state.selectVault(vaultURL)

    #expect(state.workspacePaneLayout == .default)
}

@Test
func appStateClearingVaultResetsPaneLayoutWithoutClearingSavedRecord() {
    let vaultURL = URL(fileURLWithPath: "/tmp/clear-pane-vault", isDirectory: true)
    let paneStore = MemoryWorkspacePaneLayoutStore()
    let state = AppState(
        vaultSelection: .selected(vaultURL),
        workspacePaneLayoutStore: paneStore
    )

    state.setWorkspacePaneLayout(WorkspacePaneLayout(leftSidebarWidth: 350, rightSidebarWidth: 450))
    state.clearVault()

    #expect(state.workspacePaneLayout == .default)
    #expect(paneStore.clearCount == 0)
}

@Test
func appStatePersistsPaneWidthUpdatesOnlyWhenVaultExists() {
    let vaultURL = URL(fileURLWithPath: "/tmp/resize-pane-vault", isDirectory: true)
    let paneStore = MemoryWorkspacePaneLayoutStore()
    let selectedState = AppState(
        vaultSelection: .selected(vaultURL),
        workspacePaneLayoutStore: paneStore
    )

    selectedState.setLeftSidebarWidth(100, availableWidth: 1_200)
    selectedState.setRightSidebarWidth(900, availableWidth: 1_200)

    #expect(selectedState.workspacePaneLayout.leftSidebarWidth == 200)
    #expect(selectedState.workspacePaneLayout.rightSidebarWidth == 640)
    #expect(paneStore.saveCount == 2)
    #expect(paneStore.loadLayout(forVaultAt: vaultURL) == selectedState.workspacePaneLayout)

    let noVaultStore = MemoryWorkspacePaneLayoutStore()
    let noVaultState = AppState(workspacePaneLayoutStore: noVaultStore)
    noVaultState.setLeftSidebarWidth(320, availableWidth: 1_200)
    #expect(noVaultState.workspacePaneLayout.leftSidebarWidth == 320)
    #expect(noVaultStore.saveCount == 0)
}

@Test
func appStatePaneCollapseTogglesPreserveWidthsAndPersist() {
    let vaultURL = URL(fileURLWithPath: "/tmp/collapse-pane-vault", isDirectory: true)
    let paneStore = MemoryWorkspacePaneLayoutStore()
    let state = AppState(
        vaultSelection: .selected(vaultURL),
        workspacePaneLayoutStore: paneStore
    )

    state.setWorkspacePaneLayout(WorkspacePaneLayout(leftSidebarWidth: 333, rightSidebarWidth: 444))
    state.toggleLeftSidebarCollapsed()
    state.toggleRightSidebarCollapsed()

    #expect(state.workspacePaneLayout.leftSidebarWidth == 333)
    #expect(state.workspacePaneLayout.rightSidebarWidth == 444)
    #expect(state.workspacePaneLayout.isLeftSidebarCollapsed)
    #expect(state.workspacePaneLayout.isRightSidebarCollapsed)
    #expect(paneStore.loadLayout(forVaultAt: vaultURL) == state.workspacePaneLayout)
}

@Test
func appStateOpeningGraphDoesNotMutateOrPersistRightPaneCollapse() {
    let vaultURL = URL(fileURLWithPath: "/tmp/graph-pane-vault", isDirectory: true)
    let paneStore = MemoryWorkspacePaneLayoutStore()
    let state = AppState(
        vaultSelection: .selected(vaultURL),
        workspacePaneLayoutStore: paneStore
    )
    state.setWorkspacePaneLayout(WorkspacePaneLayout(leftSidebarWidth: 333, rightSidebarWidth: 444))
    let savesBeforeGraph = paneStore.saveCount

    state.openGraph(source: .ribbon)

    #expect(state.workspaceSelection == .graph)
    #expect(!state.workspacePaneLayout.isRightSidebarCollapsed)
    #expect(state.workspacePaneLayout.rightSidebarWidth == 444)
    #expect(paneStore.saveCount == savesBeforeGraph)
}

@Test
func appStateRemovingRecentVaultClearsStoredPaneLayout() {
    let vaultURL = URL(fileURLWithPath: "/tmp/pane-forgotten-vault", isDirectory: true)
    let otherURL = URL(fileURLWithPath: "/tmp/pane-kept-vault", isDirectory: true)
    let recentStorage = MemoryRecentVaultStorage(urls: [vaultURL, otherURL])
    let paneStore = MemoryWorkspacePaneLayoutStore(layouts: [
        RecentVault.storageKey(for: vaultURL): WorkspacePaneLayout(leftSidebarWidth: 333, rightSidebarWidth: 444),
        RecentVault.storageKey(for: otherURL): WorkspacePaneLayout(leftSidebarWidth: 355, rightSidebarWidth: 466)
    ])
    let state = AppState(
        recentVaultStorage: recentStorage,
        workspacePaneLayoutStore: paneStore
    )

    state.removeRecentVault(at: vaultURL)

    #expect(state.recentVaults.map(\.url) == [otherURL])
    #expect(paneStore.loadLayout(forVaultAt: vaultURL) == nil)
    #expect(paneStore.loadLayout(forVaultAt: otherURL) != nil)
    #expect(paneStore.clearCount == 1)
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
    var errors: [any Error]
    private(set) var openedMetadataURLs: [URL] = []
    private(set) var openedTantivyURLs: [URL] = []

    init(clients: [FakeReadClient] = [], error: (any Error)? = nil, errors: [any Error] = []) {
        self.clients = clients
        self.error = error
        self.errors = errors
    }

    func make(metadataURL: URL, tantivyURL: URL) throws -> any EngineReading {
        openedMetadataURLs.append(metadataURL)
        openedTantivyURLs.append(tantivyURL)
        if !errors.isEmpty {
            throw errors.removeFirst()
        }
        if let error {
            throw error
        }
        return clients.removeFirst()
    }
}

private final class FakeReadIndexRebuilder: ReadIndexRebuilding, @unchecked Sendable {
    let error: (any Error)?
    private(set) var rebuiltVaultURLs: [URL] = []
    private(set) var rebuiltLocations: [AppOwnedIndexLocation] = []

    init(error: (any Error)? = nil) {
        self.error = error
    }

    func rebuildIndex(vaultURL: URL, location: AppOwnedIndexLocation) throws {
        rebuiltVaultURLs.append(vaultURL)
        rebuiltLocations.append(location)
        if let error {
            throw error
        }
    }
}

private final class FakeReadIndexRecoveryScheduler: ReadIndexRecoveryScheduling, @unchecked Sendable {
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

private final class FakeVaultChangeWatcher: VaultChangeWatching {
    private(set) var startedVaultURLs: [URL] = []
    private(set) var activeWatch: FakeVaultChangeWatch?

    func startWatching(
        vaultURL: URL,
        onChange: @escaping () -> Void
    ) throws -> any VaultChangeWatch {
        let watch = FakeVaultChangeWatch(onChange: onChange)
        startedVaultURLs.append(vaultURL.standardizedFileURL)
        activeWatch = watch
        return watch
    }

    func emitChange() {
        activeWatch?.emitChange()
    }
}

private final class FakeVaultChangeWatch: VaultChangeWatch {
    private let onChange: () -> Void
    private(set) var cancelCount = 0

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func emitChange() {
        guard cancelCount == 0 else {
            return
        }
        onChange()
    }

    func cancel() {
        cancelCount += 1
    }
}

private final class FakeVaultIndexRefreshScheduler: VaultIndexRefreshScheduling {
    private var action: (() -> Void)?
    private(set) var scheduledDelays: [TimeInterval] = []
    private(set) var cancelCount = 0

    var pendingActionCount: Int {
        action == nil ? 0 : 1
    }

    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) {
        scheduledDelays.append(delay)
        self.action = action
    }

    func cancel() {
        cancelCount += 1
        action = nil
    }

    func runPending() {
        guard let pending = action else {
            return
        }
        action = nil
        pending()
    }
}

private func engineReadOpenError(code: String) -> EngineReadClientError {
    EngineReadClientError.engine(EngineReadErrorPayload(
        code: code,
        message: code,
        state: EngineReadABI.State.error
    ))
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

private final class MemoryStartupVaultRestoreStorage: StartupVaultRestoreStoring {
    var suppressesLastVaultRestore: Bool
    private(set) var savedValues: [Bool] = []

    init(suppresses: Bool = false) {
        self.suppressesLastVaultRestore = suppresses
    }

    func loadSuppressesLastVaultRestore() -> Bool {
        suppressesLastVaultRestore
    }

    func saveSuppressesLastVaultRestore(_ value: Bool) {
        suppressesLastVaultRestore = value
        savedValues.append(value)
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

private final class MemoryWorkspacePaneLayoutStore: WorkspacePaneLayoutStoring {
    private(set) var savedLayouts: [String: WorkspacePaneLayout] = [:]
    private(set) var saveCount = 0
    private(set) var clearCount = 0

    init(layouts: [String: WorkspacePaneLayout] = [:]) {
        self.savedLayouts = layouts
    }

    func loadLayout(forVaultAt vaultURL: URL) -> WorkspacePaneLayout? {
        savedLayouts[RecentVault.storageKey(for: vaultURL)]
    }

    func saveLayout(_ layout: WorkspacePaneLayout, forVaultAt vaultURL: URL) {
        saveCount += 1
        savedLayouts[RecentVault.storageKey(for: vaultURL)] = layout
    }

    func clearLayout(forVaultAt vaultURL: URL) {
        clearCount += 1
        savedLayouts.removeValue(forKey: RecentVault.storageKey(for: vaultURL))
    }
}

private enum ThrowingIndexDirectoryResolverError: Error {
    case failed
}

private struct ThrowingIndexDirectoryResolver: IndexDirectoryResolving {
    func prepareIndexLocation(forVaultAt vaultURL: URL) throws -> AppOwnedIndexLocation {
        throw ThrowingIndexDirectoryResolverError.failed
    }
}
