import Darwin
import Foundation
import NativeMarkdownFFI

public enum EngineReadClientError: Error, Equatable {
    case missingLibrary(String)
    case missingSymbol(String)
    case callFailed(String)
    case decode(EngineReadDecodeError)
    case engine(EngineReadErrorPayload)
    case closed
}

public enum EngineReadInspectorPanel: Equatable, Sendable {
    case backlinks
    case outgoing
    case tags
    case properties
    case attachments

    var abiValue: UInt32 {
        switch self {
        case .backlinks:
            EngineReadABI.InspectorPanel.backlinks
        case .outgoing:
            EngineReadABI.InspectorPanel.outgoing
        case .tags:
            EngineReadABI.InspectorPanel.tags
        case .properties:
            EngineReadABI.InspectorPanel.properties
        case .attachments:
            EngineReadABI.InspectorPanel.attachments
        }
    }
}

public enum EngineReadInspectorPanelResult: Equatable, Sendable {
    case backlinks([BacklinkItem])
    case outgoing([OutgoingLinkItem])
    case tags([String])
    case properties([PropertyItem])
    case attachments([AttachmentReferenceItem])
}

public protocol EngineReading: Sendable {
    func close() async
    func fileTree(requestID: UInt64, offset: Int, limit: Int) async throws -> FileTreeSnapshot
    func search(query: String, mode: SearchMode, page: SearchPageRequest) async throws -> SearchPage
    func inspectorPanel(
        file: FileTreeItem,
        panel: EngineReadInspectorPanel,
        requestID: UInt64,
        offset: Int,
        limit: Int
    ) async throws -> EngineReadInspectorPanelResult
    func localGraph(
        file: FileTreeItem,
        requestID: UInt64,
        request: LocalGraphRequest
    ) async throws -> LocalGraphSnapshot
    func livePreviewMetadata(
        file: FileTreeItem,
        requestID: UInt64,
        contents: String
    ) async throws -> EngineLivePreviewMetadata
}

struct EngineReadSymbols: @unchecked Sendable {
    typealias OpenFunction = @convention(c) (
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?
    ) -> EngineReadOpenResult
    typealias CloseFunction = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias FreeResultFunction = @convention(c) (EngineReadResultBuffer) -> Void
    typealias FileTreeFunction = @convention(c) (
        UnsafeMutableRawPointer?,
        UInt64,
        Int,
        Int
    ) -> EngineReadResultBuffer
    typealias SearchFunction = @convention(c) (
        UnsafeMutableRawPointer?,
        UInt64,
        UInt32,
        UnsafePointer<CChar>?,
        Int,
        Int
    ) -> EngineReadResultBuffer
    typealias InspectorPanelFunction = @convention(c) (
        UnsafeMutableRawPointer?,
        UInt64,
        UnsafePointer<CChar>?,
        UInt32,
        Int,
        Int
    ) -> EngineReadResultBuffer
    typealias LocalGraphFunction = @convention(c) (
        UnsafeMutableRawPointer?,
        UInt64,
        UnsafePointer<CChar>?,
        UInt32,
        Int,
        Int
    ) -> EngineReadLocalGraphResult
    typealias LivePreviewMetadataFunction = @convention(c) (
        UnsafeMutableRawPointer?,
        UInt64,
        UnsafePointer<CChar>?,
        UnsafePointer<UInt8>?,
        Int
    ) -> EngineReadResultBuffer

    let open: OpenFunction
    let close: CloseFunction
    let freeResult: FreeResultFunction
    let fileTree: FileTreeFunction
    let search: SearchFunction
    let inspectorPanel: InspectorPanelFunction
    let localGraph: LocalGraphFunction
    let livePreviewMetadata: LivePreviewMetadataFunction

