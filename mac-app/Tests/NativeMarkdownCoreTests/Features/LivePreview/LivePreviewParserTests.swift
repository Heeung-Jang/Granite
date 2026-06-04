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
func livePreviewParserLoadsObsidianMarkersAndRulesFixture() throws {
    let source = try fixture("obsidian-markers-and-rules.md")

    #expect(source.contains("# Obsidian Marker Fixture"))
    #expect(source.contains("- [ ] Pending task"))
    #expect(source.contains("| Name | Status |"))
}

@Test
func livePreviewParserLoadsNestedListHierarchyFixture() throws {
    let source = try fixture("nested-list-hierarchy.md")
    let result = LivePreviewParser.parse(source)

    #expect(source.contains("case: unordered-3-level"))
    #expect(source.contains("case: ordered-width-normalization"))
    #expect(source.contains("case: mixed-bullet-ordered-task"))
    #expect(source.contains("case: code-fence-negative"))
    #expect(result.blocks.containsBlock { $0 == .unorderedList })
    #expect(result.blocks.containsBlock { $0 == .orderedList })
    #expect(result.blocks.containsBlock { if case .taskList(isChecked: false) = $0 { true } else { false } })
    #expect(result.blocks.containsBlock { if case .taskList(isChecked: true) = $0 { true } else { false } })
    #expect(result.blocks.containsBlock { $0 == .horizontalRule })
    #expect(result.blocks.containsBlock { $0 == .table })
    #expect(result.blocks.containsBlock { if case .fencedCode = $0 { true } else { false } })
}

@Test
func livePreviewParserLoadsFencedCodeBlocksFixture() throws {
    let source = try fixture("fenced-code-blocks.md")
    let result = LivePreviewParser.parse(source)
    let fencedBlocks = result.blocks.filter {
        if case .fencedCode = $0.kind {
            return true
        }
        return false
    }

    #expect(fencedBlocks.count >= 14)
    #expect(fencedBlocks.allSatisfy { $0.isInert })
    #expect(fencedBlocks.allSatisfy { $0.inlineSpans.isEmpty })
    #expect(result.blocks.containsBlock { if case .fencedCode(fence: "```", info: "yaml", isClosed: true) = $0 { true } else { false } })
    #expect(result.blocks.containsBlock { if case .fencedCode(fence: "~~~", info: "yaml", isClosed: true) = $0 { true } else { false } })
    #expect(result.blocks.containsBlock { if case .fencedCode(fence: "```", info: "rust", isClosed: false) = $0 { true } else { false } })
}

@Test
func livePreviewParserUsesStrictFenceClosingRules() throws {
    let cases: [(name: String, source: String, expectedFence: String, expectedBody: String)] = [
        (
            name: "longer-backtick-opener",
            source: """
            ````
            body line
            ```
            still code
            ````
            # After
            """,
            expectedFence: "````",
            expectedBody: "still code"
        ),
        (
            name: "trailing-content",
            source: """
            ```text
            body line
            ``` trailing
            still code
            ```
            # After
            """,
            expectedFence: "```",
            expectedBody: "still code"
        ),
        (
            name: "mismatched-tilde-opener",
            source: """
            ~~~text
            body line
            ```
            still code
            ~~~
            # After
            """,
            expectedFence: "~~~",
            expectedBody: "still code"
        )
    ]

    for testCase in cases {
        let result = LivePreviewParser.parse(testCase.source)
        let fencedBlocks = result.blocks.filter {
            if case .fencedCode = $0.kind {
                return true
            }
            return false
        }
        let fence = try #require(fencedBlocks.first, "missing fence for \(testCase.name)")

        if case .fencedCode(let marker, _, let isClosed) = fence.kind {
            #expect(marker == testCase.expectedFence)
            #expect(isClosed)
        } else {
            Issue.record("Expected fenced code for \(testCase.name)")
        }
        #expect(string(for: fence.sourceRange, in: testCase.source)?.contains(testCase.expectedBody) == true)
        #expect(result.blocks.containsBlock { if case .heading(level: 1) = $0 { true } else { false } })
    }
}

@Test
func livePreviewParserStoresOnlyFencedCodeDelimiterTokenRanges() throws {
    let source = """
    ````
    body line
    ``` not a delimiter
    ```
    still code
    ````
    # After
    """
    let result = LivePreviewParser.parse(source)
    let fencedBlock = try #require(result.blocks.first {
        if case .fencedCode = $0.kind {
            return true
        }
        return false
    })
    let tokenStrings = fencedBlock.tokenRanges.compactMap { string(for: $0, in: source) }

    #expect(tokenStrings == ["````", "````"])
    #expect(!tokenStrings.contains("``` not a delimiter"))
    #expect(!tokenStrings.contains("```"))
}

