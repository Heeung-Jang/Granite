import Foundation
import Testing
@testable import NativeMarkdownCore

@Test
func editorInteractionDetectsWikiLink() throws {
    let text = "Open [[Target#Details|target note]] now"
    let offset = try utf16Offset(of: "target note", in: text)

    #expect(
        MarkdownEditorInteractionResolver.interaction(in: text, utf16Offset: offset)
            == .wikiLink(EditorWikiLink(raw: "Target#Details|target note", target: "Target", heading: "Details", alias: "target note"))
    )
}

@Test
func editorInteractionDetectsExternalLink() throws {
    let text = "Read [docs](https://example.com/docs) first"
    let offset = try utf16Offset(of: "docs", in: text)

    #expect(
        MarkdownEditorInteractionResolver.interaction(in: text, utf16Offset: offset)
            == .externalLink(EditorExternalLink(rawTarget: "https://example.com/docs"))
    )
}

@Test
func editorInteractionDetectsTag() throws {
    let text = "Track #project/native status"
    let offset = try utf16Offset(of: "project/native", in: text)

    #expect(MarkdownEditorInteractionResolver.interaction(in: text, utf16Offset: offset) == .tag("project/native"))
}

@Test
func editorWikiLinkResolverReportsResolvedMissingDuplicateAndMissingHeading() throws {
    let vaultURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try write("# Target\n## Details\n", to: vaultURL.appendingPathComponent("Target.md"))
    try write("# Duplicate\n", to: vaultURL.appendingPathComponent("A/Duplicate.md"))
    try write("# Duplicate\n", to: vaultURL.appendingPathComponent("B/Duplicate.md"))

    let resolver = FileSystemEditorWikiLinkResolver()

    #expect(
        try resolver.resolve(
            EditorWikiLink(raw: "Target#Details", target: "Target", heading: "Details", alias: nil),
            at: vaultURL
        ) == .resolved(FileTreeItem(relativePath: "Target.md"))
    )
    #expect(
        try resolver.resolve(
            EditorWikiLink(raw: "Missing", target: "Missing", heading: nil, alias: nil),
            at: vaultURL
        ) == .missing
    )
    guard case .duplicate(let duplicates) = try resolver.resolve(
        EditorWikiLink(raw: "Duplicate", target: "Duplicate", heading: nil, alias: nil),
        at: vaultURL
    ) else {
        Issue.record("expected duplicate")
        return
    }
    #expect(duplicates.map(\.relativePath) == ["A/Duplicate.md", "B/Duplicate.md"])
    #expect(
        try resolver.resolve(
            EditorWikiLink(raw: "Target#Absent", target: "Target", heading: "Absent", alias: nil),
            at: vaultURL
        ) == .missingHeading(FileTreeItem(relativePath: "Target.md"), "Absent")
    )
}

private func utf16Offset(of needle: String, in text: String) throws -> Int {
    let range = (text as NSString).range(of: needle)
    try #require(range.location != NSNotFound)
    return range.location
}

private func write(_ contents: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try contents.write(to: url, atomically: true, encoding: .utf8)
}
