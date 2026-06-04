import Testing
@testable import NativeMarkdownCore

@Test
func filePropertySuggestionsIncludeDefaultsAndExistingFrontmatterKeys() {
    let source = "---\nproject: Granite\ntags:\n  - app\n---\n# Body\n"
    let suggestions = FilePropertySuggestions.suggestions(source: source)

    #expect(suggestions.map(\.name).prefix(3) == ["tags", "aliases", "cssclasses"])
    #expect(suggestions.contains(FilePropertySuggestion(name: "project", type: .text, existsInNote: true)))
    #expect(suggestions.contains(FilePropertySuggestion(name: "tags", type: .tags, existsInNote: true)))
}

@Test
func filePropertySuggestionsApplyStoredTypeByPropertyName() {
    let suggestions = FilePropertySuggestions.suggestions(
        source: "# Body\n",
        storedTypes: ["status": .list]
    )

    #expect(suggestions.first { $0.name == "status" }?.type == .list)
}
