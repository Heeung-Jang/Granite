import Foundation

public enum VaultItemOperationTarget: Equatable, Sendable {
    case file(FileTreeItem)
    case folder(String)

    public var relativePath: String {
        switch self {
        case .file(let file):
            return file.relativePath
        case .folder(let path):
            return path
        }
    }

    public var displayNameForRename: String {
        switch self {
        case .file(let file):
            return (file.displayName as NSString).deletingPathExtension
        case .folder(let path):
            return (path as NSString).lastPathComponent
        }
    }
}

public enum VaultItemOperationError: Error, Equatable, LocalizedError, Sendable {
    case invalidRelativePath(String)
    case targetEscapesVault
    case sourceMissing(String)
    case parentMissing(String)
    case targetAlreadyExists(String)
    case folderMoveIntoSelfOrDescendant
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRelativePath:
            return "Item path is invalid."
        case .targetEscapesVault:
            return "Item must stay inside the current vault."
        case .sourceMissing(let path):
            return "\"\(path)\" is no longer available."
        case .parentMissing(let path):
            return "\"\(path)\" is no longer available."
        case .targetAlreadyExists(let name):
            return "\"\(name)\" already exists."
        case .folderMoveIntoSelfOrDescendant:
            return "A folder cannot be moved into itself."
        case .operationFailed(let message):
            return message
        }
    }
}

public struct VaultFileOperationResult: Equatable, Sendable {
    public let oldFile: FileTreeItem
    public let newFile: FileTreeItem

    public init(oldFile: FileTreeItem, newFile: FileTreeItem) {
        self.oldFile = oldFile
        self.newFile = newFile
    }
}

public struct VaultFolderOperationResult: Equatable, Sendable {
    public let oldFolderPath: String
    public let newFolderPath: String

    public init(oldFolderPath: String, newFolderPath: String) {
        self.oldFolderPath = oldFolderPath
        self.newFolderPath = newFolderPath
    }
}

public struct VaultItemOperator {
    private let fileManager: FileManager
    private let validator: VaultNameValidator

    public init(
        fileManager: FileManager = .default,
        validator: VaultNameValidator = VaultNameValidator()
    ) {
        self.fileManager = fileManager
        self.validator = validator
    }

    public func renameFile(
        vaultURL: URL,
        file: FileTreeItem,
        newDisplayName: String
    ) throws -> VaultFileOperationResult {
        let noteName = try validator.validateNoteName(newDisplayName)
        let oldRelativePath = try normalizedRelativePath(file.relativePath)
        let parentPath = FileTreeItem(relativePath: oldRelativePath).parentPath
        let newRelativePath = parentPath.isEmpty ? noteName : "\(parentPath)/\(noteName)"
        if oldRelativePath == newRelativePath {
            return VaultFileOperationResult(oldFile: file, newFile: FileTreeItem(relativePath: oldRelativePath))
        }
        let sourceURL = try existingURL(vaultURL: vaultURL, relativePath: oldRelativePath, isDirectory: false)
        let targetURL = try targetURL(vaultURL: vaultURL, relativePath: newRelativePath)
        try ensureParentExists(targetURL.deletingLastPathComponent(), label: parentPath)
        try ensureNoExistingItem(at: targetURL, displayName: noteName)
        try moveItem(sourceURL, to: targetURL)
        return VaultFileOperationResult(
            oldFile: FileTreeItem(relativePath: oldRelativePath),
            newFile: FileTreeItem(relativePath: newRelativePath)
        )
    }

    public func renameFolder(
        vaultURL: URL,
        folderPath: String,
        newName: String
    ) throws -> VaultFolderOperationResult {
        let folderName = try validator.validateFolderName(newName)
        let oldRelativePath = try normalizedRelativePath(folderPath)
        let parent = (oldRelativePath as NSString).deletingLastPathComponent
        let parentPath = parent == "." ? "" : parent
        let newRelativePath = parentPath.isEmpty ? folderName : "\(parentPath)/\(folderName)"
        if oldRelativePath == newRelativePath {
            return VaultFolderOperationResult(oldFolderPath: oldRelativePath, newFolderPath: newRelativePath)
        }
        let sourceURL = try existingURL(vaultURL: vaultURL, relativePath: oldRelativePath, isDirectory: true)
        let targetURL = try targetURL(vaultURL: vaultURL, relativePath: newRelativePath)
        try ensureParentExists(targetURL.deletingLastPathComponent(), label: parentPath)
        try ensureNoExistingItem(at: targetURL, displayName: folderName)
        try moveItem(sourceURL, to: targetURL)
        return VaultFolderOperationResult(oldFolderPath: oldRelativePath, newFolderPath: newRelativePath)
    }

    public func moveFile(
        vaultURL: URL,
        file: FileTreeItem,
        destinationFolderPath: String
    ) throws -> VaultFileOperationResult {
        let oldRelativePath = try normalizedRelativePath(file.relativePath)
        let destinationPath = try normalizedFolderPath(destinationFolderPath)
        let displayName = FileTreeItem(relativePath: oldRelativePath).displayName
        let newRelativePath = destinationPath.isEmpty ? displayName : "\(destinationPath)/\(displayName)"
        if oldRelativePath == newRelativePath {
            return VaultFileOperationResult(oldFile: FileTreeItem(relativePath: oldRelativePath), newFile: FileTreeItem(relativePath: newRelativePath))
        }
        let sourceURL = try existingURL(vaultURL: vaultURL, relativePath: oldRelativePath, isDirectory: false)
        let destinationURL = try existingURL(vaultURL: vaultURL, relativePath: destinationPath, isDirectory: true)
        let targetURL = destinationURL.appendingPathComponent(displayName, isDirectory: false).standardizedFileURL
        try ensureContained(targetURL, in: vaultURL)
        try ensureNoExistingItem(at: targetURL, displayName: displayName)
        try moveItem(sourceURL, to: targetURL)
        return VaultFileOperationResult(
            oldFile: FileTreeItem(relativePath: oldRelativePath),
            newFile: FileTreeItem(relativePath: newRelativePath)
        )
    }

