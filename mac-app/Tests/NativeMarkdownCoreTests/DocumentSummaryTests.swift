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
func summaryStageRawValuesAreStable() {
    #expect(SummaryStage.fast.rawValue == "fast")
    #expect(SummaryStage.refined.rawValue == "refined")
}

@Test
func summaryRequestProvidesStageSpecificCacheKeys() {
    let request = summaryRequestFixture()

    #expect(request.cacheKey == request.refinedCacheKey)
    #expect(request.fastCacheKey.stage == .fast)
    #expect(request.refinedCacheKey.stage == .refined)
    #expect(request.fastCacheKey.vaultID == request.refinedCacheKey.vaultID)
    #expect(request.fastCacheKey.fileID == request.refinedCacheKey.fileID)
    #expect(request.fastCacheKey.contentHash == request.refinedCacheKey.contentHash)
    #expect(request.fastCacheKey.promptVersion == request.refinedCacheKey.promptVersion)
    #expect(request.fastCacheKey.summaryFormatVersion == request.refinedCacheKey.summaryFormatVersion)
    #expect(request.fastCacheKey.modelPolicyVersion == request.refinedCacheKey.modelPolicyVersion)
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
func summaryCacheKeepsFastAndRefinedEntriesSeparate() async {
    let cache = DocumentSummaryCache(maxEntries: 4, maxEstimatedBytes: 10_000)
    let request = summaryRequestFixture()
    let fastSummary = summaryFixture(
        snapshot: request.snapshot,
        stage: .fast,
        overview: "빠른 요약",
        keyPoints: ["빠른 포인트"],
        elapsedMilliseconds: 1
    )
    let refinedSummary = summaryFixture(
        snapshot: request.snapshot,
        stage: .refined,
        overview: "정교화 요약",
        keyPoints: ["정교화 포인트"],
        elapsedMilliseconds: 2
    )

    await cache.insert(summaryCacheEntry(fastSummary), for: request.fastCacheKey)
    await cache.insert(summaryCacheEntry(refinedSummary), for: request.refinedCacheKey)

    #expect(await cache.entryCount == 2)
    #expect(await cache.value(for: request.fastCacheKey)?.summary == fastSummary)
    #expect(await cache.value(for: request.refinedCacheKey)?.summary == refinedSummary)
}

@Test
func summaryRequestPreferredCacheKeysCheckRefinedBeforeFast() async {
    let cache = DocumentSummaryCache(maxEntries: 4, maxEstimatedBytes: 10_000)
    let request = summaryRequestFixture()
    let fastSummary = summaryFixture(
        snapshot: request.snapshot,
        stage: .fast,
        overview: "빠른 요약",
        elapsedMilliseconds: 1
    )
    let refinedSummary = summaryFixture(
        snapshot: request.snapshot,
        stage: .refined,
        overview: "정교화 요약",
        elapsedMilliseconds: 2
    )

    await cache.insert(summaryCacheEntry(fastSummary), for: request.fastCacheKey)
    await cache.insert(summaryCacheEntry(refinedSummary), for: request.refinedCacheKey)

    let firstHit = await firstCachedSummary(for: request.preferredCacheKeys, in: cache)

    #expect(request.preferredCacheKeys.map(\.stage) == [.refined, .fast])
    #expect(firstHit?.summary == refinedSummary)
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

    let finalPrompt = DocumentSummaryPromptBuilder.finalPrompt(
        partialSummaries: ["password: fixture"],
        language: .mixedKoreanEnglish
    )
    #expect(finalPrompt.contains("untrusted"))
    #expect(finalPrompt.contains("write files"))
    #expect(finalPrompt.contains("call tools"))
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
func summaryPipelineCanBypassCacheForRegeneration() async throws {
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

    _ = try await pipeline.summarize(request: request)
    _ = try await pipeline.summarize(request: request, useCache: false)

    #expect(await generator.generateCount == 2)
    #expect(await cache.value(for: request.cacheKey) != nil)
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

@Test
func summaryStreamSnapshotsReplaceRenderedText() async throws {
    let generator = SnapshotSummaryGenerator(snapshots: ["A", "AB"])
    let recorder = StreamSnapshotRecorder()

    let final = try await generator.stream(prompt: "prompt", maxTokens: 10) { snapshot in
        await recorder.apply(snapshot)
    }

    #expect(final == "AB")
    #expect(await recorder.text == "AB")
}

@Test
func summaryFastPipelineStreamsCompressedSourceOnce() async throws {
    let generator = FakeSummaryGenerator()
    let pipeline = DocumentSummaryPipeline(generator: generator, cache: DocumentSummaryCache())
    let request = summaryRequestFixture(contents: longSummarySource())

    let summary = try await pipeline.summarizeFast(request: request)

    #expect(summary.metadata.stage == .fast)
    #expect(await generator.streamCount == 1)
    #expect(await generator.generateCount == 0)
    #expect(await generator.lastStreamPrompt?.contains("Compressed source:") == true)
}

@Test
func summaryFastPipelineUsesFastCache() async throws {
    let generator = FakeSummaryGenerator()
    let cache = DocumentSummaryCache()
    let pipeline = DocumentSummaryPipeline(generator: generator, cache: cache)
    let request = summaryRequestFixture(contents: longSummarySource())

    let first = try await pipeline.summarizeFast(request: request)
    let second = try await pipeline.summarizeFast(request: request)

    #expect(first == second)
    #expect(await generator.streamCount == 1)
    #expect(await cache.value(for: request.fastCacheKey) != nil)
}

@Test
func summaryFastPipelineEmitsStreamingProgress() async throws {
    let generator = FakeSummaryGenerator()
    let pipeline = DocumentSummaryPipeline(generator: generator, cache: DocumentSummaryCache())
    let recorder = SummaryProgressRecorder()

    _ = try await pipeline.summarizeFast(
        request: summaryRequestFixture(contents: longSummarySource()),
        progress: { state in
            await recorder.append(state)
        }
    )

    let states = await recorder.states
    #expect(states.contains(.analyzing))
    #expect(states.contains(.fastStreaming))
    #expect(states.contains(.fastComplete))
}

@Test
func summaryFastPipelineRejectsStaleStreamBeforeCacheWrite() async {
    let generator = FakeSummaryGenerator(streamSnapshots: [
        "핵심 요약: partial",
        "핵심 요약: final"
    ])
    let cache = DocumentSummaryCache()
    let pipeline = DocumentSummaryPipeline(generator: generator, cache: cache)
    let request = summaryRequestFixture(contents: longSummarySource())
    let freshness = FreshnessCounter(allowBeforeFailure: 3)

    await #expect(throws: SummaryGenerationError.self) {
        _ = try await pipeline.summarizeFast(request: request, isFresh: { _ in
            await freshness.isFresh()
        })
    }

    #expect(await cache.value(for: request.fastCacheKey) == nil)
}

@Test
func summaryFastPipelineFallsBackToRefinedGenerateOnMalformedStream() async throws {
    let generator = FakeSummaryGenerator(streamSnapshots: ["unstructured noise"])
    let pipeline = DocumentSummaryPipeline(generator: generator, cache: DocumentSummaryCache())

    let summary = try await pipeline.summarizeFast(request: summaryRequestFixture(contents: "# Title\nBody"))

    #expect(summary.metadata.stage == .refined)
    #expect(await generator.streamCount == 1)
    #expect(await generator.generateCount == 1)
}

@Test
func summaryFastPipelineUsesFastOutputTokenBudget() async throws {
    let generator = FakeSummaryGenerator()
    let pipeline = DocumentSummaryPipeline(generator: generator, cache: DocumentSummaryCache())
    let request = DocumentSummaryRequest(
        snapshot: summaryRequestFixture(contents: longSummarySource()).snapshot,
        limits: DocumentSummaryLimits(fastOutputTokens: 123)
    )

    _ = try await pipeline.summarizeFast(request: request)

    #expect(await generator.lastStreamMaxTokens == 123)
}

private actor FakeSummaryGenerator: DocumentSummaryGenerating {
    private static let defaultResponse = """
    핵심 요약: 테스트 요약입니다.
    주요 포인트:
    - 첫 번째
    액션/결정 사항:
    - 없음
    """

    private(set) var generateCount = 0
    private(set) var streamCount = 0
    private(set) var lastStreamPrompt: String?
    private(set) var lastStreamMaxTokens: Int?
    private let response: String
    private let streamSnapshots: [String]

    init(
        response: String = FakeSummaryGenerator.defaultResponse,
        streamSnapshots: [String]? = nil
    ) {
        self.response = response
        self.streamSnapshots = streamSnapshots ?? [response]
    }

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
        return response
    }

    func stream(
        prompt: String,
        maxTokens: Int,
        onSnapshot: @Sendable (String) async -> Void
    ) async throws -> String {
        streamCount += 1
        lastStreamPrompt = prompt
        lastStreamMaxTokens = maxTokens
        var latest = ""
        for snapshot in streamSnapshots {
            latest = snapshot
            await onSnapshot(snapshot)
        }
        return latest
    }
}

private actor SnapshotSummaryGenerator: DocumentSummaryGenerating {
    private let snapshots: [String]

    init(snapshots: [String]) {
        self.snapshots = snapshots
    }

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
        snapshots.last ?? ""
    }

    func stream(
        prompt: String,
        maxTokens: Int,
        onSnapshot: @Sendable (String) async -> Void
    ) async throws -> String {
        var latest = ""
        for snapshot in snapshots {
            latest = snapshot
            await onSnapshot(snapshot)
        }
        return latest
    }
}

