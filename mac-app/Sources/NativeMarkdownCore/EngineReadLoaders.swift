import Foundation

public struct EngineFileTreeLoader: Sendable {
    private let reader: any EngineReading

    public init(reader: any EngineReading) {
        self.reader = reader
    }

    public func loadFileTree(
        requestID: UInt64,
        maxItems: Int
    ) async throws -> FileTreeSnapshot {
        try await reader.fileTree(
            requestID: requestID,
            offset: 0,
            limit: max(1, maxItems)
        )
    }
}

public struct EngineVaultSearchLoader: Sendable {
    private let reader: any EngineReading

    public init(reader: any EngineReading) {
        self.reader = reader
    }

    public func search(
        query: String,
        mode: SearchMode,
        page: SearchPageRequest
    ) async throws -> SearchPage {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            throw VaultSearchError.emptyQuery
        }
        return try await reader.search(
            query: normalizedQuery,
            mode: mode,
            page: page
        )
    }
}
