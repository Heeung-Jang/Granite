import Darwin
import Foundation

public struct EngineGraphErrorPayload: Codable, Equatable, Sendable {
    public let code: String
    public let message: String

    enum CodingKeys: String, CodingKey {
        case code
        case message
    }
}

public struct EngineGraphEnvelope<Value: Codable>: Codable where Value: Equatable {
    public let ok: Bool
    public let value: Value?
    public let error: EngineGraphErrorPayload?
}

public enum EngineGraphClientError: Error, Equatable, CustomStringConvertible {
    case missingLibrary(String)
    case missingSymbol(String)
    case callFailed(String)
    case invalidResponse(String)
    case engine(EngineGraphErrorPayload)
    case staleResponse(requestID: UInt64, latestRequestID: UInt64)

    public var description: String {
        switch self {
        case .missingLibrary:
            "graph engine library is unavailable"
        case .missingSymbol:
            "graph engine symbol is unavailable"
        case .callFailed:
            "graph engine call failed"
        case .invalidResponse:
            "graph engine response is invalid"
        case .engine(let payload):
            "graph engine error: \(payload.code)"
        case .staleResponse:
            "stale graph response"
        }
    }
}

public protocol EngineGraphTransport: Sendable {
    func snapshot(metadataPath: String, requestJSON: String) async throws -> String
}

public actor EngineGraphClient {
    private let transport: any EngineGraphTransport
    private var latestRequestID: UInt64 = 0

    public init() {
        self.init(libraryPath: EngineLibraryPath.defaultPath())
    }

    public init(libraryPath: String?) {
        transport = DynamicEngineGraphTransport(libraryPath: libraryPath)
    }

    public init(transport: any EngineGraphTransport) {
        self.transport = transport
    }

    public func loadSnapshot(
        metadataURL: URL,
        request: WholeVaultGraphRequest
    ) async throws -> WholeVaultGraphPayload {
        try Task.checkCancellation()
        latestRequestID = request.requestID

        let requestJSON = try Self.encodedJSONString(request)
        let response = try await transport.snapshot(
            metadataPath: metadataURL.path,
            requestJSON: requestJSON
        )
        try Task.checkCancellation()

        let payload = try Self.decodeEnvelope(
            response,
            expectedRequestID: request.requestID,
            expectedGeneration: request.generation,
            byteCapBytes: request.byteCapBytes
        )
        try Task.checkCancellation()

        guard payload.requestID == latestRequestID else {
            throw EngineGraphClientError.staleResponse(
                requestID: payload.requestID,
                latestRequestID: latestRequestID
            )
        }
        return payload
    }

    public static func decodeEnvelope(
        _ json: String,
        expectedRequestID: UInt64? = nil,
        expectedGeneration: UInt64? = nil,
        byteCapBytes: Int = WholeVaultGraphRequest.defaultByteCapBytes
    ) throws -> WholeVaultGraphPayload {
        guard let data = json.data(using: .utf8) else {
            throw EngineGraphClientError.invalidResponse("response is not UTF-8")
        }
        guard data.count <= byteCapBytes else {
            throw WholeVaultGraphValidationError.payloadTooLarge
        }

        let envelope: EngineGraphEnvelope<WholeVaultGraphPayload>
        do {
            envelope = try JSONDecoder().decode(
                EngineGraphEnvelope<WholeVaultGraphPayload>.self,
                from: data
            )
        } catch {
            throw EngineGraphClientError.invalidResponse(error.localizedDescription)
        }

        if envelope.ok, let value = envelope.value {
            try WholeVaultGraphPayloadValidator.validate(
                value,
                expectedRequestID: expectedRequestID,
                expectedGeneration: expectedGeneration
            )
            return value
        }
        throw EngineGraphClientError.engine(
            envelope.error ?? EngineGraphErrorPayload(
                code: "missing_error",
                message: "graph response did not include an error payload"
            )
        )
    }

    private static func encodedJSONString<Value: Encodable>(_ value: Value) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let json = String(data: data, encoding: .utf8) else {
            throw EngineGraphClientError.invalidResponse("encoded JSON is not UTF-8")
        }
        return json
    }
}

public struct DynamicEngineGraphTransport: EngineGraphTransport {
    public typealias SnapshotFunction = @convention(c) (
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?
    ) -> UnsafeMutablePointer<CChar>?
    public typealias FreeFunction = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void

    private let libraryPath: String?

    public init() {
        self.init(libraryPath: EngineLibraryPath.defaultPath())
    }

    public init(libraryPath: String?) {
        self.libraryPath = libraryPath
    }

    public func snapshot(metadataPath: String, requestJSON: String) async throws -> String {
        guard let libraryPath, !libraryPath.isEmpty else {
            throw EngineGraphClientError.missingLibrary(EngineLibraryPath.missingMessage)
        }
        guard let handle = dlopen(libraryPath, RTLD_NOW | RTLD_LOCAL) else {
            throw EngineGraphClientError.missingLibrary(dynamicLoaderError())
        }
        defer {
            dlclose(handle)
        }

        guard let snapshotSymbol = dlsym(handle, "engine_graph_snapshot"),
              let freeSymbol = dlsym(handle, "engine_string_free")
        else {
            throw EngineGraphClientError.missingSymbol(dynamicLoaderError())
        }

        let snapshot = unsafeBitCast(snapshotSymbol, to: SnapshotFunction.self)
        let free = unsafeBitCast(freeSymbol, to: FreeFunction.self)
        return try metadataPath.withCString { metadataPointer in
            try requestJSON.withCString { requestPointer in
                try stringResponse(
                    snapshot(metadataPointer, requestPointer),
                    free: free
                )
            }
        }
    }

    private func stringResponse(
        _ pointer: UnsafeMutablePointer<CChar>?,
        free: FreeFunction
    ) throws -> String {
        guard let pointer else {
            throw EngineGraphClientError.callFailed("graph FFI returned null")
        }
        defer {
            free(pointer)
        }
        return String(cString: pointer)
    }

    private func dynamicLoaderError() -> String {
        guard let error = dlerror() else {
            return "unknown dynamic loader error"
        }
        return String(cString: error)
    }
}
