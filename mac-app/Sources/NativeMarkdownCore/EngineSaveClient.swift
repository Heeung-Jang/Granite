import Darwin
import Foundation

public struct EngineFileIdentity: Codable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
}

public struct EngineSystemTime: Codable, Equatable, Sendable {
    public let secsSinceUnixEpoch: UInt64
    public let nanos: UInt32

    enum CodingKeys: String, CodingKey {
        case secsSinceUnixEpoch = "secs_since_unix_epoch"
        case nanos
    }
}

public struct EngineSaveBaseline: Codable, Equatable, Sendable {
    public let relativePath: String
    public let fileIdentity: EngineFileIdentity
    public let sizeBytes: UInt64
    public let modified: EngineSystemTime?
    public let contentHash: String

    enum CodingKeys: String, CodingKey {
        case relativePath = "relative_path"
        case fileIdentity = "file_identity"
        case sizeBytes = "size_bytes"
        case modified
        case contentHash = "content_hash"
    }
}

public struct EngineSaveOutcome: Codable, Equatable, Sendable {
    public let baseline: EngineSaveBaseline
    public let bytesWritten: UInt64

    enum CodingKeys: String, CodingKey {
        case baseline
        case bytesWritten = "bytes_written"
    }
}

public struct EngineQueuedSaveItem: Codable, Equatable, Sendable {
    public let relativePath: String
    public let generation: UInt64
    public let reason: String
    public let status: String

    enum CodingKeys: String, CodingKey {
        case relativePath = "relative_path"
        case generation
        case reason
        case status
    }
}

public struct EngineSaveReloadOutcome: Codable, Equatable, Sendable {
    public let baseline: EngineSaveBaseline
    public let contents: String
    public let queuedItem: EngineQueuedSaveItem
    public let dirty: Bool

    enum CodingKeys: String, CodingKey {
        case baseline
        case contents
        case queuedItem = "queued_item"
        case dirty
    }
}

public struct EngineSaveChoiceOutcome: Codable, Equatable, Sendable {
    public let choice: String
    public let baseline: EngineSaveBaseline
    public let bytesWritten: UInt64
    public let queuedItem: EngineQueuedSaveItem
    public let dirty: Bool

    enum CodingKeys: String, CodingKey {
        case choice
        case baseline
        case bytesWritten = "bytes_written"
        case queuedItem = "queued_item"
        case dirty
    }
}

public struct EngineSaveConflictSnapshot: Codable, Equatable, Sendable {
    public let fileIdentity: EngineFileIdentity
    public let sizeBytes: UInt64
    public let modified: EngineSystemTime?
    public let contentHash: String

    enum CodingKeys: String, CodingKey {
        case fileIdentity = "file_identity"
        case sizeBytes = "size_bytes"
        case modified
        case contentHash = "content_hash"
    }
}

public struct EngineSaveConflict: Codable, Equatable, Sendable {
    public let relativePath: String
    public let kind: String
    public let expected: EngineSaveBaseline
    public let actual: EngineSaveConflictSnapshot?

    enum CodingKeys: String, CodingKey {
        case relativePath = "relative_path"
        case kind
        case expected
        case actual
    }
}

public struct EngineSaveErrorPayload: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let conflictKind: String?
    public let conflict: EngineSaveConflict?

    public init(
        code: String,
        message: String,
        conflictKind: String?,
        conflict: EngineSaveConflict? = nil
    ) {
        self.code = code
        self.message = message
        self.conflictKind = conflictKind
        self.conflict = conflict
    }

    enum CodingKeys: String, CodingKey {
        case code
        case message
        case conflictKind = "conflict_kind"
        case conflict
    }
}

public struct EngineSaveEnvelope<Value: Codable>: Codable, Equatable where Value: Equatable {
    public let ok: Bool
    public let value: Value?
    public let error: EngineSaveErrorPayload?
}

public enum EngineSaveClientError: Error, Equatable {
    case missingLibrary(String)
    case missingSymbol(String)
    case callFailed(String)
    case invalidResponse(String)
    case engine(EngineSaveErrorPayload)
}

public protocol EngineNoteSaving: Sendable {
    func captureBaseline(vaultURL: URL, file: FileTreeItem) throws -> EngineSaveBaseline
    func save(vaultURL: URL, baseline: EngineSaveBaseline, contents: String) throws -> EngineSaveOutcome
    func reloadAfterConflict(
        vaultURL: URL,
        queueURL: URL,
        conflict: EngineSaveConflict,
        generation: UInt64
    ) throws -> EngineSaveReloadOutcome
    func keepConflictAsNewNote(
        vaultURL: URL,
        queueURL: URL,
        newRelativePath: String,
        contents: String,
        generation: UInt64
    ) throws -> EngineSaveChoiceOutcome
    func overwriteAfterConflict(
        vaultURL: URL,
        queueURL: URL,
        conflict: EngineSaveConflict,
        contents: String,
        generation: UInt64
    ) throws -> EngineSaveChoiceOutcome
}

