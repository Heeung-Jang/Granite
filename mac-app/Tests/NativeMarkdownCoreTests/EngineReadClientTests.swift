import Foundation
import NativeMarkdownFFI
import Testing
@testable import NativeMarkdownCore

@Test
func engineReadClientReportsMissingLibraryAndSymbol() {
    #expect(throws: EngineReadClientError.missingLibrary(EngineLibraryPath.missingMessage)) {
        _ = try EngineReadClient.open(
            metadataURL: URL(filePath: "/tmp/metadata-v1"),
            tantivyURL: URL(filePath: "/tmp/tantivy"),
            libraryPath: nil
        )
    }

    #expect(throws: EngineReadClientError.missingSymbol("engine_read_file_tree")) {
        _ = try EngineReadClient.open(
            metadataURL: URL(filePath: "/tmp/metadata-v1"),
            tantivyURL: URL(filePath: "/tmp/tantivy"),
            libraryPath: "/tmp/libvault_engine.dylib",
            symbolLoader: { _ in throw EngineReadClientError.missingSymbol("engine_read_file_tree") }
        )
    }
}

@Test
func engineReadClientWrapsReadFFIMethodsAndErrors() async throws {
    EngineReadClientFakeFFI.reset()
    let client = try EngineReadClient.open(
        metadataURL: URL(filePath: "/tmp/metadata-v1"),
        tantivyURL: URL(filePath: "/tmp/tantivy"),
        libraryPath: "/tmp/libvault_engine.dylib",
        symbolLoader: { _ in EngineReadClientFakeFFI.loadedSymbols() }
    )

    EngineReadClientFakeFFI.fileTreeData = {
        var builder = ReadTestBufferBuilder(rowKind: EngineReadABI.RowKind.fileTree)
        builder.appendFileTree(relativePath: builder.string("Folder/Home.md"), displayName: builder.string("Home.md"))
        return builder.finish(rowStride: 40)
    }
    let tree = try await client.fileTree(requestID: 10, offset: 0, limit: 20)
    #expect(tree.items == [FileTreeItem(relativePath: "Folder/Home.md")])

    EngineReadClientFakeFFI.searchData = {
        var builder = ReadTestBufferBuilder(rowKind: EngineReadABI.RowKind.searchHit, requestID: 11)
        builder.appendSearch(relativePath: "Home.md", title: "Home", snippet: "match", rank: 3)
        return builder.finish(rowStride: 40)
    }
    let page = try await Task.detached {
        try await client.search(
            query: "home",
            mode: .body,
            page: SearchPageRequest(requestID: 11, offset: 0, limit: 10)
        )
    }.value
    #expect(page.items.first?.snippet == "match")
    #expect(EngineReadClientFakeFFI.lastSearchMode == EngineReadABI.SearchMode.body)

    EngineReadClientFakeFFI.inspectorData[EngineReadABI.InspectorPanel.backlinks] = {
        var builder = ReadTestBufferBuilder(rowKind: EngineReadABI.RowKind.backlink)
        builder.appendLink(sourcePath: "Source.md", targetPath: "Home.md", targetText: "Home", alias: "", resolution: 1)
        return builder.finish(rowStride: 64)
    }
    let backlinks = try await client.inspectorPanel(
        file: FileTreeItem(relativePath: "Home.md"),
        panel: .backlinks,
        requestID: 12,
        offset: 0,
        limit: 10
    )
    #expect(backlinks == .backlinks([
        BacklinkItem(file: FileTreeItem(relativePath: "Source.md"), snippet: "Home")
    ]))

    EngineReadClientFakeFFI.inspectorData[EngineReadABI.InspectorPanel.outgoing] = {
        var builder = ReadTestBufferBuilder(rowKind: EngineReadABI.RowKind.outgoingLink)
        builder.appendLink(sourcePath: "Home.md", targetPath: "Target.md", targetText: "Target", alias: "Alias", resolution: 1)
        return builder.finish(rowStride: 64)
    }
    let outgoing = try await client.inspectorPanel(
        file: FileTreeItem(relativePath: "Home.md"),
        panel: .outgoing,
        requestID: 13,
        offset: 0,
        limit: 10
    )
    #expect(outgoing == .outgoing([
        OutgoingLinkItem(
            id: "0-Target",
            label: "Alias",
            target: "Target.md",
            heading: nil,
            state: .resolved(FileTreeItem(relativePath: "Target.md"))
        )
    ]))

    EngineReadClientFakeFFI.inspectorData[EngineReadABI.InspectorPanel.tags] = {
        var builder = ReadTestBufferBuilder(rowKind: EngineReadABI.RowKind.tag)
        builder.appendTag("project/native")
        return builder.finish(rowStride: 20)
    }
    let tags = try await client.inspectorPanel(
        file: FileTreeItem(relativePath: "Home.md"),
        panel: .tags,
        requestID: 14,
        offset: 0,
        limit: 10
    )
    #expect(tags == .tags(["project/native"]))

    EngineReadClientFakeFFI.inspectorData[EngineReadABI.InspectorPanel.properties] = {
        var builder = ReadTestBufferBuilder(rowKind: EngineReadABI.RowKind.property)
        builder.appendProperty(key: "status", value: "active", valueKind: 1)
        return builder.finish(rowStride: 28)
    }
    let properties = try await client.inspectorPanel(
        file: FileTreeItem(relativePath: "Home.md"),
        panel: .properties,
        requestID: 15,
        offset: 0,
        limit: 10
    )
    #expect(properties == .properties([PropertyItem(key: "status", value: "active")]))

    EngineReadClientFakeFFI.inspectorData[EngineReadABI.InspectorPanel.attachments] = {
        var builder = ReadTestBufferBuilder(rowKind: EngineReadABI.RowKind.attachment)
        builder.appendAttachment(rawTarget: "image.png", resolvedPath: "assets/image.png", source: 1, state: 1)
        return builder.finish(rowStride: 32)
    }
    let attachments = try await client.inspectorPanel(
        file: FileTreeItem(relativePath: "Home.md"),
        panel: .attachments,
        requestID: 16,
        offset: 0,
        limit: 10
    )
    #expect(attachments == .attachments([
        AttachmentReferenceItem(
            id: "0-wikiEmbed-image.png",
            source: .wikiEmbed,
            rawTarget: "image.png",
            state: .resolved(FileTreeItem(relativePath: "assets/image.png"))
        )
    ]))

    EngineReadClientFakeFFI.graphNodeData = {
        var builder = ReadTestBufferBuilder(rowKind: EngineReadABI.RowKind.graphNode)
        builder.appendGraphNode(id: "file:home", filePath: "Home.md", label: "Home", kind: 1)
        return builder.finish(rowStride: 28)
    }
    EngineReadClientFakeFFI.graphEdgeData = {
        var builder = ReadTestBufferBuilder(rowKind: EngineReadABI.RowKind.graphEdge)
        builder.appendGraphEdge(source: "file:home", target: "file:target", targetText: "Target", direction: 1, hop: 1)
        return builder.finish(rowStride: 36)
    }
    let graph = try await client.localGraph(
        file: FileTreeItem(relativePath: "Home.md"),
        requestID: 17,
        request: LocalGraphRequest(depth: .twoHop, maxNodes: 20, maxEdges: 40)
    )
    #expect(graph.nodes.map(\.id) == ["file:home"])
    #expect(EngineReadClientFakeFFI.lastGraphDepth == EngineReadABI.GraphDepth.twoHop)

    EngineReadClientFakeFFI.livePreviewData = {
        var builder = ReadTestBufferBuilder(rowKind: EngineReadABI.RowKind.livePreviewMetadata)
        builder.appendLivePreview(
            itemKind: 3,
            key: "wikilink",
            value: "Target",
            resolvedPath: "Target.md",
            alias: "",
            state: 1,
            source: 2
        )
        return builder.finish(rowStride: 60)
    }
    let metadata = try await client.livePreviewMetadata(
        file: FileTreeItem(relativePath: "Home.md"),
        requestID: 18,
        contents: "[[Target]]"
    )
    #expect(metadata.outgoingLinks.first?.state == .resolved(FileTreeItem(relativePath: "Target.md")))

    client.close()
    client.close()
    #expect(EngineReadClientFakeFFI.closeCount == 1)
    await #expect(throws: EngineReadClientError.closed) {
        _ = try await client.fileTree(requestID: 19, offset: 0, limit: 10)
    }

    EngineReadClientFakeFFI.reset()
    let errorClient = try EngineReadClient.open(
        metadataURL: URL(filePath: "/tmp/metadata-v1"),
        tantivyURL: URL(filePath: "/tmp/tantivy"),
        libraryPath: "/tmp/libvault_engine.dylib",
        symbolLoader: { _ in EngineReadClientFakeFFI.loadedSymbols() }
    )
    EngineReadClientFakeFFI.searchData = {
        var builder = ReadTestBufferBuilder(
            rowKind: EngineReadABI.RowKind.searchHit,
            state: EngineReadABI.State.error
        )
        builder.setError(code: "search_failed", message: "query failed")
        return builder.finish(rowStride: 40)
    }
    await #expect(throws: EngineReadClientError.engine(EngineReadErrorPayload(
        code: "search_failed",
        message: "query failed",
        state: EngineReadABI.State.error
    ))) {
        _ = try await errorClient.search(
            query: "home",
            mode: .fileName,
            page: SearchPageRequest(requestID: 20, offset: 0, limit: 10)
        )
    }

    EngineReadClientFakeFFI.fileTreeData = {
        var builder = ReadTestBufferBuilder(
            rowKind: EngineReadABI.RowKind.fileTree,
            state: EngineReadABI.State.indexUnavailable
        )
        builder.setError(code: "index_unavailable", message: "metadata missing")
        return builder.finish(rowStride: 40)
    }
    await #expect(throws: EngineReadClientError.engine(EngineReadErrorPayload(
        code: "index_unavailable",
        message: "metadata missing",
        state: EngineReadABI.State.indexUnavailable
    ))) {
        _ = try await errorClient.fileTree(requestID: 21, offset: 0, limit: 10)
    }
    errorClient.close()

    EngineReadClientFakeFFI.reset()
    EngineReadClientFakeFFI.openData = {
        var builder = ReadTestBufferBuilder(
            rowKind: EngineReadABI.RowKind.openStatus,
            state: EngineReadABI.State.indexUnavailable
        )
        builder.setError(code: "open_failed", message: "index unavailable")
        return builder.finish(rowStride: 0)
    }
    #expect(throws: EngineReadClientError.engine(EngineReadErrorPayload(
        code: "open_failed",
        message: "index unavailable",
        state: EngineReadABI.State.indexUnavailable
    ))) {
        _ = try EngineReadClient.open(
            metadataURL: URL(filePath: "/tmp/metadata-v1"),
            tantivyURL: URL(filePath: "/tmp/tantivy"),
            libraryPath: "/tmp/libvault_engine.dylib",
            symbolLoader: { _ in EngineReadClientFakeFFI.loadedSymbols() }
        )
    }
    #expect(EngineReadClientFakeFFI.closeCount == 1)
}

