import Foundation
import Testing
@testable import NativeMarkdownCore

@Test
func engineFileTreeLoaderUsesReadClient() async throws {
    let reader = LoaderFakeReadClient()
    reader.fileTreeSnapshot = FileTreeSnapshot(
        items: [FileTreeItem(relativePath: "Home.md")],
        state: .partial
    )

    let snapshot = try await EngineFileTreeLoader(reader: reader).loadFileTree(
        requestID: 42,
        maxItems: 25
    )

    #expect(snapshot == reader.fileTreeSnapshot)
    #expect(reader.fileTreeRequests == [LoaderFakeReadClient.FileTreeRequest(
        requestID: 42,
        offset: 0,
        limit: 25
    )])
}

@Test
func engineVaultSearchLoaderUsesReadClientAndRejectsEmptyQuery() async throws {
    let reader = LoaderFakeReadClient()
    reader.searchPage = SearchPage(
        requestID: 7,
        items: [SearchHitItem(
            file: FileTreeItem(relativePath: "Home.md"),
            title: "Home",
            snippet: "match",
            rank: 1
        )],
        nextOffset: 20,
        state: .partial
    )

    let page = try await EngineVaultSearchLoader(reader: reader).search(
        query: "  Home  ",
        mode: .body,
        page: SearchPageRequest(requestID: 7, offset: 0, limit: 20)
    )

    #expect(page == reader.searchPage)
    #expect(reader.searchRequests == [LoaderFakeReadClient.SearchRequest(
        query: "Home",
        mode: .body,
        page: SearchPageRequest(requestID: 7, offset: 0, limit: 20)
    )])
    await #expect(throws: VaultSearchError.emptyQuery) {
        _ = try await EngineVaultSearchLoader(reader: reader).search(
            query: "   ",
            mode: .fileName,
            page: SearchPageRequest(requestID: 8, offset: 0, limit: 20)
        )
    }
}

@Test
func engineInspectorGraphAndLivePreviewLoadersUseReadClient() async throws {
    let reader = LoaderFakeReadClient()
    let file = FileTreeItem(relativePath: "Home.md")
    reader.inspectorResult = .tags(["project/native"])
    reader.graphSnapshot = LocalGraphSnapshot(
        centerNodeID: "file:Home.md",
        nodes: [LocalGraphNode(id: "file:Home.md", file: file, label: "Home", kind: .center)],
        edges: [],
        state: .complete
    )
    reader.livePreviewMetadata = EngineLivePreviewMetadata(
        outgoingLinks: [OutgoingLinkItem(
            id: "0-Target",
            label: "Target",
            target: "Target.md",
            heading: nil,
            state: .resolved(FileTreeItem(relativePath: "Target.md"))
        )],
        attachments: []
    )

    let panel = try await EngineInspectorPanelLoader(reader: reader).loadPanel(
        file: file,
        panel: .tags,
        requestID: 11,
        limit: 50
    )
    let graph = try await EngineLocalGraphLoader(reader: reader).loadGraph(
        file: file,
        requestID: 12,
        request: LocalGraphRequest(depth: .twoHop, maxNodes: 10, maxEdges: 20)
    )
    let metadata = try await EngineLivePreviewMetadataLoader(reader: reader).loadMetadata(
        file: file,
        requestID: 13,
        contents: "[[Target]]"
    )

    #expect(panel == .tags(["project/native"]))
    #expect(graph == reader.graphSnapshot)
    #expect(metadata == reader.livePreviewMetadata)
    #expect(reader.inspectorRequests == [LoaderFakeReadClient.InspectorRequest(
        file: file,
        panel: .tags,
        requestID: 11,
        offset: 0,
        limit: 50
    )])
    #expect(reader.graphRequests == [LoaderFakeReadClient.GraphRequest(
        file: file,
        requestID: 12,
        request: LocalGraphRequest(depth: .twoHop, maxNodes: 10, maxEdges: 20)
    )])
    #expect(reader.livePreviewRequests == [LoaderFakeReadClient.LivePreviewRequest(
        file: file,
        requestID: 13,
        contents: "[[Target]]"
    )])
}

private final class LoaderFakeReadClient: EngineReading, @unchecked Sendable {
    struct FileTreeRequest: Equatable {
        let requestID: UInt64
        let offset: Int
        let limit: Int
    }

    struct SearchRequest: Equatable {
        let query: String
        let mode: SearchMode
        let page: SearchPageRequest
    }

    struct InspectorRequest: Equatable {
        let file: FileTreeItem
        let panel: EngineReadInspectorPanel
        let requestID: UInt64
        let offset: Int
        let limit: Int
    }

    struct GraphRequest: Equatable {
        let file: FileTreeItem
        let requestID: UInt64
        let request: LocalGraphRequest
    }

    struct LivePreviewRequest: Equatable {
        let file: FileTreeItem
        let requestID: UInt64
        let contents: String
    }

    var fileTreeSnapshot = FileTreeSnapshot(items: [], state: .complete)
    var searchPage = SearchPage(requestID: 0, items: [], nextOffset: nil, state: .complete)
    var inspectorResult = EngineReadInspectorPanelResult.backlinks([])
    var graphSnapshot = LocalGraphSnapshot(centerNodeID: "", nodes: [], edges: [], state: .complete)
    var livePreviewMetadata = EngineLivePreviewMetadata(outgoingLinks: [], attachments: [])
    private(set) var fileTreeRequests: [FileTreeRequest] = []
    private(set) var searchRequests: [SearchRequest] = []
    private(set) var inspectorRequests: [InspectorRequest] = []
    private(set) var graphRequests: [GraphRequest] = []
    private(set) var livePreviewRequests: [LivePreviewRequest] = []

    func close() {}

    func fileTree(requestID: UInt64, offset: Int, limit: Int) async throws -> FileTreeSnapshot {
        fileTreeRequests.append(FileTreeRequest(requestID: requestID, offset: offset, limit: limit))
        return fileTreeSnapshot
    }

    func search(query: String, mode: SearchMode, page: SearchPageRequest) async throws -> SearchPage {
        searchRequests.append(SearchRequest(query: query, mode: mode, page: page))
        return searchPage
    }

    func inspectorPanel(
        file: FileTreeItem,
        panel: EngineReadInspectorPanel,
        requestID: UInt64,
        offset: Int,
        limit: Int
    ) async throws -> EngineReadInspectorPanelResult {
        inspectorRequests.append(InspectorRequest(
            file: file,
            panel: panel,
            requestID: requestID,
            offset: offset,
            limit: limit
        ))
        return inspectorResult
    }

    func localGraph(
        file: FileTreeItem,
        requestID: UInt64,
        request: LocalGraphRequest
    ) async throws -> LocalGraphSnapshot {
        graphRequests.append(GraphRequest(file: file, requestID: requestID, request: request))
        return graphSnapshot
    }

    func livePreviewMetadata(
        file: FileTreeItem,
        requestID: UInt64,
        contents: String
    ) async throws -> EngineLivePreviewMetadata {
        livePreviewRequests.append(LivePreviewRequest(file: file, requestID: requestID, contents: contents))
        return livePreviewMetadata
    }
}