public struct EngineSaveClient: EngineNoteSaving {
    public typealias CaptureBaselineFunction = @convention(c) (
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?
    ) -> UnsafeMutablePointer<CChar>?
    public typealias SaveFunction = @convention(c) (
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        UnsafePointer<UInt8>?,
        Int
    ) -> UnsafeMutablePointer<CChar>?
    public typealias ReloadAfterConflictFunction = @convention(c) (
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        UInt64
    ) -> UnsafeMutablePointer<CChar>?
    public typealias KeepConflictAsNewNoteFunction = @convention(c) (
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        UnsafePointer<UInt8>?,
        Int,
        UInt64
    ) -> UnsafeMutablePointer<CChar>?
    public typealias OverwriteAfterConflictFunction = @convention(c) (
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        UnsafePointer<UInt8>?,
        Int,
        UInt64
    ) -> UnsafeMutablePointer<CChar>?
    public typealias FreeFunction = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void

    private let libraryPath: String?

    public init(libraryPath: String? = ProcessInfo.processInfo.environment["VAULT_ENGINE_DYLIB_PATH"]) {
        self.libraryPath = libraryPath
    }

    public func captureBaseline(vaultURL: URL, file: FileTreeItem) throws -> EngineSaveBaseline {
        try withSymbols { symbols in
            let response = try vaultURL.path.withCString { vaultPath in
                try file.relativePath.withCString { relativePath in
                    try stringResponse(
                        symbols.captureBaseline(vaultPath, relativePath),
                        free: symbols.free
                    )
                }
            }
            return try Self.decodeEnvelope(response, as: EngineSaveBaseline.self)
        }
    }

    public func save(
        vaultURL: URL,
        baseline: EngineSaveBaseline,
        contents: String
    ) throws -> EngineSaveOutcome {
        let baselineJSON = String(data: try JSONEncoder().encode(baseline), encoding: .utf8) ?? ""
        let contentsData = Data(contents.utf8)

        return try withSymbols { symbols in
            let response = try vaultURL.path.withCString { vaultPath in
                try baselineJSON.withCString { baselinePointer in
                    try contentsData.withUnsafeBytes { rawBuffer in
                        let buffer = rawBuffer.bindMemory(to: UInt8.self)
                        return try stringResponse(
                            symbols.save(
                                vaultPath,
                                baselinePointer,
                                buffer.baseAddress,
                                buffer.count
                            ),
                            free: symbols.free
                        )
                    }
                }
            }
            return try Self.decodeEnvelope(response, as: EngineSaveOutcome.self)
        }
    }

    public func reloadAfterConflict(
        vaultURL: URL,
        queueURL: URL,
        conflict: EngineSaveConflict,
        generation: UInt64
    ) throws -> EngineSaveReloadOutcome {
        let conflictJSON = try Self.encodedJSONString(conflict)
        return try withConflictSymbols { symbols in
            let response = try vaultURL.path.withCString { vaultPath in
                try queueURL.path.withCString { queuePath in
                    try conflictJSON.withCString { conflictPointer in
                        try stringResponse(
                            symbols.reloadAfterConflict(
                                vaultPath,
                                queuePath,
                                conflictPointer,
                                generation
                            ),
                            free: symbols.free
                        )
                    }
                }
            }
            return try Self.decodeEnvelope(response, as: EngineSaveReloadOutcome.self)
        }
    }

    public func keepConflictAsNewNote(
        vaultURL: URL,
        queueURL: URL,
        newRelativePath: String,
        contents: String,
        generation: UInt64
    ) throws -> EngineSaveChoiceOutcome {
        let contentsData = Data(contents.utf8)
        return try withConflictSymbols { symbols in
            let response = try vaultURL.path.withCString { vaultPath in
                try queueURL.path.withCString { queuePath in
                    try newRelativePath.withCString { newRelativePathPointer in
                        try contentsData.withUnsafeBytes { rawBuffer in
                            let buffer = rawBuffer.bindMemory(to: UInt8.self)
                            return try stringResponse(
                                symbols.keepConflictAsNewNote(
                                    vaultPath,
                                    queuePath,
                                    newRelativePathPointer,
                                    buffer.baseAddress,
                                    buffer.count,
                                    generation
                                ),
                                free: symbols.free
                            )
                        }
                    }
                }
            }
            return try Self.decodeEnvelope(response, as: EngineSaveChoiceOutcome.self)
        }
    }

    public func overwriteAfterConflict(
        vaultURL: URL,
        queueURL: URL,
        conflict: EngineSaveConflict,
        contents: String,
        generation: UInt64
    ) throws -> EngineSaveChoiceOutcome {
        let conflictJSON = try Self.encodedJSONString(conflict)
        let contentsData = Data(contents.utf8)
        return try withConflictSymbols { symbols in
            let response = try vaultURL.path.withCString { vaultPath in
                try queueURL.path.withCString { queuePath in
                    try conflictJSON.withCString { conflictPointer in
                        try contentsData.withUnsafeBytes { rawBuffer in
                            let buffer = rawBuffer.bindMemory(to: UInt8.self)
                            return try stringResponse(
                                symbols.overwriteAfterConflict(
                                    vaultPath,
                                    queuePath,
                                    conflictPointer,
                                    buffer.baseAddress,
                                    buffer.count,
                                    generation
                                ),
                                free: symbols.free
                            )
                        }
                    }
                }
            }
            return try Self.decodeEnvelope(response, as: EngineSaveChoiceOutcome.self)
        }
    }