private enum EngineReadClientFakeFFI {
    nonisolated(unsafe) static let handle = UnsafeMutableRawPointer(bitPattern: 0x1234)!
    nonisolated(unsafe) static var openHandle: UnsafeMutableRawPointer? = handle
    nonisolated(unsafe) static var openData: () -> Data = {
        emptyBuffer(rowKind: EngineReadABI.RowKind.openStatus, rowStride: 0)
    }
    nonisolated(unsafe) static var closeCount = 0
    nonisolated(unsafe) static var lastSearchMode: UInt32 = 0
    nonisolated(unsafe) static var lastGraphDepth: UInt32 = 0
    nonisolated(unsafe) static var fileTreeData: () -> Data = { emptyBuffer(rowKind: EngineReadABI.RowKind.fileTree, rowStride: 40) }
    nonisolated(unsafe) static var searchData: () -> Data = { emptyBuffer(rowKind: EngineReadABI.RowKind.searchHit, rowStride: 40) }
    nonisolated(unsafe) static var inspectorData: [UInt32: () -> Data] = [:]
    nonisolated(unsafe) static var graphNodeData: () -> Data = { emptyBuffer(rowKind: EngineReadABI.RowKind.graphNode, rowStride: 28) }
    nonisolated(unsafe) static var graphEdgeData: () -> Data = { emptyBuffer(rowKind: EngineReadABI.RowKind.graphEdge, rowStride: 36) }
    nonisolated(unsafe) static var livePreviewData: () -> Data = {
        emptyBuffer(rowKind: EngineReadABI.RowKind.livePreviewMetadata, rowStride: 60)
    }

