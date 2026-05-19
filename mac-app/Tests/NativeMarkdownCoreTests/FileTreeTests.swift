import Foundation
import Testing
@testable import NativeMarkdownCore

@Test
func fileTreeLoaderFindsMarkdownWithoutReadingVaultMetadataDirectories() throws {
    let vaultURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
    try write("", to: vaultURL.appendingPathComponent("Home.md"))
    try write("", to: vaultURL.appendingPathComponent("Projects/Plan.markdown"))
    try write("", to: vaultURL.appendingPathComponent(".obsidian/Internal.md"))
    try write("", to: vaultURL.appendingPathComponent(".git/Ignored.md"))
    try write("", to: vaultURL.appendingPathComponent("image.png"))

    let snapshot = try FileSystemFileTreeLoader().loadFileTree(at: vaultURL, maxItems: 20)

    #expect(snapshot.state == .complete)
    #expect(snapshot.items.map(\.relativePath) == ["Home.md", "Projects/Plan.markdown"])
    #expect(snapshot.items[1].displayName == "Plan.markdown")
    #expect(snapshot.items[1].parentPath == "Projects")
}

@Test
func fileTreeLoaderReportsPartialWhenLimited() throws {
    let vaultURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
    try write("", to: vaultURL.appendingPathComponent("A.md"))
    try write("", to: vaultURL.appendingPathComponent("B.md"))

    let snapshot = try FileSystemFileTreeLoader().loadFileTree(at: vaultURL, maxItems: 1)

    #expect(snapshot.state == .partial)
    #expect(snapshot.items.count == 1)
}

@Test
func fileTreeLoaderReportsCompleteWhenCountEqualsLimit() throws {
    let vaultURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
    try write("", to: vaultURL.appendingPathComponent("A.md"))

    let snapshot = try FileSystemFileTreeLoader().loadFileTree(at: vaultURL, maxItems: 1)

    #expect(snapshot.state == .complete)
    #expect(snapshot.items.map(\.relativePath) == ["A.md"])
}

@Test
func appStateTracksSelectedFileAndClearsItWithVault() {
    let state = AppState(
        engineHealth: EngineHealthStatus(state: .loaded, abiVersion: 1, message: "test"),
        vaultAccessValidator: AllowingFileTreeVaultAccessValidator(),
        recentVaultStorage: MemoryFileTreeRecentVaultStorage()
    )
    let item = FileTreeItem(relativePath: "Home.md")

    state.openFile(item)
    #expect(state.selectedFile == item)

    state.clearVault()
    #expect(state.selectedFile == nil)
}

private func write(_ contents: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try contents.write(to: url, atomically: true, encoding: .utf8)
}

private struct AllowingFileTreeVaultAccessValidator: VaultAccessValidating {
    func validateVault(at url: URL) -> VaultAccessIssue? {
        nil
    }
}

private final class MemoryFileTreeRecentVaultStorage: RecentVaultStoring {
    func loadRecentVaultURLs() -> [URL] {
        []
    }

    func saveRecentVaultURLs(_ urls: [URL]) {}
}
