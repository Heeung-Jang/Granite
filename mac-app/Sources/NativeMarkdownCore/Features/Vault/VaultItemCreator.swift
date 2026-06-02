import Foundation

public enum VaultItemCreationError: Error, Equatable, LocalizedError, Sendable {
    case targetEscapesVault
    case parentMissing(String)
    case targetAlreadyExists(String)

    public var errorDescription: String? {
        switch self {
        case .targetEscapesVault:
            return "Item must be created inside the current vault."
        case .parentMissing:
            return "The target folder is no longer available."
        case .targetAlreadyExists(let name):
            return "\"\(name)\" already exists."
        }
    }
}

public struct VaultItemCreator {
    private let fileManager: FileManager
    private let validator: VaultNameValidator

    public init(
        fileManager: FileManager = .default,
        validator: VaultNameValidator = VaultNameValidator()
    ) {
        self.fileManager = fileManager
        self.validator = validator
    }

    public func createNote(
        vaultURL: URL,
        parentFolderPath: String,
        name: String
    ) throws -> FileTreeItem {
        let noteName = try validator.validateNoteName(name)
        let parentURL = try resolvedParentURL(vaultURL: vaultURL, parentFolderPath: parentFolderPath)
        let targetURL = parentURL.appendingPathComponent(noteName, isDirectory: false).standardizedFileURL
        try ensureContained(targetURL, in: vaultURL)
        guard !fileManager.fileExists(atPath: targetURL.path) else {
            throw VaultItemCreationError.targetAlreadyExists(noteName)
        }
        guard fileManager.createFile(atPath: targetURL.path, contents: Data()) else {
            throw VaultItemCreationError.targetAlreadyExists(noteName)
        }
        return FileTreeItem(relativePath: relativePath(parentFolderPath: parentFolderPath, name: noteName))
    }

    public func createFolder(
        vaultURL: URL,
        parentFolderPath: String,
        name: String
    ) throws -> String {
        let folderName = try validator.validateFolderName(name)
        let parentURL = try resolvedParentURL(vaultURL: vaultURL, parentFolderPath: parentFolderPath)
        let targetURL = parentURL.appendingPathComponent(folderName, isDirectory: true).standardizedFileURL
        try ensureContained(targetURL, in: vaultURL)
        guard !fileManager.fileExists(atPath: targetURL.path) else {
            throw VaultItemCreationError.targetAlreadyExists(folderName)
        }
        try fileManager.createDirectory(at: targetURL, withIntermediateDirectories: false)
        return relativePath(parentFolderPath: parentFolderPath, name: folderName)
    }

    private func resolvedParentURL(vaultURL: URL, parentFolderPath: String) throws -> URL {
        let rootURL = vaultURL.standardizedFileURL.resolvingSymlinksInPath()
        let parentURL = parentFolderPath.isEmpty
            ? rootURL
            : rootURL.appendingPathComponent(parentFolderPath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        try ensureContained(parentURL, in: rootURL)

        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: parentURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw VaultItemCreationError.parentMissing(parentFolderPath)
        }
        return parentURL
    }

    private func ensureContained(_ childURL: URL, in vaultURL: URL) throws {
        let rootURL = vaultURL.standardizedFileURL.resolvingSymlinksInPath()
        let childPath = childURL.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = rootURL.path
        guard childPath == rootPath || childPath.hasPrefix("\(rootPath)/") else {
            throw VaultItemCreationError.targetEscapesVault
        }
    }

    private func relativePath(parentFolderPath: String, name: String) -> String {
        parentFolderPath.isEmpty ? name : "\(parentFolderPath)/\(name)"
    }
}