    init(
        open: @escaping OpenFunction,
        close: @escaping CloseFunction,
        freeResult: @escaping FreeResultFunction,
        fileTree: @escaping FileTreeFunction,
        search: @escaping SearchFunction,
        inspectorPanel: @escaping InspectorPanelFunction,
        localGraph: @escaping LocalGraphFunction,
        livePreviewMetadata: @escaping LivePreviewMetadataFunction
    ) {
        self.open = open
        self.close = close
        self.freeResult = freeResult
        self.fileTree = fileTree
        self.search = search
        self.inspectorPanel = inspectorPanel
        self.localGraph = localGraph
        self.livePreviewMetadata = livePreviewMetadata
    }
}

public final class EngineReadClient: EngineReading, @unchecked Sendable {
    typealias SymbolLoader = @Sendable (String?) throws -> LoadedEngineReadSymbols

    private let queue = DispatchQueue(label: "NativeMarkdown.EngineReadClient")
    private let symbols: EngineReadSymbols
    private var handle: UnsafeMutableRawPointer?
    private var libraryHandle: UnsafeMutableRawPointer?

    public static func open(
        metadataURL: URL,
        tantivyURL: URL
    ) throws -> EngineReadClient {
        try open(
            metadataURL: metadataURL,
            tantivyURL: tantivyURL,
            libraryPath: EngineLibraryPath.defaultPath()
        )
    }

    public static func open(
        metadataURL: URL,
        tantivyURL: URL,
        libraryPath: String?
    ) throws -> EngineReadClient {
        try open(
            metadataURL: metadataURL,
            tantivyURL: tantivyURL,
            libraryPath: libraryPath,
            symbolLoader: EngineReadClient.loadSymbols
        )
    }

    static func open(
        metadataURL: URL,
        tantivyURL: URL,
        libraryPath: String?,
        symbolLoader: SymbolLoader
    ) throws -> EngineReadClient {
        let loaded = try symbolLoader(libraryPath)
        let response = metadataURL.path.withCString { metadataPath in
            tantivyURL.path.withCString { tantivyPath in
                loaded.symbols.open(metadataPath, tantivyPath)
            }
        }

        do {
            let data = try data(from: response.result, free: loaded.symbols.freeResult)
            if let error = try errorPayload(from: data) {
                throw EngineReadClientError.engine(error)
            }
            guard let handle = response.handle else {
                throw EngineReadClientError.callFailed("read open returned null handle")
            }
            return EngineReadClient(
                handle: handle,
                symbols: loaded.symbols,
                libraryHandle: loaded.libraryHandle
            )
        } catch {
            if let handle = response.handle {
                loaded.symbols.close(handle)
            }
            if let libraryHandle = loaded.libraryHandle {
                dlclose(libraryHandle)
            }
            throw error
        }
    }

    init(
        handle: UnsafeMutableRawPointer,
        symbols: EngineReadSymbols,
        libraryHandle: UnsafeMutableRawPointer? = nil
    ) {
        self.handle = handle
        self.symbols = symbols
        self.libraryHandle = libraryHandle
    }

    deinit {
        closeLocked()
    }

