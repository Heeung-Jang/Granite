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
    ), indexDirectoryResolver: AppOwnedIndexDirectoryResolver(applicationSupportRoot: supportRoot))
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
