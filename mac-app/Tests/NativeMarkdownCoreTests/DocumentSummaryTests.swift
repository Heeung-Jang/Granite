import Foundation
import Testing
@testable import NativeMarkdownCore

@Test
func summaryContentHashIsStableAndChangesWithContent() {
    let first = SummaryContentHash.hash("same")
    let second = SummaryContentHash.hash("same")
    let changed = SummaryContentHash.hash("changed")

    #expect(first == second)
    #expect(first != changed)
    #expect(first.count == 16)
}

@Test
func summaryLanguageFollowsKoreanEnglishPolicy() {
    #expect(DocumentSummaryLanguageDetector.detect("한국어 문서") == .korean)
    #expect(DocumentSummaryLanguageDetector.detect("English note") == .english)
    #expect(DocumentSummaryLanguageDetector.detect("한국어 and English") == .mixedKoreanEnglish)
    #expect(DocumentSummaryLanguageDetector.detect("1234") == .other)
}

@Test
func summaryCacheIsVaultScopedAndBounded() async {
    let cache = DocumentSummaryCache(maxEntries: 1, maxEstimatedBytes: 10_000)
    let metadata = SummaryMetadata(sourceByteCount: 10, chunkCount: 1, elapsedMilliseconds: 1, language: .korean)
    let summary = DocumentSummary(overview: "요약", keyPoints: ["A"], actionItems: ["없음"], metadata: metadata)
    let first = SummaryCacheKey(vaultID: "vault-a", fileID: "A.md", contentHash: "hash", promptVersion: 1, summaryFormatVersion: 1, modelPolicyVersion: 1)
    let second = SummaryCacheKey(vaultID: "vault-b", fileID: "A.md", contentHash: "hash", promptVersion: 1, summaryFormatVersion: 1, modelPolicyVersion: 1)

    await cache.insert(SummaryCacheEntry(summary: summary, sourceByteCount: 10, chunkCount: 1, elapsedMilliseconds: 1), for: first)
    #expect(await cache.value(for: first)?.summary == summary)
    #expect(await cache.value(for: second) == nil)

    await cache.insert(SummaryCacheEntry(summary: summary, sourceByteCount: 10, chunkCount: 1, elapsedMilliseconds: 1), for: second)
    #expect(await cache.entryCount == 1)
    #expect(await cache.value(for: first) == nil)
    #expect(await cache.value(for: second)?.summary == summary)
}

@Test
func summaryCacheClearsByVault() async {
    let cache = DocumentSummaryCache(maxEntries: 4, maxEstimatedBytes: 10_000)
    let metadata = SummaryMetadata(sourceByteCount: 10, chunkCount: 1, elapsedMilliseconds: 1, language: .korean)
    let summary = DocumentSummary(overview: "요약", keyPoints: [], actionItems: ["없음"], metadata: metadata)
    let first = SummaryCacheKey(vaultID: "vault-a", fileID: "A.md", contentHash: "a", promptVersion: 1, summaryFormatVersion: 1, modelPolicyVersion: 1)
    let second = SummaryCacheKey(vaultID: "vault-b", fileID: "A.md", contentHash: "a", promptVersion: 1, summaryFormatVersion: 1, modelPolicyVersion: 1)
    let entry = SummaryCacheEntry(summary: summary, sourceByteCount: 10, chunkCount: 1, elapsedMilliseconds: 1)

    await cache.insert(entry, for: first)
    await cache.insert(entry, for: second)
    await cache.clear(vaultID: "vault-a")

    #expect(await cache.value(for: first) == nil)
    #expect(await cache.value(for: second) != nil)
}

@Test
func summaryChunkerSplitsHeadingsAndIgnoresFenceHeadings() throws {
    let source = """
    ---
    api_key: secret
    ---

    # First
    Body

    ```swift
    # Not heading
    ```

    ## Second
    More body
    """

    let chunks = try DocumentSummaryChunker.chunks(
        for: source,
        contextSize: 8_000,
        language: .english,
        limits: DocumentSummaryLimits(fallbackInputCharacters: 200)
    )

    #expect(chunks.count >= 2)
    #expect(chunks.first?.text.contains("api_key") == false)
    #expect(chunks.contains { $0.headingPath.contains("First") })
    #expect(chunks.contains { $0.headingPath.contains("Second") })
    #expect(!chunks.contains { $0.headingPath.contains("Not heading") })
}

