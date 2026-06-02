import Foundation
import Testing
@testable import NativeMarkdownCore

@Test
func vaultNameSuggestionUsesFirstAvailableDefaultNames() throws {
    let folder = try TemporaryVaultFixture()
    defer { folder.remove() }
    let suggestion = VaultNameSuggestion()

    #expect(suggestion.suggestedNoteName(in: folder.url) == "Untitled.md")
    try folder.write("", relativePath: "Untitled.md")
    #expect(suggestion.suggestedNoteName(in: folder.url) == "Untitled 1.md")

    #expect(suggestion.suggestedFolderName(in: folder.url) == "Untitled folder")
    try folder.createDirectory(relativePath: "Untitled folder")
    #expect(suggestion.suggestedFolderName(in: folder.url) == "Untitled folder 1")
}
