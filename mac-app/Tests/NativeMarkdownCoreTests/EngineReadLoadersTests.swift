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

    var fileTreeSnapshot = FileTreeSnapshot(items: [], state: .complete)
    var searchPage = SearchPage(requestID: 0, items: [], nextOffset: nil, state: .complete)
    private(set) var fileTreeRequests: [FileTreeRequest] = []
    private(set) var searchRequests: [SearchRequest] = []

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
        .backlinks([])
    }

    func localGraph(
        file: FileTreeItem,
        requestID: UInt64,
        request: LocalGraphRequest
    ) async throws -> LocalGraphSnapshot {
        LocalGraphSnapshot(centerNodeID: file.id, nodes: [], edges: [], state: .complete)
    }

    func livePreviewMetadata(
        file: FileTreeItem,
        requestID: UInt64,
        contents: String
    ) async throws -> EngineLivePreviewMetadata {
        EngineLivePreviewMetadata(outgoingLinks: [], attachments: [])
    }
}
