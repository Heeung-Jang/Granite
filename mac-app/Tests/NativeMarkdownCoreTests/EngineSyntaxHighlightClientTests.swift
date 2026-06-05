import Foundation
import NativeMarkdownFFI
import Testing
@testable import NativeMarkdownCore

@Suite(.serialized)
struct EngineSyntaxHighlightClientTests {
    @Test
    func callsFFIAndDecodesTokens() async throws {
        EngineSyntaxHighlightFakeFFI.reset()
        EngineSyntaxHighlightFakeFFI.highlightData = {
            var builder = ReadTestBufferBuilder(rowKind: EngineReadABI.RowKind.syntaxToken, requestID: 91)
            builder.appendSyntaxToken(kind: 1, startUTF16: 0, lengthUTF16: 2)
            builder.appendSyntaxToken(kind: 2, startUTF16: 18, lengthUTF16: 9)
            return builder.finish(rowStride: 12)
        }
        let client = try EngineSyntaxHighlightClient.load(
            libraryPath: "/tmp/libvault_engine.dylib",
            symbolLoader: { _ in EngineSyntaxHighlightFakeFFI.loadedSymbols() }
        )

        let result = try await client.highlight(
            requestID: 91,
            language: "rust",
            code: #"fn main() { let name = "granite"; }"#,
            visibleStartUTF16: 0,
            visibleLengthUTF16: 0
        )

        #expect(EngineSyntaxHighlightFakeFFI.lastRequestID == 91)
        #expect(EngineSyntaxHighlightFakeFFI.lastLanguage == "rust")
        #expect(EngineSyntaxHighlightFakeFFI.lastCode == #"fn main() { let name = "granite"; }"#)
        #expect(result.tokens.map(\.kind) == [.keyword, .string])
    }

    @Test
    func reportsEngineErrors() async throws {
        EngineSyntaxHighlightFakeFFI.reset()
        EngineSyntaxHighlightFakeFFI.highlightData = {
            var builder = ReadTestBufferBuilder(
                rowKind: EngineReadABI.RowKind.syntaxToken,
                state: EngineReadABI.State.error
            )
            builder.setError(code: "invalid_input", message: "code")
            return builder.finish(rowStride: 0)
        }
        let client = try EngineSyntaxHighlightClient.load(
            libraryPath: "/tmp/libvault_engine.dylib",
            symbolLoader: { _ in EngineSyntaxHighlightFakeFFI.loadedSymbols() }
        )

        await #expect(throws: EngineReadClientError.engine(EngineReadErrorPayload(
            code: "invalid_input",
            message: "code",
            state: EngineReadABI.State.error
        ))) {
            _ = try await client.highlight(
                requestID: 92,
                language: "rust",
                code: "fn main() {}",
                visibleStartUTF16: 0,
                visibleLengthUTF16: 0
            )
        }
    }
}

private enum EngineSyntaxHighlightFakeFFI {
    nonisolated(unsafe) static var highlightData: () -> Data = {
        emptyBuffer(rowKind: EngineReadABI.RowKind.syntaxToken, rowStride: 12)
    }
    nonisolated(unsafe) static var lastRequestID: UInt64 = 0
    nonisolated(unsafe) static var lastLanguage: String?
    nonisolated(unsafe) static var lastCode: String?

    static func reset() {
        highlightData = { emptyBuffer(rowKind: EngineReadABI.RowKind.syntaxToken, rowStride: 12) }
        lastRequestID = 0
        lastLanguage = nil
        lastCode = nil
    }

    static func loadedSymbols() -> LoadedEngineSyntaxHighlightSymbols {
        LoadedEngineSyntaxHighlightSymbols(
            symbols: EngineSyntaxHighlightSymbols(
                highlight: { requestID, language, bytes, len, _, _ in
                    EngineSyntaxHighlightFakeFFI.highlight(requestID, language, bytes, len)
                },
                freeResult: { buffer in
                    EngineSyntaxHighlightFakeFFI.free(buffer)
                }
            )
        )
    }

    static func highlight(
        _ requestID: UInt64,
        _ language: UnsafePointer<CChar>?,
        _ bytes: UnsafePointer<UInt8>?,
        _ len: Int
    ) -> EngineReadResultBuffer {
        lastRequestID = requestID
        lastLanguage = language.map(String.init(cString:))
        if let bytes {
            lastCode = String(decoding: UnsafeBufferPointer(start: bytes, count: len), as: UTF8.self)
        }
        return ffiBuffer(highlightData())
    }

    static func free(_ buffer: EngineReadResultBuffer) {
        buffer.ptr?.deallocate()
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
