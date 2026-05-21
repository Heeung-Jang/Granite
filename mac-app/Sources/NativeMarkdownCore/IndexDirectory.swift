import Foundation

public struct IndexConfiguration: Equatable {
    public static let defaultSchemaVersion = "metadata-v1"
    public static let defaultBackendVersion = "sqlite+tantivy"
    public static let defaultTokenizerConfig = "tantivy"

    public let schemaVersion: String
    public let backendVersion: String
    public let tokenizerConfig: String

    public init(
        schemaVersion: String = Self.defaultSchemaVersion,
        backendVersion: String = Self.defaultBackendVersion,
        tokenizerConfig: String = Self.defaultTokenizerConfig
    ) {
        self.schemaVersion = schemaVersion
        self.backendVersion = backendVersion
        self.tokenizerConfig = tokenizerConfig
    }
}

public struct AppOwnedIndexLocation: Equatable {
    public let vaultIdentityHash: String
    public let rootDirectory: URL
    public let dataDirectory: URL
    public let metadataStoreFile: URL
    public let tantivyIndexDirectory: URL
    public let indexingQueueFile: URL
    public let lockFile: URL
    public let rebuildDirectory: URL
    public let configuration: IndexConfiguration
}

public protocol IndexDirectoryResolving {
    func prepareIndexLocation(forVaultAt vaultURL: URL) throws -> AppOwnedIndexLocation
}

public enum IndexDirectoryError: Error, Equatable {
    case applicationSupportInsideVault(applicationSupportRoot: URL, vaultURL: URL)
}

public struct AppOwnedIndexDirectoryResolver: IndexDirectoryResolving {
    private let fileManager: FileManager
    private let applicationSupportRoot: URL
    private let configuration: IndexConfiguration

    public init(
        fileManager: FileManager = .default,
        applicationSupportRoot: URL? = nil,
        configuration: IndexConfiguration = IndexConfiguration()
    ) {
        self.fileManager = fileManager
        self.applicationSupportRoot = applicationSupportRoot ?? Self.defaultApplicationSupportRoot()
        self.configuration = configuration
    }

    public func prepareIndexLocation(forVaultAt vaultURL: URL) throws -> AppOwnedIndexLocation {
        try validateApplicationSupportRootOutsideVault(vaultURL)

        let identityHash = vaultIdentityHash(for: vaultURL)
        let rootDirectory = applicationSupportRoot
            .appendingPathComponent("Indexes", isDirectory: true)
            .appendingPathComponent(identityHash, isDirectory: true)
            .appendingPathComponent(safePathComponent(configuration.schemaVersion), isDirectory: true)
            .appendingPathComponent(safePathComponent(configuration.backendVersion), isDirectory: true)
            .appendingPathComponent(safePathComponent(configuration.tokenizerConfig), isDirectory: true)
        let dataDirectory = rootDirectory.appendingPathComponent("data", isDirectory: true)
        let rebuildDirectory = rootDirectory.appendingPathComponent("rebuild", isDirectory: true)
        let metadataStoreFile = dataDirectory.appendingPathComponent(
            "metadata.sqlite",
            isDirectory: false
        )
        let tantivyIndexDirectory = dataDirectory.appendingPathComponent(
            "tantivy",
            isDirectory: true
        )
        let indexingQueueFile = dataDirectory.appendingPathComponent(
            "indexing-queue.sqlite",
            isDirectory: false
        )
        let lockFile = rootDirectory.appendingPathComponent("index.lock", isDirectory: false)

        try fileManager.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: rebuildDirectory, withIntermediateDirectories: true)

        return AppOwnedIndexLocation(
            vaultIdentityHash: identityHash,
            rootDirectory: rootDirectory,
            dataDirectory: dataDirectory,
            metadataStoreFile: metadataStoreFile,
            tantivyIndexDirectory: tantivyIndexDirectory,
            indexingQueueFile: indexingQueueFile,
            lockFile: lockFile,
            rebuildDirectory: rebuildDirectory,
            configuration: configuration
        )
    }

    private func validateApplicationSupportRootOutsideVault(_ vaultURL: URL) throws {
        let vaultPath = canonicalDirectoryPath(vaultURL)
        let supportPath = canonicalDirectoryPath(applicationSupportRoot)

        if supportPath == vaultPath || supportPath.hasPrefix("\(vaultPath)/") {
            throw IndexDirectoryError.applicationSupportInsideVault(
                applicationSupportRoot: applicationSupportRoot,
                vaultURL: vaultURL
            )
        }
    }

    private static func defaultApplicationSupportRoot() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory

        return base.appendingPathComponent("NativeMarkdownMacApp", isDirectory: true)
    }

    private func vaultIdentityHash(for vaultURL: URL) -> String {
        stableHash(canonicalDirectoryPath(vaultURL))
    }

    private func canonicalDirectoryPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if path.count > 1, path.hasSuffix("/") {
            return String(path.dropLast())
        }
        return path
    }

    private func safePathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let component = String(scalars)
        return component.isEmpty ? "default" : component
    }

    private func stableHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
