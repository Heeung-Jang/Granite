import Foundation
import Testing
@testable import NativeMarkdownCore

@Test
func livePreviewRangeMapperRoundTripsUTF16Ranges() throws {
    let source = "A\r\n한글 🙂 e\u{301}\n"
    let koreanRange = try #require(source.range(of: "한글 🙂"))
    let sourceRange = LivePreviewRangeMapper.sourceRange(for: koreanRange, in: source)

    #expect(sourceRange.length == ("한글 🙂" as NSString).length)
    #expect(LivePreviewRangeMapper.stringRange(for: sourceRange, in: source) == koreanRange)
    #expect(LivePreviewRangeMapper.clamped(
        LivePreviewSourceRange(location: 9_999, length: 10),
        in: source
    ).length == 0)
}

@Test
func livePreviewSpanModelsKeepRangeInvariants() {
    let range = LivePreviewSourceRange(location: 4, length: 8)
    let inline = LivePreviewInlineSpan(kind: .strong, sourceRange: range, isEditable: true)
    let block = LivePreviewBlockSpan(
        kind: .paragraph,
        sourceRange: LivePreviewSourceRange(location: 0, length: 20),
        contentRange: LivePreviewSourceRange(location: 0, length: 20),
        inlineSpans: [inline]
    )

    #expect(block.inlineSpans == [inline])
    #expect(block.sourceRange.intersects(range))
    #expect(!range.expanded(by: 2, limit: 20).intersects(LivePreviewSourceRange(location: 20, length: 2)))
}

@Test
func livePreviewParserClassifiesBasicFormattingFixture() throws {
    let source = try fixture("basic-formatting.md")
    let result = LivePreviewParser.parse(source)

    #expect(result.blocks.containsBlock { if case .heading(level: 1) = $0 { true } else { false } })
    #expect(result.blocks.containsBlock { if case .heading(level: 2) = $0 { true } else { false } })
    #expect(result.blocks.containsBlock { $0 == .unorderedList })
    #expect(result.blocks.containsBlock { $0 == .orderedList })
    #expect(result.blocks.containsBlock { if case .taskList(isChecked: false) = $0 { true } else { false } })
    #expect(result.blocks.containsBlock { if case .taskList(isChecked: true) = $0 { true } else { false } })
    #expect(result.blocks.containsBlock { $0 == .blockquote })
    #expect(result.blocks.containsBlock { if case .callout(kind: "note") = $0 { true } else { false } })
    #expect(result.blocks.containsBlock { if case .fencedCode(fence: "```", info: "swift", isClosed: true) = $0 { true } else { false } })

    let paragraph = try #require(result.blocks.first { $0.kind == .paragraph })
    #expect(paragraph.inlineSpans.contains { $0.kind == .strong })
    #expect(paragraph.inlineSpans.contains { $0.kind == .emphasis })
    #expect(paragraph.inlineSpans.contains { $0.kind == .inlineCode })
}

@Test
func livePreviewParserKeepsMalformedFenceBounded() throws {
    let source = "Before\n```swift\nlet value = `not inline`\n"
    let result = LivePreviewParser.parse(source)

    let fence = try #require(result.blocks.first {
        if case .fencedCode = $0.kind {
            return true
        }
        return false
    })
    #expect(fence.inlineSpans.isEmpty)
    #expect(result.blocks.containsBlock {
        if case .fencedCode(fence: "```", info: "swift", isClosed: false) = $0 {
            true
        } else {
            false
        }
    })
    #expect(result.blocks.last?.sourceRange.endLocation == (source as NSString).length)
}

@Test
func livePreviewParserClassifiesFrontmatterWithoutInterpretingValues() throws {
    let properties = try fixture("properties.md")
    let parsedProperties = LivePreviewParser.parse(properties)
    #expect(parsedProperties.blocks.first?.kind == .frontmatter(isClosed: true))
    #expect(parsedProperties.blocks.first?.isInert == true)
    #expect(parsedProperties.blocks.first?.inlineSpans.isEmpty == true)

    let malformed = "---\ntitle: Missing close\n# Body\n"
    let parsedMalformed = LivePreviewParser.parse(malformed)
    #expect(parsedMalformed.blocks.first?.kind == .frontmatter(isClosed: false))

    let absent = "# Body\nNo properties.\n"
    #expect(LivePreviewParser.parse(absent).blocks.first?.kind == .heading(level: 1))
}