    public func close() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.closeLocked()
                continuation.resume()
            }
        }
    }

    public func fileTree(
        requestID: UInt64,
        offset: Int,
        limit: Int
    ) async throws -> FileTreeSnapshot {
        try await read { handle in
            let buffer = self.symbols.fileTree(handle, requestID, offset, limit)
            let data = try Self.data(from: buffer, free: self.symbols.freeResult)
            return try Self.decode(data, EngineReadBufferDecoder.decodeFileTree)
        }
    }

    public func search(
        query: String,
        mode: SearchMode,
        page: SearchPageRequest
    ) async throws -> SearchPage {
        try await read { handle in
            try query.withCString { queryPointer in
                let buffer = self.symbols.search(
                    handle,
                    page.requestID,
                    mode.abiValue,
                    queryPointer,
                    page.offset,
                    page.limit
                )
                let data = try Self.data(from: buffer, free: self.symbols.freeResult)
                return try Self.decode(data, EngineReadBufferDecoder.decodeSearch)
            }
        }
    }

    public func inspectorPanel(
        file: FileTreeItem,
        panel: EngineReadInspectorPanel,
        requestID: UInt64,
        offset: Int,
        limit: Int
    ) async throws -> EngineReadInspectorPanelResult {
        try await read { handle in
            try file.relativePath.withCString { pathPointer in
                let buffer = self.symbols.inspectorPanel(
                    handle,
                    requestID,
                    pathPointer,
                    panel.abiValue,
                    offset,
                    limit
                )
                let data = try Self.data(from: buffer, free: self.symbols.freeResult)
                return try Self.decodeInspectorPanel(data, panel: panel)
            }
        }
    }

    public func localGraph(
        file: FileTreeItem,
        requestID: UInt64,
        request: LocalGraphRequest
    ) async throws -> LocalGraphSnapshot {
        try await read { handle in
            try file.relativePath.withCString { pathPointer in
                let result = self.symbols.localGraph(
                    handle,
                    requestID,
                    pathPointer,
                    request.depth.abiValue,
                    request.maxNodes,
                    request.maxEdges
                )
                let nodes = try Self.data(from: result.nodes, free: self.symbols.freeResult)
                let edges = try Self.data(from: result.edges, free: self.symbols.freeResult)
                if let error = try Self.errorPayload(from: nodes) {
                    throw EngineReadClientError.engine(error)
                }
                if let error = try Self.errorPayload(from: edges) {
                    throw EngineReadClientError.engine(error)
                }
                do {
                    return try EngineReadBufferDecoder.decodeGraph(nodes: nodes, edges: edges)
                } catch let error as EngineReadDecodeError {
                    throw EngineReadClientError.decode(error)
                }
            }
        }
    }

    public func livePreviewMetadata(
        file: FileTreeItem,
        requestID: UInt64,
        contents: String
    ) async throws -> EngineLivePreviewMetadata {
        let data = Data(contents.utf8)
        return try await read { handle in
            try file.relativePath.withCString { pathPointer in
                try data.withUnsafeBytes { rawBuffer in
                    let bytes = rawBuffer.bindMemory(to: UInt8.self)
                    let buffer = self.symbols.livePreviewMetadata(
                        handle,
                        requestID,
                        pathPointer,
                        bytes.baseAddress,
                        bytes.count
                    )
                    let response = try Self.data(from: buffer, free: self.symbols.freeResult)
                    return try Self.decode(response, EngineReadBufferDecoder.decodeLivePreviewMetadata)
                }
            }
        }
    }

    private func read<T>(_ body: @escaping @Sendable (UnsafeMutableRawPointer) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let handle = self.handle else {
                    continuation.resume(throwing: EngineReadClientError.closed)
                    return
                }
                do {
                    continuation.resume(returning: try body(handle))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func closeLocked() {
        if let handle {
            symbols.close(handle)
            self.handle = nil
        }
        if let libraryHandle {
            dlclose(libraryHandle)
            self.libraryHandle = nil
        }
    }

    private static func decode<Value>(
        _ data: Data,
        _ decoder: (Data) throws -> Value
    ) throws -> Value {
        if let error = try errorPayload(from: data) {
            throw EngineReadClientError.engine(error)
        }
        do {
            return try decoder(data)
        } catch let error as EngineReadDecodeError {
            throw EngineReadClientError.decode(error)
        }
    }

    private static func decodeInspectorPanel(
        _ data: Data,
        panel: EngineReadInspectorPanel
    ) throws -> EngineReadInspectorPanelResult {
        switch panel {
        case .backlinks:
            return .backlinks(try decode(data, EngineReadBufferDecoder.decodeBacklinks))
        case .outgoing:
            return .outgoing(try decode(data, EngineReadBufferDecoder.decodeOutgoingLinks))
        case .tags:
            return .tags(try decode(data, EngineReadBufferDecoder.decodeTags))
        case .properties:
            return .properties(try decode(data, EngineReadBufferDecoder.decodeProperties))
        case .attachments:
            return .attachments(try decode(data, EngineReadBufferDecoder.decodeAttachments))
        }
    }

    private static func data(
        from buffer: EngineReadResultBuffer,
        free: EngineReadSymbols.FreeResultFunction
    ) throws -> Data {
        guard let pointer = buffer.ptr, buffer.len > 0 else {
            throw EngineReadClientError.callFailed("read FFI returned empty buffer")
        }
        defer {
            free(buffer)
        }
        return Data(bytes: pointer, count: buffer.len)
    }

    private static func errorPayload(from data: Data) throws -> EngineReadErrorPayload? {
        do {
            return try EngineReadBufferDecoder.decodeErrorPayload(data)
        } catch let error as EngineReadDecodeError {
            throw EngineReadClientError.decode(error)
        }
    }

    private static func loadSymbols(libraryPath: String?) throws -> LoadedEngineReadSymbols {
        guard let libraryPath, !libraryPath.isEmpty else {
            throw EngineReadClientError.missingLibrary(EngineLibraryPath.missingMessage)
        }
        guard let handle = dlopen(libraryPath, RTLD_NOW | RTLD_LOCAL) else {
            throw EngineReadClientError.missingLibrary(dynamicLoaderError())
        }

        do {
            let symbols = try EngineReadSymbols(
                open: loadSymbol(handle, "engine_read_open", as: EngineReadSymbols.OpenFunction.self),
                close: loadSymbol(handle, "engine_read_close", as: EngineReadSymbols.CloseFunction.self),
                freeResult: loadSymbol(handle, "engine_read_result_free", as: EngineReadSymbols.FreeResultFunction.self),
                fileTree: loadSymbol(handle, "engine_read_file_tree", as: EngineReadSymbols.FileTreeFunction.self),
                search: loadSymbol(handle, "engine_read_search", as: EngineReadSymbols.SearchFunction.self),
                inspectorPanel: loadSymbol(
                    handle,
                    "engine_read_inspector_panel",
                    as: EngineReadSymbols.InspectorPanelFunction.self
                ),
                localGraph: loadSymbol(handle, "engine_read_local_graph", as: EngineReadSymbols.LocalGraphFunction.self),
                livePreviewMetadata: loadSymbol(
                    handle,
                    "engine_read_live_preview_metadata",
                    as: EngineReadSymbols.LivePreviewMetadataFunction.self
                )
            )
            return LoadedEngineReadSymbols(symbols: symbols, libraryHandle: handle)
        } catch {
            dlclose(handle)
            throw error
        }
    }

    private static func loadSymbol<Function>(
        _ handle: UnsafeMutableRawPointer,
        _ name: String,
        as type: Function.Type
    ) throws -> Function {
        guard let symbol = dlsym(handle, name) else {
            throw EngineReadClientError.missingSymbol(dynamicLoaderError())
        }
        return unsafeBitCast(symbol, to: type)
    }

    private static func dynamicLoaderError() -> String {
        guard let error = dlerror() else {
            return "unknown dynamic loader error"
        }
        return String(cString: error)
    }
}

struct LoadedEngineReadSymbols: @unchecked Sendable {
    let symbols: EngineReadSymbols
    let libraryHandle: UnsafeMutableRawPointer?

    init(symbols: EngineReadSymbols, libraryHandle: UnsafeMutableRawPointer? = nil) {
        self.symbols = symbols
        self.libraryHandle = libraryHandle
    }
}

private extension SearchMode {
    var abiValue: UInt32 {
        switch self {
        case .fileName:
            EngineReadABI.SearchMode.fileName
        case .body:
            EngineReadABI.SearchMode.body
        }
    }
}

private extension LocalGraphDepth {
    var abiValue: UInt32 {
        switch self {
        case .oneHop:
            EngineReadABI.GraphDepth.oneHop
        case .twoHop:
            EngineReadABI.GraphDepth.twoHop
        }
    }
}
