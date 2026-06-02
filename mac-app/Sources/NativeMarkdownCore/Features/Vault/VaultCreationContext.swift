import Foundation

public enum VaultCreationTarget: Equatable, Sendable {
    case vaultRoot
    case folder(String)
    case noteParent(FileTreeItem)

    public var parentFolderPath: String {
        switch self {
        case .vaultRoot:
            return ""
        case .folder(let path):
            return path
        case .noteParent(let item):
            return item.parentPath
        }
    }
}

public struct VaultCreationContext: Equatable, Sendable {
    public let target: VaultCreationTarget

    public init(target: VaultCreationTarget) {
        self.target = target
    }

    public var parentFolderPath: String {
        target.parentFolderPath
    }

    public static func from(selectedFolderPath: String?, selectedFile: FileTreeItem?) -> VaultCreationContext {
        if let selectedFolderPath {
            return VaultCreationContext(target: .folder(selectedFolderPath))
        }
        if let selectedFile {
            return VaultCreationContext(target: .noteParent(selectedFile))
        }
        return VaultCreationContext(target: .vaultRoot)
    }
}
