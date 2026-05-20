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
    #expect(snapshot.attachments.isEmpty)
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

@Test
func noteInspectorListsAttachmentStates() throws {
    let vaultURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let source = """
        # Home
        ![[attachments/diagram.png]]
        ![[missing.png]]
        ![[duplicate.png]]
        ![[Other]]
        ![[../../secret.png]]
        ![[/tmp/secret.png]]
        ![[~/secret.png]]
        ![[bad\u{0}path.png]]
        ![[./linked.png]]
        ![remote](https://example.com/image.png)
        [passwd](file:///etc/passwd)
        """
    let noteURL = vaultURL.appendingPathComponent("Home.md")
    try write(source, to: noteURL)
    try write("image", to: vaultURL.appendingPathComponent("attachments/diagram.png"))
    try write("a", to: vaultURL.appendingPathComponent("a/duplicate.png"))
    try write("b", to: vaultURL.appendingPathComponent("b/duplicate.png"))
    try write("# Other\n", to: vaultURL.appendingPathComponent("Other.md"))
    try FileManager.default.createSymbolicLink(
        atPath: vaultURL.appendingPathComponent("linked.png").path,
        withDestinationPath: "/tmp/secret.png"
    )

    let snapshot = try FileSystemNoteInspectorLoader().loadInspector(
        at: vaultURL,
        file: FileTreeItem(relativePath: "Home.md"),
        maxFiles: 20
    )

    let states = Dictionary(uniqueKeysWithValues: snapshot.attachments.map { ($0.rawTarget, $0.state) })
    #expect(snapshot.attachments.first?.source == .wikiEmbed)
    #expect(snapshot.attachments.first?.rawTarget == "attachments/diagram.png")
    #expect(states["attachments/diagram.png"] == .resolved(FileTreeItem(relativePath: "attachments/diagram.png")))
    #expect(states["missing.png"] == .missing)
    #expect(states["Other"] == .unsupported)
    #expect(states["../../secret.png"] == .rejected(.outsideVault))
    #expect(states["/tmp/secret.png"] == .rejected(.absolutePath))
    #expect(states["~/secret.png"] == .rejected(.tildePrefix))
    #expect(states["bad\u{0}path.png"] == .rejected(.containsNul))
    #expect(states["./linked.png"] == .rejected(.symlinkEscape))
    #expect(states["https://example.com/image.png"] == .remote)
    #expect(states["file:///etc/passwd"] == .rejected(.urlScheme))

    guard case .duplicate(let duplicates) = states["duplicate.png"] else {
        Issue.record("expected duplicate attachment")
        return
    }
    #expect(duplicates.map(\.relativePath) == ["a/duplicate.png", "b/duplicate.png"])
    #expect(try String(contentsOf: noteURL, encoding: .utf8) == source)
}

@Test
func noteInspectorReportsUnreadableAttachmentWhenFilesystemDoes() throws {
    let vaultURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let unreadableURL = vaultURL.appendingPathComponent("secret.png")
    try write("secret", to: unreadableURL)
    try write("![[secret.png]]", to: vaultURL.appendingPathComponent("Home.md"))
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadableURL.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadableURL.path)
    }

    guard !FileManager.default.isReadableFile(atPath: unreadableURL.path) else {
        return
    }

    let snapshot = try FileSystemNoteInspectorLoader().loadInspector(
        at: vaultURL,
        file: FileTreeItem(relativePath: "Home.md"),
        maxFiles: 20
    )

    #expect(snapshot.attachments.first?.state == .unreadable(FileTreeItem(relativePath: "secret.png")))
}

@Test
func localGraphLoaderBuildsOneHopAndTwoHopGraph() throws {
    let vaultURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try write("# Home\n[[Target]] [[Missing]]", to: vaultURL.appendingPathComponent("Home.md"))
    try write("# Target\n[[Home]] [[Guide]]", to: vaultURL.appendingPathComponent("Target.md"))
    try write("# Guide\n", to: vaultURL.appendingPathComponent("Guide.md"))

    let loader = FileSystemLocalGraphLoader()
    let oneHop = try loader.loadGraph(
        at: vaultURL,
        file: FileTreeItem(relativePath: "Home.md"),
        request: LocalGraphRequest(depth: .oneHop, maxNodes: 10, maxEdges: 10),
        maxFiles: 20
    )

    #expect(oneHop.state == .complete)
    #expect(oneHop.nodes.contains(LocalGraphNode(
        id: "file:Home.md",
        file: FileTreeItem(relativePath: "Home.md"),
        label: "Home.md",
        kind: .center
    )))
    #expect(oneHop.nodes.contains { $0.id == "file:Target.md" && $0.kind == .resolved })
    #expect(oneHop.nodes.contains { $0.id == "unresolved:missing" && $0.kind == .unresolved })
    #expect(!oneHop.nodes.contains { $0.id == "file:Guide.md" })
    #expect(oneHop.edges.count == 3)
    #expect(oneHop.edges.allSatisfy { $0.hop == 1 })

    let twoHop = try loader.loadGraph(
        at: vaultURL,
        file: FileTreeItem(relativePath: "Home.md"),
        request: LocalGraphRequest(depth: .twoHop, maxNodes: 10, maxEdges: 10),
        maxFiles: 20
    )

    #expect(twoHop.nodes.contains { $0.id == "file:Guide.md" && $0.kind == .resolved })
    #expect(twoHop.edges.contains {
        $0.sourceNodeID == "file:Target.md"
            && $0.targetNodeID == "file:Guide.md"
            && $0.hop == 2
    })
}

@Test
func localGraphLoaderReportsPartialWhenCapsAreReached() throws {
    let vaultURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try write("# Home\n[[One]] [[Two]]", to: vaultURL.appendingPathComponent("Home.md"))
    try write("# One\n", to: vaultURL.appendingPathComponent("One.md"))
    try write("# Two\n", to: vaultURL.appendingPathComponent("Two.md"))

    let snapshot = try FileSystemLocalGraphLoader().loadGraph(
        at: vaultURL,
        file: FileTreeItem(relativePath: "Home.md"),
        request: LocalGraphRequest(depth: .oneHop, maxNodes: 2, maxEdges: 10),
        maxFiles: 20
    )

    #expect(snapshot.state == .partial)
    #expect(snapshot.nodes.count == 2)
}

private func write(_ contents: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try contents.write(to: url, atomically: true, encoding: .utf8)
}
