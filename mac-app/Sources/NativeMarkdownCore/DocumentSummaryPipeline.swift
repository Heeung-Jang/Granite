import Foundation

public struct DocumentSummaryPipeline: Sendable {
    public typealias ProgressHandler = @Sendable (SummaryProgressState) async -> Void
    public typealias FreshnessCheck = @Sendable (DocumentSummaryRequestKey) async -> Bool

    private let generator: any DocumentSummaryGenerating
    private let cache: DocumentSummaryCache

    public init(
        generator: any DocumentSummaryGenerating,
        cache: DocumentSummaryCache
    ) {
        self.generator = generator
        self.cache = cache
    }

    public func summarize(
        request: DocumentSummaryRequest,
        useCache: Bool = true,
        progress: ProgressHandler? = nil,
        isFresh: FreshnessCheck? = nil
    ) async throws -> DocumentSummary {
        let timer = AppTelemetryTimer()
        try await ensureFresh(request.key, isFresh: isFresh)
        await progress?(.analyzing)

        if useCache, let cached = await cache.value(for: request.cacheKey) {
            await progress?(.complete)
            return cached.summary
        }

        let trimmed = request.snapshot.contents.trimmingCharacters(in: .whitespacesAndNewlines)
        let language = DocumentSummaryLanguageDetector.detect(request.snapshot.contents)
        if trimmed.isEmpty {
            let summary = DocumentSummary.empty(metadata: SummaryMetadata(
                sourceByteCount: request.snapshot.byteCount,
                chunkCount: 0,
                elapsedMilliseconds: timer.elapsedMilliseconds(),
                language: language
            ))
            await cache.insert(
                SummaryCacheEntry(
                    summary: summary,
                    sourceByteCount: request.snapshot.byteCount,
                    chunkCount: 0,
                    elapsedMilliseconds: summary.metadata.elapsedMilliseconds
                ),
                for: request.cacheKey
            )
            await progress?(.complete)
            return summary
        }

        switch await generator.availability() {
        case .available:
            break
        case .unavailable(let reason):
            await progress?(.unavailable(reason))
            throw SummaryGenerationError.unavailable(reason)
        }

        try await ensureFresh(request.key, isFresh: isFresh)
        let contextSize = await generator.contextSize()
        try await ensureFresh(request.key, isFresh: isFresh)
        let chunks = try DocumentSummaryChunker.chunks(
            for: request.snapshot.contents,
            contextSize: contextSize,
            language: language,
            limits: request.limits
        )

        if chunks.count == 1 {
            let prompt = DocumentSummaryPromptBuilder.finalPrompt(
                partialSummaries: [chunks[0].text],
                language: language
            )
            _ = try await generator.tokenCount(prompt)
            try await ensureFresh(request.key, isFresh: isFresh)
            await progress?(.finalizing)
            let response = try await generator.generate(prompt: prompt, maxTokens: request.limits.finalOutputTokens)
            try await ensureFresh(request.key, isFresh: isFresh)
            let summary = DocumentSummaryParser.parse(
                response,
                metadata: SummaryMetadata(
                    sourceByteCount: request.snapshot.byteCount,
                    chunkCount: 1,
                    elapsedMilliseconds: timer.elapsedMilliseconds(),
                    language: language
                )
            )
            await cache.insert(cacheEntry(for: summary), for: request.cacheKey)
            await progress?(.complete)
            return summary
        }

        var partials: [String] = []
        for (offset, chunk) in chunks.enumerated() {
            try await ensureFresh(request.key, isFresh: isFresh)
            await progress?(.summarizingChunk(current: offset + 1, total: chunks.count))
            let prompt = DocumentSummaryPromptBuilder.chunkPrompt(
                chunk: chunk,
                language: language,
                index: offset + 1,
                total: chunks.count
            )
            _ = try await generator.tokenCount(prompt)
            try await ensureFresh(request.key, isFresh: isFresh)
            let partial = try await generator.generate(prompt: prompt, maxTokens: request.limits.chunkOutputTokens)
            try await ensureFresh(request.key, isFresh: isFresh)
            partials.append(partial)
        }

        let reduced = try await reducePartials(
            partials,
            language: language,
            limits: request.limits,
            requestKey: request.key,
            isFresh: isFresh
        )
        await progress?(.finalizing)
        let finalPrompt = DocumentSummaryPromptBuilder.finalPrompt(partialSummaries: reduced, language: language)
        _ = try await generator.tokenCount(finalPrompt)
        try await ensureFresh(request.key, isFresh: isFresh)
        let response = try await generator.generate(prompt: finalPrompt, maxTokens: request.limits.finalOutputTokens)
        try await ensureFresh(request.key, isFresh: isFresh)
        let summary = DocumentSummaryParser.parse(
            response,
            metadata: SummaryMetadata(
                sourceByteCount: request.snapshot.byteCount,
                chunkCount: chunks.count,
                elapsedMilliseconds: timer.elapsedMilliseconds(),
                language: language
            )
        )
        await cache.insert(cacheEntry(for: summary), for: request.cacheKey)
        await progress?(.complete)
        return summary
    }

    private func reducePartials(
        _ partials: [String],
        language: SummaryLanguage,
        limits: DocumentSummaryLimits,
        requestKey: DocumentSummaryRequestKey,
        isFresh: FreshnessCheck?
    ) async throws -> [String] {
        var current = partials
        while current.joined(separator: "\n").count > limits.maxReduceInputTokens * 4, current.count > 1 {
            var next: [String] = []
            for batch in current.chunked(size: 8) {
                try await ensureFresh(requestKey, isFresh: isFresh)
                let prompt = DocumentSummaryPromptBuilder.finalPrompt(partialSummaries: batch, language: language)
                let reduced = try await generator.generate(prompt: prompt, maxTokens: limits.chunkOutputTokens)
                try await ensureFresh(requestKey, isFresh: isFresh)
                next.append(reduced)
            }
            current = next
        }
        return current
    }

    private func ensureFresh(
        _ key: DocumentSummaryRequestKey,
        isFresh: FreshnessCheck?
    ) async throws {
        if Task.isCancelled {
            throw SummaryGenerationError.cancelled
        }
        guard let isFresh else {
            return
        }
        if await !isFresh(key) {
            throw SummaryGenerationError.staleRequest
        }
    }

    private func cacheEntry(for summary: DocumentSummary) -> SummaryCacheEntry {
        SummaryCacheEntry(
            summary: summary,
            sourceByteCount: summary.metadata.sourceByteCount,
            chunkCount: summary.metadata.chunkCount,
            elapsedMilliseconds: summary.metadata.elapsedMilliseconds
        )
    }

}

private extension Array {
    func chunked(size: Int) -> [[Element]] {
        let chunkSize = Swift.max(1, size)
        return stride(from: 0, to: count, by: chunkSize).map {
            Array(self[$0..<Swift.min($0 + chunkSize, count)])
        }
    }
}
