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

public enum EngineInspectorPanelPayload: Equatable, Sendable {
    case backlinks([BacklinkItem])
    case outgoing([OutgoingLinkItem])
    case tags([String])
    case properties([PropertyItem])
    case attachments([AttachmentReferenceItem])
}

public protocol InspectorPanelLoading: Sendable {
    func loadPanel(
        file: FileTreeItem,
        panel: EngineReadInspectorPanel,
        requestID: UInt64,
        offset: Int,
        limit: Int
    ) async throws -> EngineInspectorPanelPayload
}

public struct EngineInspectorPanelLoader: InspectorPanelLoading {
    private let reader: any EngineReading

    public init(reader: any EngineReading) {
        self.reader = reader
    }

    public func loadPanel(
        file: FileTreeItem,
        panel: EngineReadInspectorPanel,
        requestID: UInt64,
        offset: Int = 0,
        limit: Int = 100
    ) async throws -> EngineInspectorPanelPayload {
        let result = try await reader.inspectorPanel(
            file: file,
            panel: panel,
            requestID: requestID,
            offset: offset,
            limit: max(1, limit)
        )
        switch result {
        case .backlinks(let items):
            return .backlinks(items)
        case .outgoing(let items):
            return .outgoing(items)
        case .tags(let items):
            return .tags(items)
        case .properties(let items):
            return .properties(items)
        case .attachments(let items):
            return .attachments(items)
        }
    }
}

public struct EngineLocalGraphLoader: Sendable {
    private let reader: any EngineReading

    public init(reader: any EngineReading) {
        self.reader = reader
    }

    public func loadGraph(
        file: FileTreeItem,
        requestID: UInt64,
        request: LocalGraphRequest
    ) async throws -> LocalGraphSnapshot {
        try await reader.localGraph(file: file, requestID: requestID, request: request)
    }
}

public struct EngineLivePreviewMetadataLoader: Sendable {
    private let reader: any EngineReading

    public init(reader: any EngineReading) {
        self.reader = reader
    }

    public func loadMetadata(
        file: FileTreeItem,
        requestID: UInt64,
        contents: String
    ) async throws -> EngineLivePreviewMetadata {
        try await reader.livePreviewMetadata(file: file, requestID: requestID, contents: contents)
    }
}
