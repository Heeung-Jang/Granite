import Testing
@testable import NativeMarkdownCore

@Test
func editorStrategyDefaultsToTextKit1Compatibility() {
    let decision = EditorStrategyDecision()

    #expect(decision.textSystem == .textKit1Compatibility)
    #expect(decision.thresholds.maxDecoratedFileBytes == 5 * 1024 * 1024)
    #expect(decision.thresholds.maxSingleLineCharacters == 100_000)
    #expect(decision.thresholds.maxEmbedCount == 100)
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