@Test
func livePreviewParserDetectsTablesAndLeavesMalformedTablesAsParagraphs() throws {
    let source = try fixture("tables.md")
    let result = LivePreviewParser.parse(source)

    let tableCount = result.blocks.filter { $0.kind == .table }.count
    #expect(tableCount == 3)
    #expect(result.blocks.contains { block in
        block.kind == .paragraph &&
            LivePreviewRangeMapper.stringRange(for: block.sourceRange, in: source).map {
                source[$0].contains("Malformed table:")
            } == true
    })
}

@Test
func livePreviewParserClassifiesEmbedsAsInertCandidates() throws {
    let source = try fixture("embeds.md")
    let result = LivePreviewParser.parse(source)
    let embeds = result.blocks.filter { $0.kind == .embed }

    #expect(embeds.count >= 8)
    #expect(embeds.allSatisfy { $0.isInert })
    #expect(embeds.contains { block in
        LivePreviewRangeMapper.stringRange(for: block.sourceRange, in: source).map {
            source[$0].contains("data:image")
        } == true
    })
}

@Test
func livePreviewParserClassifiesLinksTagsAndInertInlineEmbeds() {
    let source = "Text [[Target#Heading|Alias]] [Label](https://example.com) #상태/검토 ![[image.png]]\n"
    let result = LivePreviewParser.parse(source)
    let inlineSpans = result.blocks.flatMap(\.inlineSpans)

    #expect(inlineSpans.contains { $0.kind == .wikiLink && !$0.isInert })
    #expect(inlineSpans.contains { $0.kind == .markdownLink && !$0.isInert })
    #expect(inlineSpans.contains { $0.kind == .tag })
    #expect(inlineSpans.contains { $0.kind == .wikiLink && $0.isInert })
}

@Test
func livePreviewVisibleParseWindowExpandsAndCapsRange() {
    let source = (0..<100).map { "Line \($0)" }.joined(separator: "\n")
    let visible = LivePreviewSourceRange(location: 60, length: 8)
    let window = LivePreviewVisibleParseWindow.window(
        in: source,
        visibleRange: visible,
        paddingLines: 2,
        maxUTF16Length: 80
    )

    #expect(window.length <= 80)
    #expect(window.location <= visible.location)
    #expect(window.endLocation >= visible.endLocation)
}

@Test
func livePreviewSpanCacheInvalidatesEditedRangesWithNeighbors() {
    var cache = LivePreviewSpanCache()
    let first = LivePreviewParseResult(
        sourceVersion: 1,
        sourceRange: LivePreviewSourceRange(location: 0, length: 10),
        blocks: []
    )
    let second = LivePreviewParseResult(
        sourceVersion: 1,
        sourceRange: LivePreviewSourceRange(location: 30, length: 10),
        blocks: []
    )
    cache.store(first)
    cache.store(second)

    cache.invalidate(
        editedRange: LivePreviewSourceRange(location: 12, length: 1),
        neighborUTF16Padding: 3,
        documentUTF16Length: 100
    )

    #expect(cache.result(for: first.sourceRange, sourceVersion: 1) == nil)
    #expect(cache.result(for: second.sourceRange, sourceVersion: 1) == nil)

    cache.store(LivePreviewParseResult(
        sourceVersion: 2,
        sourceRange: second.sourceRange,
        blocks: []
    ))
    #expect(cache.result(for: second.sourceRange, sourceVersion: 1) == nil)
    #expect(cache.result(for: second.sourceRange, sourceVersion: 2)?.sourceVersion == 2)
}

@Test
func livePreviewRenderVersionGateRejectsStaleWork() {
    var gate = LivePreviewRenderVersionGate()
    let first = gate.nextVersion()
    let second = gate.nextVersion()
    let result = LivePreviewParseResult(
        sourceVersion: second,
        sourceRange: LivePreviewSourceRange(location: 0, length: 1),
        blocks: []
    )

    #expect(!gate.accepts(first))
    #expect(gate.accepts(second))
    #expect(gate.accepts(result))
}

private func fixture(_ name: String) throws -> String {
    let testFileURL = URL(fileURLWithPath: #filePath)
    let repoRoot = testFileURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let fileURL = repoRoot
        .appendingPathComponent("fixtures/live-preview-vault", isDirectory: true)
        .appendingPathComponent(name, isDirectory: false)
    return try String(contentsOf: fileURL, encoding: .utf8)
}

private extension Array where Element == LivePreviewBlockSpan {
    func containsBlock(_ predicate: (LivePreviewBlockKind) -> Bool) -> Bool {
        contains { predicate($0.kind) }
    }
}
