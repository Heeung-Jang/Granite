import Foundation
import Testing
@testable import NativeMarkdownCore

@Test
func livePreviewPropertyParserBuildsRowsFromClosedFrontmatter() throws {
    let source = """
    ---
    title: Live Preview Properties
    status: draft
    empty:
    aliases:
      - live preview fixture
      - properties fixture
    count: 42
    html_looking: "<script>alert('nope')</script>"
    secret_token: "fixture-secret-not-real"
    long_value: "This is a deliberately long property value used to verify inert display behavior."
    ---

    # Body
    """

    let block = try #require(LivePreviewPropertyParser.parse(source))

    #expect(block.isClosed)
    #expect(block.rows.map(\.key).contains("title"))
    #expect(block.rows.contains { $0.key == "empty" && $0.value.isEmpty && $0.valueRange == nil })
    #expect(block.rows.contains { $0.key == "aliases" && $0.value == "live preview fixture" })
    #expect(block.rows.contains { $0.key == "aliases" && $0.value == "properties fixture" })
    #expect(block.rows.contains { $0.key == "count" && $0.value == "42" })
    #expect(block.rows.contains { $0.key == "html_looking" && $0.value.contains("<script>") })
    #expect(block.rows.contains { $0.key == "secret_token" && $0.value.contains("fixture-secret") })
    #expect(block.rows.contains { $0.key == "long_value" && $0.value.count > 40 })
    #expect(block.tokenRanges.count >= 8)
}

@Test
func livePreviewPropertyParserLeavesMalformedFrontmatterUnparsed() throws {
    let source = "---\ntitle: Missing close\n# Body\n"
    let block = try #require(LivePreviewPropertyParser.parse(source))

    #expect(!block.isClosed)
    #expect(block.rows.isEmpty)
    #expect(block.tokenRanges.isEmpty)
}

@Test
func livePreviewPropertyParserCapsMalformedFrontmatterScan() throws {
    let body = (0..<2_000).map { "line_\($0): value" }.joined(separator: "\n")
    let source = "---\n\(body)\n# Body\n"
    let block = try #require(LivePreviewPropertyParser.parse(source))

    #expect(!block.isClosed)
    #expect(block.sourceRange.length < (source as NSString).length)
}

@Test
func livePreviewPropertyParserIgnoresAbsentFrontmatter() {
    #expect(LivePreviewPropertyParser.parse("# Body\nstatus: draft\n") == nil)
}