    public static func decodeEnvelope<Value: Codable & Equatable>(
        _ json: String,
        as type: Value.Type
    ) throws -> Value {
        guard let data = json.data(using: .utf8) else {
            throw EngineSaveClientError.invalidResponse("response is not UTF-8")
        }
        let envelope: EngineSaveEnvelope<Value>
        do {
            envelope = try JSONDecoder().decode(EngineSaveEnvelope<Value>.self, from: data)
        } catch {
            throw EngineSaveClientError.invalidResponse(error.localizedDescription)
        }

        if envelope.ok, let value = envelope.value {
            return value
        }
        throw EngineSaveClientError.engine(
            envelope.error ?? EngineSaveErrorPayload(
                code: "missing_error",
                message: "save response did not include an error payload",
                conflictKind: nil
            )
        )
    }

    private static func encodedJSONString<Value: Encodable>(_ value: Value) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let json = String(data: data, encoding: .utf8) else {
            throw EngineSaveClientError.invalidResponse("encoded JSON is not UTF-8")
        }
        return json
    }

    private func withSymbols<T>(_ body: (SaveSymbols) throws -> T) throws -> T {
        guard let libraryPath, !libraryPath.isEmpty else {
            throw EngineSaveClientError.missingLibrary("VAULT_ENGINE_DYLIB_PATH is not set")
        }
        guard let handle = dlopen(libraryPath, RTLD_NOW | RTLD_LOCAL) else {
            throw EngineSaveClientError.missingLibrary(dynamicLoaderError())
        }
        defer {
            dlclose(handle)
        }

        guard let captureSymbol = dlsym(handle, "engine_save_capture_baseline"),
              let saveSymbol = dlsym(handle, "engine_save_write"),
              let freeSymbol = dlsym(handle, "engine_string_free")
        else {
            throw EngineSaveClientError.missingSymbol(dynamicLoaderError())
        }

        return try body(
            SaveSymbols(
                captureBaseline: unsafeBitCast(captureSymbol, to: CaptureBaselineFunction.self),
                save: unsafeBitCast(saveSymbol, to: SaveFunction.self),
                free: unsafeBitCast(freeSymbol, to: FreeFunction.self)
            )
        )
    }

    private func withConflictSymbols<T>(_ body: (ConflictSaveSymbols) throws -> T) throws -> T {
        guard let libraryPath, !libraryPath.isEmpty else {
            throw EngineSaveClientError.missingLibrary("VAULT_ENGINE_DYLIB_PATH is not set")
        }
        guard let handle = dlopen(libraryPath, RTLD_NOW | RTLD_LOCAL) else {
            throw EngineSaveClientError.missingLibrary(dynamicLoaderError())
        }
        defer {
            dlclose(handle)
        }

        guard let reloadSymbol = dlsym(handle, "engine_save_reload_after_conflict"),
              let keepSymbol = dlsym(handle, "engine_save_keep_conflict_as_new_note"),
              let overwriteSymbol = dlsym(handle, "engine_save_overwrite_after_conflict"),
              let freeSymbol = dlsym(handle, "engine_string_free")
        else {
            throw EngineSaveClientError.missingSymbol(dynamicLoaderError())
        }

        return try body(
            ConflictSaveSymbols(
                reloadAfterConflict: unsafeBitCast(
                    reloadSymbol,
                    to: ReloadAfterConflictFunction.self
                ),
                keepConflictAsNewNote: unsafeBitCast(
                    keepSymbol,
                    to: KeepConflictAsNewNoteFunction.self
                ),
                overwriteAfterConflict: unsafeBitCast(
                    overwriteSymbol,
                    to: OverwriteAfterConflictFunction.self
                ),
                free: unsafeBitCast(freeSymbol, to: FreeFunction.self)
            )
        )
    }

    private func stringResponse(
        _ pointer: UnsafeMutablePointer<CChar>?,
        free: FreeFunction
    ) throws -> String {
        guard let pointer else {
            throw EngineSaveClientError.callFailed("save FFI returned null")
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

    private struct SaveSymbols {
        let captureBaseline: CaptureBaselineFunction
        let save: SaveFunction
        let free: FreeFunction
    }

    private struct ConflictSaveSymbols {
        let reloadAfterConflict: ReloadAfterConflictFunction
        let keepConflictAsNewNote: KeepConflictAsNewNoteFunction
        let overwriteAfterConflict: OverwriteAfterConflictFunction
        let free: FreeFunction
    }
}
