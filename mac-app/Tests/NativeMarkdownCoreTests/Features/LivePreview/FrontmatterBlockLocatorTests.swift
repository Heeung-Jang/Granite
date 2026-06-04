import Testing
@testable import NativeMarkdownCore

@Test
func frontmatterBlockLocatorFindsClosedBlockAtStart() throws {
    let source = "---\ntitle: Home\n---\n# Body\n"
    let block = try #require(FrontmatterBlockLocator.locateClosedBlock(in: source))

    #expect(String(source[block.contentRange]) == "title: Home\n")
    #expect(String(source[block.closingDelimiterRange]) == "---")
    #expect(block.newline == "\n")
}

@Test
func frontmatterBlockLocatorTreatsUnclosedTopDelimiterAsAbsent() {
    let source = "---\nThis is a thematic break style body.\n"
    #expect(FrontmatterBlockLocator.locateClosedBlock(in: source) == nil)
}

@Test
func frontmatterBlockLocatorPreservesCRLFNewline() throws {
    let source = "---\r\ntitle: Home\r\n---\r\n# Body\r\n"
    let block = try #require(FrontmatterBlockLocator.locateClosedBlock(in: source))

    #expect(block.newline == "\r\n")
    #expect(String(source[block.contentRange]) == "title: Home\r\n")
}

@Test
func frontmatterBlockLocatorIgnoresLaterThematicBreaksWithoutTopFrontmatter() {
    let source = "# Body\n\n---\n"
    #expect(FrontmatterBlockLocator.locateClosedBlock(in: source) == nil)
}
