import Darwin
import Foundation

public enum EngineHealthState: String, Equatable {
    case loaded
    case missingLibrary
    case missingSymbol
    case abiMismatch
    case callFailed
}

public struct EngineHealthStatus: Equatable {
    public let state: EngineHealthState
    public let abiVersion: UInt32?
    public let message: String

    public init(state: EngineHealthState, abiVersion: UInt32?, message: String) {
        self.state = state
        self.abiVersion = abiVersion
        self.message = message
    }

    public var displayText: String {
        switch state {
        case .loaded:
            return "Engine OK"
        case .missingLibrary:
            return "Engine Missing"
        case .missingSymbol:
            return "Engine Symbol Missing"
        case .abiMismatch:
            return "Engine ABI Mismatch"
        case .callFailed:
            return "Engine Call Failed"
        }
    }

    public static func evaluate(
        abiVersion: UInt32,
        expectedAbiVersion: UInt32,
        message: String
    ) -> EngineHealthStatus {
        if abiVersion != expectedAbiVersion {
            return EngineHealthStatus(
                state: .abiMismatch,
                abiVersion: abiVersion,
                message: "expected \(expectedAbiVersion), got \(abiVersion)"
            )
        }

        return EngineHealthStatus(
            state: .loaded,
            abiVersion: abiVersion,
            message: message
        )
    }
}

public protocol EngineHealthLoading {
    func load() -> EngineHealthStatus
}

public struct EngineHealthClient: EngineHealthLoading {
    public typealias AbiFunction = @convention(c) () -> UInt32
    public typealias HealthFunction = @convention(c) () -> UnsafeMutablePointer<CChar>?
    public typealias FreeFunction = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void

    private let libraryPath: String?
    private let expectedAbiVersion: UInt32

    public init(
        libraryPath: String? = ProcessInfo.processInfo.environment["VAULT_ENGINE_DYLIB_PATH"],
        expectedAbiVersion: UInt32 = 1
    ) {
        self.libraryPath = libraryPath
        self.expectedAbiVersion = expectedAbiVersion
    }

    public func load() -> EngineHealthStatus {
        guard let libraryPath, !libraryPath.isEmpty else {
            return EngineHealthStatus(
                state: .missingLibrary,
                abiVersion: nil,
                message: "VAULT_ENGINE_DYLIB_PATH is not set"
            )
        }

        guard let handle = dlopen(libraryPath, RTLD_NOW | RTLD_LOCAL) else {
            return EngineHealthStatus(
                state: .missingLibrary,
                abiVersion: nil,
                message: dynamicLoaderError()
            )
        }
        defer {
            dlclose(handle)
        }

        guard let abiSymbol = dlsym(handle, "engine_abi_version"),
              let healthSymbol = dlsym(handle, "engine_health_check"),
              let freeSymbol = dlsym(handle, "engine_string_free")
        else {
            return EngineHealthStatus(
                state: .missingSymbol,
                abiVersion: nil,
                message: dynamicLoaderError()
            )
        }

        let abiFunction = unsafeBitCast(abiSymbol, to: AbiFunction.self)
        let healthFunction = unsafeBitCast(healthSymbol, to: HealthFunction.self)
        let freeFunction = unsafeBitCast(freeSymbol, to: FreeFunction.self)
        let abiVersion = abiFunction()

        guard let messagePointer = healthFunction() else {
            return EngineHealthStatus(
                state: .callFailed,
                abiVersion: abiVersion,
                message: "engine_health_check returned null"
            )
        }
        defer {
            freeFunction(messagePointer)
        }

        let message = String(cString: messagePointer)
        return EngineHealthStatus.evaluate(
            abiVersion: abiVersion,
            expectedAbiVersion: expectedAbiVersion,
            message: message
        )
    }

    private func dynamicLoaderError() -> String {
        guard let error = dlerror() else {
            return "unknown dynamic loader error"
        }
        return String(cString: error)
    }
}

