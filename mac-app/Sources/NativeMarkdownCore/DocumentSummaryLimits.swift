import Foundation

public struct DocumentSummaryLimits: Equatable, Sendable {
    public let maxSourceBytes: Int
    public let maxChunks: Int
    public let maxModelCalls: Int
    public let maxReduceInputTokens: Int
    public let fallbackInputCharacters: Int
    public let chunkOutputTokens: Int
    public let fastOutputTokens: Int
    public let finalOutputTokens: Int
    public let refinementSourceByteThreshold: Int

    public init(
        maxSourceBytes: Int = 512 * 1024,
        maxChunks: Int = 64,
        maxModelCalls: Int = 80,
        maxReduceInputTokens: Int = 3_000,
        fallbackInputCharacters: Int = 6_000,
        chunkOutputTokens: Int = 220,
        fastOutputTokens: Int = 280,
        finalOutputTokens: Int = 500,
        refinementSourceByteThreshold: Int = 48 * 1024
    ) {
        self.maxSourceBytes = max(1, maxSourceBytes)
        self.maxChunks = max(1, maxChunks)
        self.maxModelCalls = max(1, maxModelCalls)
        self.maxReduceInputTokens = max(1, maxReduceInputTokens)
        self.fallbackInputCharacters = max(200, fallbackInputCharacters)
        self.chunkOutputTokens = max(64, chunkOutputTokens)
        self.fastOutputTokens = max(64, fastOutputTokens)
        self.finalOutputTokens = max(128, finalOutputTokens)
        self.refinementSourceByteThreshold = max(1, refinementSourceByteThreshold)
    }

    public func shouldRunBackgroundRefinement(sourceByteCount: Int) -> Bool {
        sourceByteCount >= refinementSourceByteThreshold
    }
}