@Test
func livePreviewParserKeepsMarkdownAfterFencedBlocksSeparate() throws {
    let source = """
    # Boundary Fixture

    ```text
    first block
    ```

    ## Between fenced blocks

    ```
    second block
    ```

    ## Next heading after fenced blocks

    ```
    third block
    ```

    Final paragraph outside fenced code.
    """
    let result = LivePreviewParser.parse(source)
    let fencedBlocks = result.blocks.filter {
        if case .fencedCode = $0.kind {
            return true
        }
        return false
    }

    #expect(fencedBlocks.count == 3)
    #expect(result.blocks.containsBlock { if case .heading(level: 2) = $0 { true } else { false } })
    #expect(result.blocks.last?.kind == .paragraph)
    #expect(string(for: result.blocks.last?.sourceRange, in: source)?.contains("Final paragraph") == true)
}

@Test
func livePreviewParserGroupsObsidianCalloutBodyLines() throws {
    let source = """
    > [!summary] TL;DR
    > First line with `code`.
    > - Nested point

    ## Next
    """

    let result = LivePreviewParser.parse(source)
    let callouts = result.blocks.filter {
        if case .callout(kind: "summary") = $0.kind {
            return true
        }
        return false
    }

    #expect(callouts.count == 1)
    let callout = try #require(callouts.first)
    #expect(string(for: callout.sourceRange, in: source)?.contains("Nested point") == true)
    #expect(callout.inlineSpans.contains { $0.kind == .inlineCode })
    #expect(result.blocks.containsBlock { if case .heading(level: 2) = $0 { true } else { false } })
}

@Test
func livePreviewParserHandlesCalloutVariantsAndPlainBlockquotes() {
    let source = """
    > [!NOTE] Uppercase kind
    > Multiline body

    > [!note] Titled callout

    > [!note]- Folded callout
    > Folded body

    > Plain quote
    """
    let result = LivePreviewParser.parse(source)
    let callouts = result.blocks.filter {
        if case .callout(kind: "note") = $0.kind {
            return true
        }
        return false
    }

    #expect(callouts.count == 3)
    #expect(callouts.contains { string(for: $0.sourceRange, in: source)?.contains("Multiline body") == true })
    #expect(result.blocks.containsBlock { $0 == .blockquote })
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
func livePreviewParserClassifiesHorizontalRules() {
    let source = """
    Before
    ---
    ***
    ___
    After
    """
    let result = LivePreviewParser.parse(source)

    let horizontalRules = result.blocks.filter { $0.kind == .horizontalRule }
    #expect(horizontalRules.count == 3)
    #expect(horizontalRules.allSatisfy { string(for: $0.contentRange, in: source)?.count == 3 })
}

@Test
func livePreviewParserKeepsHorizontalRuleFalsePositivesAsOtherBlocks() {
    let source = """
    ----
    - - -
    --- text
        ---
    > ---
    - ---
    ```swift
    ---
    ```
    | A | B |
    | --- | --- |
    | 1 | 2 |
    """
    let result = LivePreviewParser.parse(source)

    #expect(!result.blocks.contains { $0.kind == .horizontalRule })
    #expect(result.blocks.containsBlock { $0 == .blockquote })
    #expect(result.blocks.containsBlock { $0 == .table })
    #expect(result.blocks.containsBlock {
        if case .fencedCode = $0 { true } else { false }
    })
}

@Test
func livePreviewParserTreatsSetextLikeLineAsHorizontalRule() {
    let source = """
    Title
    ---
    """
    let result = LivePreviewParser.parse(source)

    #expect(result.blocks.map(\.kind) == [.paragraph, .horizontalRule])
}

@Test
func livePreviewParserDoesNotTreatFrontmatterDelimitersAsHorizontalRules() throws {
    let source = """
    ---
    title: Test
    ---

    Body
    ---
    """
    let result = LivePreviewParser.parse(source)
    let horizontalRules = result.blocks.filter { $0.kind == .horizontalRule }
    #expect(horizontalRules.count == 1)
    #expect(result.blocks.first?.kind == .frontmatter(isClosed: true))

    let nsSource = source as NSString
    let openingDelimiter = nsSource.range(of: "---")
    let closingDelimiter = nsSource.range(
        of: "---",
        options: [],
        range: NSRange(
            location: openingDelimiter.location + openingDelimiter.length,
            length: nsSource.length - openingDelimiter.location - openingDelimiter.length
        )
    )
    let partial = LivePreviewParser.parse(
        source,
        in: LivePreviewSourceRange(location: closingDelimiter.location, length: closingDelimiter.length)
    )
    #expect(!partial.blocks.contains { $0.kind == .horizontalRule })
}

@Test
func livePreviewParserHandlesCRLFHorizontalRulesAndFrontmatterDelimiters() {
    let source = "---\r\ntitle: CRLF\r\n---\r\n\r\nBody\r\n***\r\n___\r\n"
    let result = LivePreviewParser.parse(source)
    let horizontalRules = result.blocks
        .filter { $0.kind == .horizontalRule }
        .compactMap { string(for: $0.contentRange, in: source) }

    #expect(result.blocks.first?.kind == .frontmatter(isClosed: true))
    #expect(horizontalRules == ["***", "___"])
}