private actor StreamSnapshotRecorder {
    private(set) var text = ""

    func apply(_ snapshot: String) {
        text = DocumentSummaryStreamSnapshotNormalizer.renderedText(
            current: text,
            snapshot: snapshot
        )
    }
}

private actor SummaryProgressRecorder {
    private(set) var states: [SummaryProgressState] = []

    func append(_ state: SummaryProgressState) {
        states.append(state)
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

private func summaryRequestFixture(contents: String = "# Title\nBody") -> DocumentSummaryRequest {
    DocumentSummaryRequest(snapshot: EditorBufferSnapshot(
        vaultID: "vault",
        fileID: "Note.md",
        tabID: UUID(),
        ownerID: UUID(),
        revision: 1,
        contents: contents
    ))
}

private func longSummarySource() -> String {
    (0..<80)
        .map { index in
            """
            ## Section \(index)
            This section explains implementation detail \(index).
            - Decision \(index)
            """
        }
        .joined(separator: "\n\n")
}

private func summaryFixture(
    snapshot: EditorBufferSnapshot,
    stage: SummaryStage,
    overview: String,
    keyPoints: [String] = [],
    elapsedMilliseconds: Double
) -> DocumentSummary {
    DocumentSummary(
        overview: overview,
        keyPoints: keyPoints,
        actionItems: ["없음"],
        metadata: SummaryMetadata(
            sourceByteCount: snapshot.byteCount,
            chunkCount: 1,
            elapsedMilliseconds: elapsedMilliseconds,
            language: .korean,
            stage: stage
        )
    )
}

private func summaryCacheEntry(_ summary: DocumentSummary) -> SummaryCacheEntry {
    SummaryCacheEntry(
        summary: summary,
        sourceByteCount: summary.metadata.sourceByteCount,
        chunkCount: summary.metadata.chunkCount,
        elapsedMilliseconds: summary.metadata.elapsedMilliseconds
    )
}

private func firstCachedSummary(
    for keys: [SummaryCacheKey],
    in cache: DocumentSummaryCache
) async -> SummaryCacheEntry? {
    for key in keys {
        if let entry = await cache.value(for: key) {
            return entry
        }
    }
    return nil
}
