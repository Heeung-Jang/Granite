import Foundation
import Testing
@testable import NativeMarkdownCore

@Test
func vaultCreatorCreatesEmptyInitialNoteWithoutObsidianDirectory() throws {
    let parent = try TemporaryVaultFixture()
    defer { parent.remove() }

    let outcome = try VaultCreator().createVault(VaultCreationRequest(
        parentURL: parent.url,
        vaultName: "새 볼트"
    ))

    #expect(outcome.initialNote == FileTreeItem(relativePath: "Untitled.md"))
    #expect(FileManager.default.fileExists(atPath: outcome.vaultURL.path))
    #expect(FileManager.default.fileExists(atPath: outcome.vaultURL.appendingPathComponent("Untitled.md").path))
    #expect(!FileManager.default.fileExists(atPath: outcome.vaultURL.appendingPathComponent(".obsidian").path))
    #expect(try String(contentsOf: outcome.vaultURL.appendingPathComponent("Untitled.md"), encoding: .utf8) == "")
}

@Test
func vaultCreatorRejectsExistingTargetWithoutMutation() throws {
    let parent = try TemporaryVaultFixture()
    defer { parent.remove() }
    try parent.createDirectory(relativePath: "Existing")

    #expect(throws: VaultCreationError.targetAlreadyExists("Existing")) {
        try VaultCreator().createVault(VaultCreationRequest(parentURL: parent.url, vaultName: "Existing"))
    }
    #expect(!FileManager.default.fileExists(atPath: parent.url.appendingPathComponent("Existing/Untitled.md").path))
}

@Test
func vaultCreatorRejectsInvalidNameWithoutMutation() throws {
    let parent = try TemporaryVaultFixture()
    defer { parent.remove() }

    #expect(throws: VaultNameValidationError.containsPathSeparator) {
        try VaultCreator().createVault(VaultCreationRequest(parentURL: parent.url, vaultName: "../Escape"))
    }
    #expect((try? FileManager.default.contentsOfDirectory(atPath: parent.url.path))?.isEmpty == true)
}
