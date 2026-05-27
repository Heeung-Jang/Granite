import Foundation
import Testing
@testable import NativeMarkdownCore

@Test
func documentSummaryCompressorEmitsTitleAndFirstParagraph() {
    let source = """
    # Release Notes

    This is the first useful paragraph.

    This paragraph is lower priority.
    """

    let result = DocumentSummaryCompressor().compress(source)

    #expect(result.text.contains("Release Notes"))
    #expect(result.text.contains("This is the first useful paragraph."))
    #expect(result.originalByteCount == source.utf8.count)
    #expect(result.compressedByteCount == result.text.utf8.count)
    #expect(result.includedSegmentCount > 0)
}

@Test
func documentSummaryCompressorIncludesSafeFrontmatterKeys() {
    let source = """
    ---
    title: Weekly Review
    date: 2026-05-27
    tags: [swift, summary]
    type: review
    project: Granite
    ---

    Body.
    """

    let result = DocumentSummaryCompressor().compress(source)

    #expect(result.text.contains("Weekly Review"))
    #expect(result.text.contains("date: 2026-05-27"))
    #expect(result.text.contains("tags: swift, summary"))
    #expect(result.text.contains("type: review"))
    #expect(result.text.contains("project: Granite"))
}

@Test
func documentSummaryCompressorExcludesSecretFrontmatterKeys() {
    let source = """
    ---
    title: Safe Title
    token: shh-token
    password: hunter2
    secret: private-secret
    api_key: hidden-key
    private: hidden-private
    credential: hidden-credential
    ---

    Body.
    """

    let result = DocumentSummaryCompressor().compress(source)

    #expect(result.text.contains("Safe Title"))
    #expect(!result.text.contains("shh-token"))
    #expect(!result.text.contains("hunter2"))
    #expect(!result.text.contains("private-secret"))
    #expect(!result.text.contains("hidden-key"))
    #expect(!result.text.contains("hidden-private"))
    #expect(!result.text.contains("hidden-credential"))
}

@Test
func documentSummaryCompressorIgnoresHeadingsInsideFences() {
    let source = """
    ```markdown
    # Not A Heading
    ```

    # Real Heading
    Body.
    """

    let result = DocumentSummaryCompressor().compress(source)

    #expect(result.text.contains("# Real Heading"))
    #expect(!result.text.contains("Not A Heading"))
}

@Test
func documentSummaryCompressorKeepsHeadingOutlineOrder() throws {
    let source = """
    # One
    Intro.

    ## Two
    Body.

    ### Three
    More.
    """

    let text = DocumentSummaryCompressor().compress(source).text
    let one = try #require(text.range(of: "# One")?.lowerBound)
    let two = try #require(text.range(of: "## Two")?.lowerBound)
    let three = try #require(text.range(of: "### Three")?.lowerBound)

    #expect(one < two)
    #expect(two < three)
}

@Test
func documentSummaryCompressorKeepsFirstParagraphPerSection() {
    let source = """
    ## Context
    First context paragraph.

    Second context paragraph should be skipped.

    ## Decision
    First decision paragraph.
    """

    let result = DocumentSummaryCompressor().compress(source)

    #expect(result.text.contains("[Context] First context paragraph."))
    #expect(!result.text.contains("Second context paragraph should be skipped."))
    #expect(result.text.contains("[Decision] First decision paragraph."))
}

@Test
func documentSummaryCompressorExtractsBoundedLists() {
    let source = """
    ## Decisions
    - Keep local processing
      - Preserve privacy
    - Add fast summary
    """

    let result = DocumentSummaryCompressor().compress(source)

    #expect(result.text.contains("Lists:"))
    #expect(result.text.contains("- Keep local processing"))
    #expect(result.text.contains("  - Preserve privacy"))
    #expect(result.text.contains("- Add fast summary"))
}

@Test
func documentSummaryCompressorExtractsCallouts() {
    let source = """
    > [!note] TL;DR
    > Fast summary first.
    > Refined summary later.
    > Extra line should be skipped.
    """

    let result = DocumentSummaryCompressor().compress(source)

    #expect(result.text.contains("Callouts:"))
    #expect(result.text.contains("[!note] TL;DR"))
    #expect(result.text.contains("Fast summary first."))
    #expect(result.text.contains("Refined summary later."))
    #expect(!result.text.contains("Extra line should be skipped."))
}

@Test
func documentSummaryCompressorExtractsRepresentativeTableRows() {
    let source = """
    | Date | Work |
    | --- | --- |
    | 2026-05-25 | Baseline |
    | 2026-05-26 | Cache |
    | 2026-05-27 | Compressor |
    """

    let result = DocumentSummaryCompressor().compress(source)

    #expect(result.text.contains("Tables:"))
    #expect(result.text.contains("| Date | Work |"))
    #expect(result.text.contains("| --- | --- |"))
    #expect(result.text.contains("| 2026-05-25 | Baseline |"))
    #expect(result.text.contains("| 2026-05-27 | Compressor |"))
}

@Test
func documentSummaryCompressorDoesNotTreatMalformedPipeTextAsTable() {
    let source = """
    ## Notes
    This | is not a table.
    Neither is this row.
    """

    let result = DocumentSummaryCompressor().compress(source)

    #expect(!result.text.contains("Tables:"))
    #expect(result.text.contains("This | is not a table. Neither is this row."))
}

@Test
func documentSummaryCompressorEnforcesCharacterBudget() {
    let source = (0..<200)
        .map { "## Section \($0)\n" + String(repeating: "Long content ", count: 30) }
        .joined(separator: "\n\n")

    let result = DocumentSummaryCompressor(maxCharacters: 600).compress(source)

    #expect(result.text.count <= 600)
    #expect(result.truncatedSegmentCount > 0)
    #expect(result.compressedByteCount <= result.originalByteCount)
}

@Test
func documentSummaryCompressorLinearGuardKeepsLargeInputBounded() {
    let source = (0..<5_000)
        .map { "## Section \($0)\nParagraph \($0).\n- Item \($0)" }
        .joined(separator: "\n\n")
    let start = Date()

    let result = DocumentSummaryCompressor(maxCharacters: 2_000).compress(source)

    #expect(Date().timeIntervalSince(start) < 2.0)
    #expect(result.text.count <= 2_000)
    #expect(result.includedSegmentCount > 0)
}