    static func reset() {
        openHandle = handle
        openData = { emptyBuffer(rowKind: EngineReadABI.RowKind.openStatus, rowStride: 0) }
        closeCount = 0
        lastSearchMode = 0
        lastGraphDepth = 0
        fileTreeData = { emptyBuffer(rowKind: EngineReadABI.RowKind.fileTree, rowStride: 40) }
        searchData = { emptyBuffer(rowKind: EngineReadABI.RowKind.searchHit, rowStride: 40) }
        inspectorData = [:]
        graphNodeData = { emptyBuffer(rowKind: EngineReadABI.RowKind.graphNode, rowStride: 28) }
        graphEdgeData = { emptyBuffer(rowKind: EngineReadABI.RowKind.graphEdge, rowStride: 36) }
        livePreviewData = { emptyBuffer(rowKind: EngineReadABI.RowKind.livePreviewMetadata, rowStride: 60) }
    }

    static func loadedSymbols() -> LoadedEngineReadSymbols {
        LoadedEngineReadSymbols(
            symbols: EngineReadSymbols(
                open: { metadataPath, tantivyPath in
                    EngineReadClientFakeFFI.open(metadataPath, tantivyPath)
                },
                close: { handle in
                    EngineReadClientFakeFFI.close(handle)
                },
                freeResult: { buffer in
                    EngineReadClientFakeFFI.free(buffer)
                },
                fileTree: { handle, requestID, offset, limit in
                    EngineReadClientFakeFFI.fileTree(handle, requestID, offset, limit)
                },
                search: { handle, requestID, mode, query, offset, limit in
                    EngineReadClientFakeFFI.search(handle, requestID, mode, query, offset, limit)
                },
                inspectorPanel: { handle, requestID, path, panel, offset, limit in
                    EngineReadClientFakeFFI.inspectorPanel(handle, requestID, path, panel, offset, limit)
                },
                localGraph: { handle, requestID, path, depth, maxNodes, maxEdges in
                    EngineReadClientFakeFFI.localGraph(handle, requestID, path, depth, maxNodes, maxEdges)
                },
                livePreviewMetadata: { handle, requestID, path, bytes, len in
                    EngineReadClientFakeFFI.livePreviewMetadata(handle, requestID, path, bytes, len)
                }
            )
        )
    }

