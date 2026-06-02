import Foundation
import Testing
@testable import NativeMarkdownCore

@Test
func vaultItemCreatorCreatesNotesInRootAndNestedFolders() throws {
    let vault = try TemporaryVaultFixture()
    defer { vault.remove() }
    try vault.createDirectory(relativePath: "Projects")

    let creator = VaultItemCreator()
    let rootNote = try creator.createNote(vaultURL: vault.url, parentFolderPath: "", name: "Daily")
    let nestedNote = try creator.createNote(vaultURL: vault.url, parentFolderPath: "Projects", name: "Plan.md")

    #expect(rootNote == FileTreeItem(relativePath: "Daily.md"))
    #expect(nestedNote == FileTreeItem(relativePath: "Projects/Plan.md"))
    #expect(FileManager.default.fileExists(atPath: vault.url.appendingPathComponent("Daily.md").path))
    #expect(FileManager.default.fileExists(atPath: vault.url.appendingPathComponent("Projects/Plan.md").path))
}

@Test
func vaultItemCreatorRejectsUnsupportedNoteExtensionAndDuplicates() throws {
    let vault = try TemporaryVaultFixture()
    defer { vault.remove() }
    try vault.write("", relativePath: "Existing.md")

    let creator = VaultItemCreator()
    #expect(throws: VaultNameValidationError.unsupportedNoteExtension("txt")) {
        try creator.createNote(vaultURL: vault.url, parentFolderPath: "", name: "Wrong.txt")
    }
    #expect(throws: VaultItemCreationError.targetAlreadyExists("Existing.md")) {
        try creator.createNote(vaultURL: vault.url, parentFolderPath: "", name: "Existing.md")
    }
}

@Test
func vaultItemCreatorCreatesFoldersWithoutPlaceholderFiles() throws {
    let vault = try TemporaryVaultFixture()
    defer { vault.remove() }

    let folderPath = try VaultItemCreator().createFolder(vaultURL: vault.url, parentFolderPath: "", name: "New Folder")

    #expect(folderPath == "New Folder")
    var isDirectory = ObjCBool(false)
    #expect(FileManager.default.fileExists(atPath: vault.url.appendingPathComponent(folderPath).path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)
    #expect((try? FileManager.default.contentsOfDirectory(atPath: vault.url.appendingPathComponent(folderPath).path))?.isEmpty == true)
}

@Test
func vaultItemCreatorRejectsParentPathTraversalAndSymlinkEscape() throws {
    let vault = try TemporaryVaultFixture()
    defer { vault.remove() }
    let outside = try TemporaryVaultFixture()
    defer { outside.remove() }

    let symlinkURL = vault.url.appendingPathComponent("External", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: outside.url)

    let creator = VaultItemCreator()
    #expect(throws: VaultItemCreationError.targetEscapesVault) {
        try creator.createNote(vaultURL: vault.url, parentFolderPath: "../Outside", name: "Escaped")
    }
    #expect(throws: VaultItemCreationError.targetEscapesVault) {
        try creator.createNote(vaultURL: vault.url, parentFolderPath: "External", name: "Escaped")
    }
    #expect(!FileManager.default.fileExists(atPath: outside.url.appendingPathComponent("Escaped.md").path))
}

@Test
func vaultCreationContextResolvesTargetParent() {
    let selectedFile = FileTreeItem(relativePath: "Projects/Plan.md")

    #expect(VaultCreationContext.from(selectedFolderPath: "Inbox", selectedFile: selectedFile).parentFolderPath == "Inbox")
    #expect(VaultCreationContext.from(selectedFolderPath: nil, selectedFile: selectedFile).parentFolderPath == "Projects")
    #expect(VaultCreationContext.from(selectedFolderPath: nil, selectedFile: nil).parentFolderPath == "")
}
