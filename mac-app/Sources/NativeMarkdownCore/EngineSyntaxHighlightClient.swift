import Darwin
import Foundation
import NativeMarkdownFFI

public protocol EngineSyntaxHighlighting: Sendable {
    func highlight(
        requestID: UInt64,
        language: String?,
        code: String,
        visibleStartUTF16: UInt32,
        visibleLengthUTF16: UInt32
    ) async throws -> EngineSyntaxHighlightResult
}

struct EngineSyntaxHighlightSymbols: @unchecked Sendable {
    typealias HighlightFunction = @convention(c) (
        UInt64,
        UnsafePointer<CChar>?,
        UnsafePointer<UInt8>?,
        Int,
        UInt32,
        UInt32
    ) -> EngineReadResultBuffer
    typealias FreeResultFunction = @convention(c) (EngineReadResultBuffer) -> Void

    let highlight: HighlightFunction
    let freeResult: FreeResultFunction
}

public final class EngineSyntaxHighlightClient: EngineSyntaxHighlighting, @unchecked Sendable {
    typealias SymbolLoader = @Sendable (String?) throws -> LoadedEngineSyntaxHighlightSymbols

    private let queue = DispatchQueue(label: "NativeMarkdown.EngineSyntaxHighlightClient")
    private let symbols: EngineSyntaxHighlightSymbols
    private var libraryHandle: UnsafeMutableRawPointer?

    public static func loadDefault() throws -> EngineSyntaxHighlightClient {
        try load(libraryPath: EngineLibraryPath.defaultPath())
    }

    public static func load(libraryPath: String?) throws -> EngineSyntaxHighlightClient {
        try load(libraryPath: libraryPath, symbolLoader: EngineSyntaxHighlightClient.loadSymbols)
    }

    static func load(
        libraryPath: String?,
        symbolLoader: SymbolLoader
    ) throws -> EngineSyntaxHighlightClient {
        let loaded = try symbolLoader(libraryPath)
        return EngineSyntaxHighlightClient(
            symbols: loaded.symbols,
            libraryHandle: loaded.libraryHandle
        )
    }

    init(
        symbols: EngineSyntaxHighlightSymbols,
        libraryHandle: UnsafeMutableRawPointer? = nil
    ) {
        self.symbols = symbols
        self.libraryHandle = libraryHandle
    }

    deinit {
        if let libraryHandle {
            dlclose(libraryHandle)
        }
    }

    public func highlight(
        requestID: UInt64,
        language: String?,
        code: String,
        visibleStartUTF16: UInt32,
        visibleLengthUTF16: UInt32
    ) async throws -> EngineSyntaxHighlightResult {
        let bytes = Data(code.utf8)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let result = try language.withOptionalCString { languagePointer in
                        try bytes.withUnsafeBytes { rawBuffer in
                            let byteBuffer = rawBuffer.bindMemory(to: UInt8.self)
                            let buffer = self.symbols.highlight(
                                requestID,
                                languagePointer,
                                byteBuffer.baseAddress,
                                byteBuffer.count,
                                visibleStartUTF16,
                                visibleLengthUTF16
                            )
                            let data = try Self.data(from: buffer, free: self.symbols.freeResult)
                            return try Self.decode(data)
                        }
                    }
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func decode(_ data: Data) throws -> EngineSyntaxHighlightResult {
        if let error = try errorPayload(from: data) {
            throw EngineReadClientError.engine(error)
        }
        do {
            return try EngineReadBufferDecoder.decodeSyntaxHighlight(data)
        } catch let error as EngineReadDecodeError {
            throw EngineReadClientError.decode(error)
        }
    }

    private static func data(
        from buffer: EngineReadResultBuffer,
        free: EngineSyntaxHighlightSymbols.FreeResultFunction
    ) throws -> Data {
        guard let pointer = buffer.ptr, buffer.len > 0 else {
            throw EngineReadClientError.callFailed("syntax FFI returned empty buffer")
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

    private static func loadSymbols(libraryPath: String?) throws -> LoadedEngineSyntaxHighlightSymbols {
        guard let libraryPath, !libraryPath.isEmpty else {
            throw EngineReadClientError.missingLibrary(EngineLibraryPath.missingMessage)
        }
        guard let handle = dlopen(libraryPath, RTLD_NOW | RTLD_LOCAL) else {
            throw EngineReadClientError.missingLibrary(dynamicLoaderError())
        }

        do {
            let symbols = EngineSyntaxHighlightSymbols(
                highlight: try loadSymbol(
                    handle,
                    "engine_live_preview_highlight_code",
                    as: EngineSyntaxHighlightSymbols.HighlightFunction.self
                ),
                freeResult: try loadSymbol(
                    handle,
                    "engine_read_result_free",
                    as: EngineSyntaxHighlightSymbols.FreeResultFunction.self
                )
            )
            return LoadedEngineSyntaxHighlightSymbols(symbols: symbols, libraryHandle: handle)
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

struct LoadedEngineSyntaxHighlightSymbols: @unchecked Sendable {
    let symbols: EngineSyntaxHighlightSymbols
    let libraryHandle: UnsafeMutableRawPointer?

    init(symbols: EngineSyntaxHighlightSymbols, libraryHandle: UnsafeMutableRawPointer? = nil) {
        self.symbols = symbols
        self.libraryHandle = libraryHandle
    }
}

private extension Optional where Wrapped == String {
    func withOptionalCString<T>(_ body: (UnsafePointer<CChar>?) throws -> T) rethrows -> T {
        switch self {
        case .none:
            try body(nil)
        case .some(let value):
            try value.withCString(body)
        }
    }
}
