import Foundation

public struct DocumentSummaryLimits: Equatable, Sendable {
    public let maxSourceBytes: Int
    public let maxChunks: Int
    public let maxModelCalls: Int
    public let maxReduceInputTokens: Int
    public let fallbackInputCharacters: Int
    public let chunkOutputTokens: Int
    public let finalOutputTokens: Int

    public init(
        maxSourceBytes: Int = 512 * 1024,
        maxChunks: Int = 64,
        maxModelCalls: Int = 80,
        maxReduceInputTokens: Int = 3_000,
        fallbackInputCharacters: Int = 6_000,
        chunkOutputTokens: Int = 220,
        finalOutputTokens: Int = 500
    ) {
        self.maxSourceBytes = max(1, maxSourceBytes)
        self.maxChunks = max(1, maxChunks)
        self.maxModelCalls = max(1, maxModelCalls)
        self.maxReduceInputTokens = max(1, maxReduceInputTokens)
        self.fallbackInputCharacters = max(200, fallbackInputCharacters)
        self.chunkOutputTokens = max(64, chunkOutputTokens)
        self.finalOutputTokens = max(128, finalOutputTokens)
    }
}
