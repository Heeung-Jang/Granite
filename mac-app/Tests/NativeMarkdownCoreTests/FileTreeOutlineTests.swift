import Testing
@testable import NativeMarkdownCore

@Test
func fileTreeOutlineCachesLookupAndVisibleRows() {
    let home = FileTreeItem(relativePath: "Codex/Home.md")
    let nested = FileTreeItem(relativePath: "Codex/Conversations/2026/Note.md")
    let guide = FileTreeItem(relativePath: "docs/Guide.md")
    let outline = FileTreeOutline(items: [nested, guide, home])

    #expect(outline.item(withID: "Codex/Home.md") == home)
    #expect(outline.item(withID: "Missing.md") == nil)

    let rootRows = outline.visibleRows(expandedFolderIDs: [])
    #expect(rootRows.map(\.id) == ["Codex", "docs"])

    let codexRows = outline.visibleRows(expandedFolderIDs: ["Codex"])
    #expect(codexRows.map(\.id) == ["Codex", "Codex/Conversations", "Codex/Home.md", "docs"])
    #expect(codexRows.first { $0.id == "Codex" }?.isExpanded == true)
    #expect(codexRows.first { $0.id == "Codex/Home.md" }?.title == "Home")
}

@Test
func fileTreeOutlineExpandsRootAndSelectedAncestors() {
    let selected = FileTreeItem(relativePath: "Codex/Conversations/2026/Note.md")
    let outline = FileTreeOutline(items: [
        selected,
        FileTreeItem(relativePath: "docs/Guide.md")
    ])

    #expect(outline.defaultExpandedFolderIDs(selectedFile: nil) == ["Codex", "docs"])
    #expect(outline.defaultExpandedFolderIDs(selectedFile: selected) == [
        "Codex",
        "Codex/Conversations",
        "Codex/Conversations/2026",
        "docs"
    ])
    #expect(outline.ancestorFolderIDs(for: selected) == [
        "Codex",
        "Codex/Conversations",
        "Codex/Conversations/2026"
    ])
}

@Test
func fileTreeOutlineBuildsOnlyExpandedBranchRows() {
    let outline = FileTreeOutline(items: [
        FileTreeItem(relativePath: "Codex/Conversations/2026/Note.md"),
        FileTreeItem(relativePath: "Codex/Home.md"),
        FileTreeItem(relativePath: "docs/Guide.md")
    ])

    let rows = outline.childRows(
        ofFolderID: "Codex",
        depth: 1,
        expandedFolderIDs: ["Codex", "Codex/Conversations"]
    )

    #expect(rows.map(\.id) == [
        "Codex/Conversations",
        "Codex/Conversations/2026",
        "Codex/Home.md"
    ])
    #expect(rows.first?.depth == 1)
    #expect(rows.first { $0.id == "Codex/Conversations/2026" }?.depth == 2)
    #expect(rows.first { $0.id == "Codex/Home.md" }?.title == "Home")
}
