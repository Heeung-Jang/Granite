import Foundation

public struct VaultCreationRequest: Equatable, Sendable {
    public let parentURL: URL
    public let vaultName: String

    public init(parentURL: URL, vaultName: String) {
        self.parentURL = parentURL
        self.vaultName = vaultName
    }
}

public struct VaultCreationOutcome: Equatable, Sendable {
    public let vaultURL: URL
    public let initialNote: FileTreeItem

    public init(vaultURL: URL, initialNote: FileTreeItem) {
        self.vaultURL = vaultURL
        self.initialNote = initialNote
    }
}

public enum VaultCreationError: Error, Equatable, LocalizedError, Sendable {
    case targetAlreadyExists(String)
    case targetEscapesParent
    case initialNoteWriteFailed

    public var errorDescription: String? {
        switch self {
        case .targetAlreadyExists(let name):
            return "\"\(name)\" already exists."
        case .targetEscapesParent:
            return "Vault must be created inside the selected parent folder."
        case .initialNoteWriteFailed:
            return "Failed to create the initial note."
        }
    }
}

public struct VaultCreator {
    public static let initialNoteName = "Untitled.md"

    private let fileManager: FileManager
    private let validator: VaultNameValidator

    public init(
        fileManager: FileManager = .default,
        validator: VaultNameValidator = VaultNameValidator()
    ) {
        self.fileManager = fileManager
        self.validator = validator
    }

    public func createVault(_ request: VaultCreationRequest) throws -> VaultCreationOutcome {
        let name = try validator.validateVaultName(request.vaultName)
        let parentURL = request.parentURL.standardizedFileURL.resolvingSymlinksInPath()
        let targetURL = parentURL
            .appendingPathComponent(name, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        guard isContained(targetURL, in: parentURL) else {
            throw VaultCreationError.targetEscapesParent
        }
        guard !fileManager.fileExists(atPath: targetURL.path) else {
            throw VaultCreationError.targetAlreadyExists(name)
        }

        try fileManager.createDirectory(at: targetURL, withIntermediateDirectories: false)
        do {
            let initialNoteURL = targetURL.appendingPathComponent(Self.initialNoteName, isDirectory: false)
            guard fileManager.createFile(atPath: initialNoteURL.path, contents: Data()) else {
                throw VaultCreationError.initialNoteWriteFailed
            }
        } catch {
            try? fileManager.removeItem(at: targetURL)
            throw error
        }

        return VaultCreationOutcome(
            vaultURL: targetURL,
            initialNote: FileTreeItem(relativePath: Self.initialNoteName)
        )
    }

    private func isContained(_ childURL: URL, in parentURL: URL) -> Bool {
        let childPath = childURL.standardizedFileURL.path
        let parentPath = parentURL.standardizedFileURL.path
        return childPath == parentPath || childPath.hasPrefix("\(parentPath)/")
    }
}
