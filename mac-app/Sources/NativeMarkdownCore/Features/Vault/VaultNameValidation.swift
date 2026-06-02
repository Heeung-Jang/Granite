import Foundation

public enum VaultNameValidationError: Error, Equatable, LocalizedError, Sendable {
    case empty
    case reserved(String)
    case containsPathSeparator
    case containsColon
    case unsupportedNoteExtension(String)

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "Name is required."
        case .reserved(let name):
            return "\"\(name)\" cannot be used as a name."
        case .containsPathSeparator:
            return "Names cannot contain path separators."
        case .containsColon:
            return "Names cannot contain colons."
        case .unsupportedNoteExtension(let ext):
            return "Only Markdown notes are supported. Remove .\(ext) or use .md."
        }
    }
}

public struct VaultNameValidator: Sendable {
    public init() {}

    public func validateVaultName(_ name: String) throws -> String {
        try validateFolderName(name)
    }

    public func validateFolderName(_ name: String) throws -> String {
        try validateBaseName(name)
    }

    public func validateNoteName(_ name: String) throws -> String {
        let trimmed = try validateBaseName(name)
        let nsName = trimmed as NSString
        let ext = nsName.pathExtension
        guard !ext.isEmpty else {
            return "\(trimmed).md"
        }
        guard ext.caseInsensitiveCompare("md") == .orderedSame else {
            throw VaultNameValidationError.unsupportedNoteExtension(ext)
        }
        return trimmed
    }

    private func validateBaseName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw VaultNameValidationError.empty
        }
        guard trimmed != ".", trimmed != ".." else {
            throw VaultNameValidationError.reserved(trimmed)
        }
        guard !trimmed.contains("/") && !trimmed.contains("\\") else {
            throw VaultNameValidationError.containsPathSeparator
        }
        guard !trimmed.contains(":") else {
            throw VaultNameValidationError.containsColon
        }
        return trimmed
    }
}
