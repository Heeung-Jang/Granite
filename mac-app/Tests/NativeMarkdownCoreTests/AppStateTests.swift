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