@Test
func summaryChunkerRejectsOversizedSource() {
    let source = String(repeating: "a", count: 101)

    #expect(throws: SummaryGenerationError.self) {
        _ = try DocumentSummaryChunker.chunks(
            for: source,
            contextSize: nil,
            language: .english,
            limits: DocumentSummaryLimits(maxSourceBytes: 100)
        )
    }
}

@Test
func summaryPromptContainsPrivacyGuardAndNoWriteInstruction() {
    let prompt = DocumentSummaryPromptBuilder.chunkPrompt(
        chunk: DocumentSummaryChunk(headingPath: ["A"], text: "password: fixture"),
        language: .mixedKoreanEnglish,
        index: 1,
        total: 1
    )

    #expect(prompt.contains("untrusted"))
    #expect(prompt.contains("Redact credential-like strings"))
    #expect(prompt.contains("write files"))
    #expect(!prompt.localizedCaseInsensitiveContains("modify the source"))
}

@Test
func summaryPipelineUsesCacheAndDoesNotCallGeneratorTwice() async throws {
    let generator = FakeSummaryGenerator()
    let cache = DocumentSummaryCache()
    let pipeline = DocumentSummaryPipeline(generator: generator, cache: cache)
    let snapshot = EditorBufferSnapshot(
        vaultID: "vault",
        fileID: "Note.md",
        tabID: UUID(),
        ownerID: UUID(),
        revision: 1,
        contents: "# Title\nBody"
    )
    let request = DocumentSummaryRequest(snapshot: snapshot)

    let first = try await pipeline.summarize(request: request)
    let second = try await pipeline.summarize(request: request)

    #expect(first == second)
    #expect(await generator.generateCount == 1)
}

@Test
func summaryPipelineRejectsStaleRequestBeforeCacheWrite() async throws {
    let generator = FakeSummaryGenerator()
    let cache = DocumentSummaryCache()
    let pipeline = DocumentSummaryPipeline(generator: generator, cache: cache)
    let snapshot = EditorBufferSnapshot(
        vaultID: "vault",
        fileID: "Note.md",
        tabID: UUID(),
        ownerID: UUID(),
        revision: 1,
        contents: "# Title\nBody"
    )
    let request = DocumentSummaryRequest(snapshot: snapshot)
    let freshness = FreshnessCounter(allowBeforeFailure: 3)

    await #expect(throws: SummaryGenerationError.self) {
        _ = try await pipeline.summarize(request: request, isFresh: { _ in
            await freshness.isFresh()
        })
    }

    #expect(await cache.value(for: request.cacheKey) == nil)
}

@Test
func emptySummaryDoesNotCallGenerator() async throws {
    let generator = FakeSummaryGenerator()
    let pipeline = DocumentSummaryPipeline(generator: generator, cache: DocumentSummaryCache())
    let snapshot = EditorBufferSnapshot(
        vaultID: "vault",
        fileID: "Empty.md",
        tabID: UUID(),
        ownerID: UUID(),
        revision: 1,
        contents: "   \n"
    )

    let summary = try await pipeline.summarize(request: DocumentSummaryRequest(snapshot: snapshot))

    #expect(summary.overview == "요약할 본문이 없습니다.")
    #expect(await generator.generateCount == 0)
}

private actor FakeSummaryGenerator: DocumentSummaryGenerating {
    private(set) var generateCount = 0

    func availability() async -> SummaryModelAvailability {
        .available
    }

    func contextSize() async -> Int? {
        8_000
    }

    func tokenCount(_ text: String) async throws -> Int {
        max(1, text.count / 4)
    }

    func generate(prompt: String, maxTokens: Int) async throws -> String {
        generateCount += 1
        return """
        핵심 요약: 테스트 요약입니다.
        주요 포인트:
        - 첫 번째
        액션/결정 사항:
        - 없음
        """
    }
}

private actor FreshnessCounter {
    private var checks = 0
    private let allowBeforeFailure: Int

    init(allowBeforeFailure: Int) {
        self.allowBeforeFailure = allowBeforeFailure
    }

    func isFresh() -> Bool {
        checks += 1
        return checks <= allowBeforeFailure
    }
}
