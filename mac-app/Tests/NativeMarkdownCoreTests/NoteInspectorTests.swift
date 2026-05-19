import Foundation
import Testing
@testable import NativeMarkdownCore

@Test
func noteInspectorLoadsLinksTagsPropertiesAndBacklinks() throws {
    let vaultURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try write(
        """
        ---
        tags: [project/native]
        status: active
        ---
        # Home
        See [[Target#Details|target note]] and #inline/tag.
        """,
        to: vaultURL.appendingPathComponent("Home.md")
    )
    try write(
        """
        # Target
        ## Details
        Back to [[Home]].
        #project/native
        """,
        to: vaultURL.appendingPathComponent("Target.md")
    )

    let snapshot = try FileSystemNoteInspectorLoader().loadInspector(
        at: vaultURL,
        file: FileTreeItem(relativePath: "Home.md"),
        maxFiles: 20
    )

    #expect(snapshot.state == .complete)
    #expect(snapshot.outgoingLinks.count == 1)
    #expect(snapshot.outgoingLinks[0].label == "target note")
    #expect(snapshot.outgoingLinks[0].state == .resolved(FileTreeItem(relativePath: "Target.md")))
    #expect(snapshot.backlinks.map(\.file.relativePath) == ["Target.md"])
    #expect(snapshot.tags == ["inline/tag", "project/native"])
    let projectTag = try #require(snapshot.tagNotes.first { $0.tag == "project/native" })
    #expect(projectTag.files.map(\.relativePath) == ["Target.md"])
    #expect(snapshot.properties.contains(PropertyItem(key: "status", value: "active")))
}

@Test
func noteInspectorMarksMissingDuplicateAndMissingHeadingLinks() throws {
    let vaultURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try write("Links [[Missing]] [[Duplicate]] [[Target#Absent]]", to: vaultURL.appendingPathComponent("Home.md"))
    try write("# Duplicate\n", to: vaultURL.appendingPathComponent("A/Duplicate.md"))
    try write("# Duplicate\n", to: vaultURL.appendingPathComponent("B/Duplicate.md"))
    try write("# Target\n## Present\n", to: vaultURL.appendingPathComponent("Target.md"))

    let snapshot = try FileSystemNoteInspectorLoader().loadInspector(
        at: vaultURL,
        file: FileTreeItem(relativePath: "Home.md"),
        maxFiles: 20
    )

    #expect(snapshot.outgoingLinks[0].state == .missing)
    guard case .duplicate(let duplicates) = snapshot.outgoingLinks[1].state else {
        Issue.record("expected duplicate")
        return
    }
    #expect(duplicates.map(\.relativePath).sorted() == ["A/Duplicate.md", "B/Duplicate.md"])
    #expect(snapshot.outgoingLinks[2].state == .missingHeading(FileTreeItem(relativePath: "Target.md"), "Absent"))
}

@Test
func noteInspectorReportsMalformedFrontmatter() throws {
    let vaultURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try write("---\ntags: [broken\n# Home\n", to: vaultURL.appendingPathComponent("Home.md"))

    let snapshot = try FileSystemNoteInspectorLoader().loadInspector(
        at: vaultURL,
        file: FileTreeItem(relativePath: "Home.md"),
        maxFiles: 20
    )

    #expect(snapshot.warnings == ["Malformed frontmatter"])
}

@Test
func noteInspectorReportsPartialWhenFileTreeIsLimited() throws {
    let vaultURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try write("# Home\n", to: vaultURL.appendingPathComponent("Home.md"))
    try write("# Other\n", to: vaultURL.appendingPathComponent("Other.md"))

    let snapshot = try FileSystemNoteInspectorLoader().loadInspector(
        at: vaultURL,
        file: FileTreeItem(relativePath: "Home.md"),
        maxFiles: 1
    )

    #expect(snapshot.state == .partial)
}

private func write(_ contents: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try contents.write(to: url, atomically: true, encoding: .utf8)
}
