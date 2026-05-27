import Foundation

public protocol DocumentSummaryGenerating: Sendable {
    func availability() async -> SummaryModelAvailability
    func contextSize() async -> Int?
    func tokenCount(_ text: String) async throws -> Int
    func generate(prompt: String, maxTokens: Int) async throws -> String
}

public struct DocumentSummaryRequestKey: Hashable, Sendable {
    public let generationID: UUID
    public let vaultID: String
    public let fileID: String
    public let tabID: UUID
    public let ownerID: UUID
    public let bufferRevision: UInt64
    public let contentHash: String

    public init(
        generationID: UUID = UUID(),
        snapshot: EditorBufferSnapshot
    ) {
        self.generationID = generationID
        self.vaultID = snapshot.vaultID
        self.fileID = snapshot.fileID
        self.tabID = snapshot.tabID
        self.ownerID = snapshot.ownerID
        self.bufferRevision = snapshot.revision
        self.contentHash = snapshot.contentHash
    }
}

public struct DocumentSummaryRequest: Sendable {
    public let key: DocumentSummaryRequestKey
    public let snapshot: EditorBufferSnapshot
    public let limits: DocumentSummaryLimits
    public let promptVersion: Int
    public let summaryFormatVersion: Int
    public let modelPolicyVersion: Int

    public init(
        snapshot: EditorBufferSnapshot,
        generationID: UUID = UUID(),
        limits: DocumentSummaryLimits = DocumentSummaryLimits(),
        promptVersion: Int = DocumentSummaryPromptBuilder.promptVersion,
        summaryFormatVersion: Int = DocumentSummaryPromptBuilder.summaryFormatVersion,
        modelPolicyVersion: Int = DocumentSummaryPromptBuilder.modelPolicyVersion
    ) {
        self.key = DocumentSummaryRequestKey(generationID: generationID, snapshot: snapshot)
        self.snapshot = snapshot
        self.limits = limits
        self.promptVersion = promptVersion
        self.summaryFormatVersion = summaryFormatVersion
        self.modelPolicyVersion = modelPolicyVersion
    }

    public var cacheKey: SummaryCacheKey {
        refinedCacheKey
    }

    public var fastCacheKey: SummaryCacheKey {
        cacheKey(stage: .fast)
    }

    public var refinedCacheKey: SummaryCacheKey {
        cacheKey(stage: .refined)
    }

    public var preferredCacheKeys: [SummaryCacheKey] {
        [refinedCacheKey, fastCacheKey]
    }

    public func cacheKey(stage: SummaryStage) -> SummaryCacheKey {
        SummaryCacheKey(
            vaultID: snapshot.vaultID,
            fileID: snapshot.fileID,
            contentHash: snapshot.contentHash,
            promptVersion: promptVersion,
            summaryFormatVersion: summaryFormatVersion,
            modelPolicyVersion: modelPolicyVersion,
            stage: stage
        )
    }
}