    public func moveFolder(
        vaultURL: URL,
        folderPath: String,
        destinationFolderPath: String
    ) throws -> VaultFolderOperationResult {
        let oldRelativePath = try normalizedRelativePath(folderPath)
        let destinationPath = try normalizedFolderPath(destinationFolderPath)
        guard !Self.path(destinationPath, isSameOrDescendantOf: oldRelativePath) else {
            throw VaultItemOperationError.folderMoveIntoSelfOrDescendant
        }
        let folderName = (oldRelativePath as NSString).lastPathComponent
        let newRelativePath = destinationPath.isEmpty ? folderName : "\(destinationPath)/\(folderName)"
        if oldRelativePath == newRelativePath {
            return VaultFolderOperationResult(oldFolderPath: oldRelativePath, newFolderPath: newRelativePath)
        }
        let sourceURL = try existingURL(vaultURL: vaultURL, relativePath: oldRelativePath, isDirectory: true)
        let destinationURL = try existingURL(vaultURL: vaultURL, relativePath: destinationPath, isDirectory: true)
        let targetURL = destinationURL.appendingPathComponent(folderName, isDirectory: true).standardizedFileURL
        try ensureContained(targetURL, in: vaultURL)
        try ensureNoExistingItem(at: targetURL, displayName: folderName)
        try moveItem(sourceURL, to: targetURL)
        return VaultFolderOperationResult(oldFolderPath: oldRelativePath, newFolderPath: newRelativePath)
    }

    public func containedURL(vaultURL: URL, relativePath: String) throws -> URL {
        try targetURL(vaultURL: vaultURL, relativePath: try normalizedRelativePath(relativePath))
    }

    public static func path(_ path: String, isSameOrDescendantOf prefix: String) -> Bool {
        path == prefix || path.hasPrefix("\(prefix)/")
    }

    public static func replacingPrefix(in relativePath: String, oldPrefix: String, newPrefix: String) -> String? {
        guard path(relativePath, isSameOrDescendantOf: oldPrefix) else {
            return nil
        }
        if relativePath == oldPrefix {
            return newPrefix
        }
        let suffix = relativePath.dropFirst(oldPrefix.count + 1)
        return newPrefix.isEmpty ? String(suffix) : "\(newPrefix)/\(suffix)"
    }

    private func normalizedRelativePath(_ relativePath: String) throws -> String {
        guard let normalized = WorkspacePathIdentity.canonicalRelativePath(relativePath) else {
            throw VaultItemOperationError.invalidRelativePath(relativePath)
        }
        return normalized
    }

    private func normalizedFolderPath(_ relativePath: String) throws -> String {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }
        return try normalizedRelativePath(trimmed)
    }

    private func existingURL(vaultURL: URL, relativePath: String, isDirectory expectedDirectory: Bool) throws -> URL {
        let url = try targetURL(vaultURL: vaultURL, relativePath: relativePath)
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            if expectedDirectory {
                throw VaultItemOperationError.parentMissing(relativePath)
            }
            throw VaultItemOperationError.sourceMissing(relativePath)
        }
        guard isDirectory.boolValue == expectedDirectory else {
            throw expectedDirectory
                ? VaultItemOperationError.parentMissing(relativePath)
                : VaultItemOperationError.sourceMissing(relativePath)
        }
        return url
    }

    private func targetURL(vaultURL: URL, relativePath: String) throws -> URL {
        let rootURL = vaultURL.standardizedFileURL.resolvingSymlinksInPath()
        let url = relativePath.isEmpty
            ? rootURL
            : rootURL.appendingPathComponent(relativePath).standardizedFileURL
        try ensureContained(url, in: rootURL)
        return url
    }

    private func ensureContained(_ childURL: URL, in vaultURL: URL) throws {
        let rootURL = vaultURL.standardizedFileURL.resolvingSymlinksInPath()
        let childPath = childURL.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = rootURL.path
        guard childPath == rootPath || childPath.hasPrefix("\(rootPath)/") else {
            throw VaultItemOperationError.targetEscapesVault
        }
    }

    private func ensureParentExists(_ parentURL: URL, label: String) throws {
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: parentURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw VaultItemOperationError.parentMissing(label)
        }
    }

    private func ensureNoExistingItem(at url: URL, displayName: String) throws {
        guard !fileManager.fileExists(atPath: url.path) else {
            throw VaultItemOperationError.targetAlreadyExists(displayName)
        }
    }

    private func moveItem(_ sourceURL: URL, to targetURL: URL) throws {
        do {
            try fileManager.moveItem(at: sourceURL, to: targetURL)
        } catch {
            throw VaultItemOperationError.operationFailed(error.localizedDescription)
        }
    }
}
