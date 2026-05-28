import Foundation

public struct SummaryCacheKey: Hashable, Sendable {
    public let vaultID: String
    public let fileID: String
    public let contentHash: String
    public let promptVersion: Int
    public let summaryFormatVersion: Int
    public let modelPolicyVersion: Int
    public let stage: SummaryStage

    public init(
        vaultID: String,
        fileID: String,
        contentHash: String,
        promptVersion: Int,
        summaryFormatVersion: Int,
        modelPolicyVersion: Int,
        stage: SummaryStage = .refined
    ) {
        self.vaultID = vaultID
        self.fileID = fileID
        self.contentHash = contentHash
        self.promptVersion = promptVersion
        self.summaryFormatVersion = summaryFormatVersion
        self.modelPolicyVersion = modelPolicyVersion
        self.stage = stage
    }
}

public struct SummaryCacheEntry: Equatable, Sendable {
    public let summary: DocumentSummary
    public let createdAt: Date
    public let sourceByteCount: Int
    public let chunkCount: Int
    public let elapsedMilliseconds: Double
    public let estimatedByteCount: Int

    public init(
        summary: DocumentSummary,
        createdAt: Date = Date(),
        sourceByteCount: Int,
        chunkCount: Int,
        elapsedMilliseconds: Double
    ) {
        self.summary = summary
        self.createdAt = createdAt
        self.sourceByteCount = sourceByteCount
        self.chunkCount = chunkCount
        self.elapsedMilliseconds = elapsedMilliseconds
        self.estimatedByteCount = summary.overview.utf8.count
            + summary.keyPoints.reduce(0) { $0 + $1.utf8.count }
            + summary.actionItems.reduce(0) { $0 + $1.utf8.count }
            + 128
    }
}

public actor DocumentSummaryCache {
    private let maxEntries: Int
    private let maxEstimatedBytes: Int
    private var entries: [SummaryCacheKey: SummaryCacheEntry] = [:]
    private var recency: [SummaryCacheKey] = []
    private var totalEstimatedBytes = 0

    public init(maxEntries: Int = 20, maxEstimatedBytes: Int = 2 * 1024 * 1024) {
        self.maxEntries = max(1, maxEntries)
        self.maxEstimatedBytes = max(1, maxEstimatedBytes)
    }

    public var entryCount: Int {
        entries.count
    }

    public var estimatedBytes: Int {
        totalEstimatedBytes
    }

    public func value(for key: SummaryCacheKey) -> SummaryCacheEntry? {
        guard let entry = entries[key] else {
            return nil
        }
        markRecentlyUsed(key)
        return entry
    }

    public func insert(_ entry: SummaryCacheEntry, for key: SummaryCacheKey) {
        if let existing = entries[key] {
            totalEstimatedBytes -= existing.estimatedByteCount
        }
        entries[key] = entry
        totalEstimatedBytes += entry.estimatedByteCount
        markRecentlyUsed(key)
        evictIfNeeded()
    }

    public func clear() {
        entries.removeAll()
        recency.removeAll()
        totalEstimatedBytes = 0
    }

    public func clear(vaultID: String) {
        let keys = entries.keys.filter { $0.vaultID == vaultID }
        for key in keys {
            if let removed = entries.removeValue(forKey: key) {
                totalEstimatedBytes -= removed.estimatedByteCount
            }
        }
        recency.removeAll { $0.vaultID == vaultID }
    }

    private func markRecentlyUsed(_ key: SummaryCacheKey) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private func evictIfNeeded() {
        while entries.count > maxEntries || totalEstimatedBytes > maxEstimatedBytes {
            guard let oldest = recency.first else {
                break
            }
            recency.removeFirst()
            if let removed = entries.removeValue(forKey: oldest) {
                totalEstimatedBytes -= removed.estimatedByteCount
            }
        }
    }
}
