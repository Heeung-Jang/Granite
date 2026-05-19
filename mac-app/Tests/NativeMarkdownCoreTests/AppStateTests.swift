import Foundation
import Testing
@testable import NativeMarkdownCore

@Test
func appStateSelectsAndClearsVault() throws {
    let supportRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let state = AppState(engineHealth: EngineHealthStatus(
        state: .loaded,
        abiVersion: 1,
        message: "test"
    ), indexDirectoryResolver: AppOwnedIndexDirectoryResolver(applicationSupportRoot: supportRoot), vaultAccessValidator: AllowingVaultAccessValidator())
    let url = URL(fileURLWithPath: "/tmp/example-vault", isDirectory: true)

    #expect(state.vaultSelection == .noVault)

    try state.selectVault(url)
    #expect(state.vaultSelection == .selected(url))
    #expect(state.indexLocation != nil)

    state.clearVault()
    #expect(state.vaultSelection == .noVault)
    #expect(state.indexLocation == nil)
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
    #expect(location.rebuildDirectory.path.hasPrefix(supportRoot.path))
    #expect(location.lockFile.path.hasPrefix(supportRoot.path))
    #expect(FileManager.default.fileExists(atPath: location.dataDirectory.path))
    #expect(FileManager.default.fileExists(atPath: location.rebuildDirectory.path))
    #expect(!FileManager.default.fileExists(atPath: location.lockFile.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: vaultURL.path).isEmpty)
    #expect(!location.rootDirectory.path.contains("schema/v1"))
    #expect(!location.rootDirectory.path.contains("sqlite-fts/v1"))
    #expect(!location.rootDirectory.path.contains("unicode61 default"))
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
        vaultAccessValidator: AllowingVaultAccessValidator()
    )
    let url = URL(fileURLWithPath: "/tmp/stale-vault", isDirectory: true)

    state.markStaleBookmark(for: url)

    #expect(state.vaultSelection == .unavailable(.staleBookmark(url)))
    #expect(state.indexLocation == nil)
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
