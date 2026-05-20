import Testing
@testable import NativeMarkdownCore

@Test
func editorStrategyDefaultsToTextKit1Compatibility() {
    let decision = EditorStrategyDecision()

    #expect(decision.textSystem == .textKit1Compatibility)
    #expect(decision.thresholds.maxDecoratedFileBytes == 5 * 1024 * 1024)
    #expect(decision.thresholds.maxSingleLineCharacters == 100_000)
    #expect(decision.thresholds.maxEmbedCount == 100)
    #expect(decision.thresholds.maxWidgetCount == 250)
    #expect(decision.thresholds.maxAttachmentCount == 100)
    #expect(decision.thresholds.maxTableCellCount == 10_000)
    #expect(decision.thresholds.maxSpanCount == 50_000)
    #expect(decision.thresholds.maxVisibleParseP95Milliseconds == 50)
    #expect(decision.thresholds.maxVisibleRenderP95Milliseconds == 50)
    #expect(decision.thresholds.maxRenderMemoryDeltaBytes == 64 * 1024 * 1024)
    #expect(decision.thresholds.maxVisibleDecorationP95Milliseconds == 50)
    #expect(decision.thresholds.maxTypingP95Milliseconds == 16)
}

@Test
func editorStrategyAllowsNormalDecoratedSource() {
    let decision = EditorStrategyDecision()
    let profile = EditorDocumentProfile(
        byteCount: 512 * 1024,
        longestLineCharacters: 2_000,
        embedCount: 4,
        visibleDecorationP95Milliseconds: 12,
        typingP95Milliseconds: 7
    )

    #expect(decision.renderingMode(for: profile) == .decoratedSource)
}

@Test
func editorStrategyDegradesLargeDocuments() {
    let decision = EditorStrategyDecision()
    let profile = EditorDocumentProfile(
        byteCount: 5 * 1024 * 1024 + 1,
        longestLineCharacters: 2_000,
        embedCount: 4
    )

    #expect(decision.renderingMode(for: profile) == .degradedSource(reason: .fileTooLarge))
}

@Test
func editorStrategyDegradesLongSingleLines() {
    let decision = EditorStrategyDecision()
    let profile = EditorDocumentProfile(
        byteCount: 1024,
        longestLineCharacters: 100_001,
        embedCount: 0
    )

    #expect(decision.renderingMode(for: profile) == .degradedSource(reason: .singleLineTooLong))
}

@Test
func editorStrategyDegradesEmbedHeavyDocuments() {
    let decision = EditorStrategyDecision()
    let profile = EditorDocumentProfile(
        byteCount: 1024,
        longestLineCharacters: 80,
        embedCount: 101
    )

    #expect(decision.renderingMode(for: profile) == .degradedSource(reason: .tooManyEmbeds))
}

@Test
func editorStrategyDegradesPlannedLivePreviewThresholds() {
    let decision = EditorStrategyDecision()

    #expect(decision.renderingMode(for: EditorDocumentProfile(
        byteCount: 1024,
        longestLineCharacters: 80,
        embedCount: 0,
        widgetCount: 251
    )) == .degradedSource(reason: .tooManyWidgets))
    #expect(decision.renderingMode(for: EditorDocumentProfile(
        byteCount: 1024,
        longestLineCharacters: 80,
        embedCount: 0,
        attachmentCount: 101
    )) == .degradedSource(reason: .tooManyAttachments))
    #expect(decision.renderingMode(for: EditorDocumentProfile(
        byteCount: 1024,
        longestLineCharacters: 80,
        embedCount: 0,
        tableCellCount: 10_001
    )) == .degradedSource(reason: .tooManyTableCells))
    #expect(decision.renderingMode(for: EditorDocumentProfile(
        byteCount: 1024,
        longestLineCharacters: 80,
        embedCount: 0,
        spanCount: 50_001
    )) == .degradedSource(reason: .tooManySpans))
    #expect(decision.renderingMode(for: EditorDocumentProfile(
        byteCount: 1024,
        longestLineCharacters: 80,
        embedCount: 0,
        visibleParseP95Milliseconds: 50.1
    )) == .degradedSource(reason: .visibleParseTooSlow))
    #expect(decision.renderingMode(for: EditorDocumentProfile(
        byteCount: 1024,
        longestLineCharacters: 80,
        embedCount: 0,
        visibleRenderP95Milliseconds: 50.1
    )) == .degradedSource(reason: .visibleRenderTooSlow))
    #expect(decision.renderingMode(for: EditorDocumentProfile(
        byteCount: 1024,
        longestLineCharacters: 80,
        embedCount: 0,
        renderMemoryDeltaBytes: 64 * 1024 * 1024 + 1
    )) == .degradedSource(reason: .memoryDeltaTooHigh))
}

@Test
func editorStrategyDegradesSlowRuntimeMetrics() {
    let decision = EditorStrategyDecision()

    #expect(decision.renderingMode(for: EditorDocumentProfile(
        byteCount: 1024,
        longestLineCharacters: 80,
        embedCount: 0,
        visibleDecorationP95Milliseconds: 50.1,
        typingP95Milliseconds: 1
    )) == .degradedSource(reason: .decorationTooSlow))
    #expect(decision.renderingMode(for: EditorDocumentProfile(
        byteCount: 1024,
        longestLineCharacters: 80,
        embedCount: 0,
        visibleDecorationP95Milliseconds: 1,
        typingP95Milliseconds: 16.1
    )) == .degradedSource(reason: .typingTooSlow))
}

@Test
func editorDocumentProfilerMeasuresSourceShape() {
    let longestLine = "very long line ![[image.png]] ![alt](image.png)"
    let text = "# Title\nshort\n\(longestLine)"

    let profile = EditorDocumentProfiler.profile(text)

    #expect(profile.byteCount == text.utf8.count)
    #expect(profile.longestLineCharacters == longestLine.count)
    #expect(profile.embedCount == 2)
}