@Test
func livePreviewParserPartialWindowRejectsTableAlignmentRowsAsHorizontalRules() {
    let source = """
    | A | B |
    | --- | --- |
    | 1 | 2 |
    """
    let full = LivePreviewParser.parse(source)
    let alignmentRange = (source as NSString).range(of: "| --- | --- |")
    let partial = LivePreviewParser.parse(
        source,
        in: LivePreviewSourceRange(location: alignmentRange.location, length: alignmentRange.length)
    )

    #expect(full.blocks.contains { $0.kind == .table })
    #expect(!partial.blocks.contains { $0.kind == .horizontalRule })
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
    let source = "Text [[Target#Heading|Alias]] [Label](https://example.com) #project/native #상태/검토 ![[image.png]]\n"
    let result = LivePreviewParser.parse(source)
    let inlineSpans = result.blocks.flatMap(\.inlineSpans)

    #expect(inlineSpans.contains { $0.kind == .wikiLink && !$0.isInert })
    #expect(inlineSpans.contains { $0.kind == .markdownLink && !$0.isInert })
    #expect(inlineSpans.filter { $0.kind == .tag }.count == 2)
    #expect(inlineSpans.contains { $0.kind == .wikiLink && $0.isInert })
    let aliasedWikiLink = try! #require(inlineSpans.first { $0.kind == .wikiLink && !$0.isInert })
    let markdownLink = try! #require(inlineSpans.first { $0.kind == .markdownLink && !$0.isInert })
    let nestedTag = try! #require(inlineSpans.first { string(for: $0.sourceRange, in: source) == "#project/native" })
    let koreanTag = try! #require(inlineSpans.first { string(for: $0.sourceRange, in: source) == "#상태/검토" })
    #expect(string(for: aliasedWikiLink.displayRange, in: source) == "Alias")
    #expect(string(for: markdownLink.displayRange, in: source) == "Label")
    #expect(string(for: nestedTag.displayRange, in: source) == "project/native")
    #expect(string(for: koreanTag.displayRange, in: source) == "상태/검토")
}

@Test
func livePreviewLinkStyleMapAdaptsCoreResolutionStates() {
    let source = "[[Target]] [[Missing]]"
    let result = LivePreviewParser.parse(source)
    let links = result.blocks.flatMap(\.inlineSpans).filter { $0.kind == .wikiLink }
    let map = LivePreviewLinkStyleMap(source: source, outgoingLinks: [
        OutgoingLinkItem(
            id: "0-Target",
            label: "Target",
            target: "Target",
            heading: nil,
            state: .resolved(FileTreeItem(relativePath: "Target.md"))
        ),
        OutgoingLinkItem(
            id: "1-Missing",
            label: "Missing",
            target: "Missing",
            heading: nil,
            state: .missing
        )
    ])

    #expect(map.state(for: links[0]) == .resolved)
    #expect(map.state(for: links[1]) == .missing)
}

@Test
func livePreviewParserKeepsUnsafeWikiTargetsVisibleThroughAliases() {
    let source = """
    [[file:///private/wiki|Open]]
    [[data:text/plain,value|Open]]
    [[javascript:alert(1)|Open]]
    [[/private/wiki|Open]]
    [[Private/Payroll|Open]]
    [[../Secrets|Open]]
    [[http://[::1|Open]]
    """
    let result = LivePreviewParser.parse(source)
    let displayValues = result.blocks
        .flatMap(\.inlineSpans)
        .filter { $0.kind == .wikiLink }
        .compactMap { string(for: $0.displayRange, in: source) }

    #expect(displayValues.contains("file:///private/wiki|Open"))
    #expect(displayValues.contains("data:text/plain,value|Open"))
    #expect(displayValues.contains("javascript:alert(1)|Open"))
    #expect(displayValues.contains("/private/wiki|Open"))
    #expect(displayValues.contains("Private/Payroll|Open"))
    #expect(displayValues.contains("../Secrets|Open"))
    #expect(displayValues.contains("http://[::1|Open"))
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
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let fileURL = repoRoot
        .appendingPathComponent("fixtures/live-preview-vault", isDirectory: true)
        .appendingPathComponent(name, isDirectory: false)
    return try String(contentsOf: fileURL, encoding: .utf8)
}

private func string(for sourceRange: LivePreviewSourceRange?, in source: String) -> String? {
    guard let sourceRange,
          let range = LivePreviewRangeMapper.stringRange(for: sourceRange, in: source)
    else {
        return nil
    }
    return String(source[range])
}

private extension Array where Element == LivePreviewBlockSpan {
    func containsBlock(_ predicate: (LivePreviewBlockKind) -> Bool) -> Bool {
        contains { predicate($0.kind) }
    }
}