    static func open(
        _ metadataPath: UnsafePointer<CChar>?,
        _ tantivyPath: UnsafePointer<CChar>?
    ) -> EngineReadOpenResult {
        EngineReadOpenResult(
            handle: openHandle,
            result: ffiBuffer(openData())
        )
    }

    static func close(_ handle: UnsafeMutableRawPointer?) {
        closeCount += 1
    }

    static func free(_ buffer: EngineReadResultBuffer) {
        buffer.ptr?.deallocate()
    }

    static func fileTree(
        _ handle: UnsafeMutableRawPointer?,
        _ requestID: UInt64,
        _ offset: Int,
        _ limit: Int
    ) -> EngineReadResultBuffer {
        ffiBuffer(fileTreeData())
    }

    static func search(
        _ handle: UnsafeMutableRawPointer?,
        _ requestID: UInt64,
        _ mode: UInt32,
        _ query: UnsafePointer<CChar>?,
        _ offset: Int,
        _ limit: Int
    ) -> EngineReadResultBuffer {
        lastSearchMode = mode
        return ffiBuffer(searchData())
    }

    static func inspectorPanel(
        _ handle: UnsafeMutableRawPointer?,
        _ requestID: UInt64,
        _ path: UnsafePointer<CChar>?,
        _ panel: UInt32,
        _ offset: Int,
        _ limit: Int
    ) -> EngineReadResultBuffer {
        ffiBuffer(inspectorData[panel]?() ?? emptyBuffer(rowKind: EngineReadABI.RowKind.openStatus, rowStride: 0))
    }

    static func localGraph(
        _ handle: UnsafeMutableRawPointer?,
        _ requestID: UInt64,
        _ path: UnsafePointer<CChar>?,
        _ depth: UInt32,
        _ maxNodes: Int,
        _ maxEdges: Int
    ) -> EngineReadLocalGraphResult {
        lastGraphDepth = depth
        return EngineReadLocalGraphResult(
            nodes: ffiBuffer(graphNodeData()),
            edges: ffiBuffer(graphEdgeData())
        )
    }

    static func livePreviewMetadata(
        _ handle: UnsafeMutableRawPointer?,
        _ requestID: UInt64,
        _ path: UnsafePointer<CChar>?,
        _ bytes: UnsafePointer<UInt8>?,
        _ len: Int
    ) -> EngineReadResultBuffer {
        ffiBuffer(livePreviewData())
    }

    static func ffiBuffer(_ data: Data) -> EngineReadResultBuffer {
        let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
        _ = data.copyBytes(to: UnsafeMutableBufferPointer(start: pointer, count: data.count))
        return EngineReadResultBuffer(ptr: pointer, len: data.count, capacity: data.count)
    }

    static func emptyBuffer(rowKind: UInt32, rowStride: UInt32) -> Data {
        ReadTestBufferBuilder(rowKind: rowKind).finish(rowStride: rowStride)
    }
}
