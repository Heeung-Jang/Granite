import Testing
@testable import NativeMarkdownCore

@Test
func documentSummaryFastPromptContainsContractAndPrivacyGuard() {
    let prompt = DocumentSummaryPromptBuilder.fastPrompt(
        compressedSource: "Heading Outline:\n# Title",
        language: .mixedKoreanEnglish
    )

    #expect(prompt.contains("untrusted"))
    #expect(prompt.contains("Redact credential-like strings"))
    #expect(prompt.contains("한국어로 요약하세요."))
    #expect(prompt.contains("Return exactly these sections"))
    #expect(prompt.contains("핵심 요약:"))
    #expect(prompt.contains("주요 포인트:"))
    #expect(prompt.contains("액션/결정 사항:"))
    #expect(prompt.contains("Heading Outline:\n# Title"))
}

@Test
func documentSummaryParserParsesKoreanFastResponse() throws {
    let summary = try DocumentSummaryParser.parseFast(
        """
        핵심 요약: 빠른 요약입니다.
        주요 포인트:
        - 첫 번째 포인트
        - 두 번째 포인트
        액션/결정 사항:
        - 다음 작업 진행
        """,
        metadata: parserMetadata(language: .korean)
    )

    #expect(summary.overview == "빠른 요약입니다.")
    #expect(summary.keyPoints == ["첫 번째 포인트", "두 번째 포인트"])
    #expect(summary.actionItems == ["다음 작업 진행"])
    #expect(summary.metadata.stage == .fast)
}

@Test
func documentSummaryParserParsesEnglishFastResponse() throws {
    let summary = try DocumentSummaryParser.parseFast(
        """
        Summary: The note explains the fast summary path.
        Key points:
        - Compress markdown structure.
        - Stream one model response.
        Actions:
        - Add the pipeline.
        """,
        metadata: parserMetadata(language: .english)
    )

    #expect(summary.overview == "The note explains the fast summary path.")
    #expect(summary.keyPoints == ["Compress markdown structure.", "Stream one model response."])
    #expect(summary.actionItems == ["Add the pipeline."])
}

@Test
func documentSummaryParserAcceptsLooseBulletOutput() throws {
    let summary = try DocumentSummaryParser.parseFast(
        """
        - First inferred point.
        - Second inferred point.
        """,
        metadata: parserMetadata(language: .english)
    )

    #expect(summary.overview == "First inferred point.")
    #expect(summary.keyPoints == ["First inferred point.", "Second inferred point."])
    #expect(summary.actionItems == ["없음"])
}

@Test
func documentSummaryParserRejectsMalformedFastResponse() {
    #expect(throws: SummaryGenerationError.self) {
        _ = try DocumentSummaryParser.parseFast(
            "",
            metadata: parserMetadata(language: .english)
        )
    }
    #expect(throws: SummaryGenerationError.self) {
        _ = try DocumentSummaryParser.parseFast(
            "This is unstructured noise without summary sections.",
            metadata: parserMetadata(language: .english)
        )
    }
}

private func parserMetadata(language: SummaryLanguage) -> SummaryMetadata {
    SummaryMetadata(
        sourceByteCount: 100,
        chunkCount: 1,
        elapsedMilliseconds: 1,
        language: language,
        stage: .fast
    )
}
