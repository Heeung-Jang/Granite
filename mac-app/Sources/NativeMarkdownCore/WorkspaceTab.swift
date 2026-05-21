import Foundation

public struct WorkspaceTab: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var file: FileTreeItem?
    public var relativePathKey: String?

    public init(id: UUID = UUID(), file: FileTreeItem? = nil) {
        self.id = id
        self.file = file
        self.relativePathKey = file.flatMap(WorkspacePathIdentity.key(for:))
    }

    public var isEmpty: Bool {
        file == nil
    }

    public var displayTitle: String {
        file?.displayName ?? "Untitled"
    }

    public mutating func replaceFile(_ file: FileTreeItem?) {
        self.file = file
        self.relativePathKey = file.flatMap(WorkspacePathIdentity.key(for:))
    }
}

public enum WorkspaceTabOpenDisposition: Equatable, Sendable {
    case currentTab
    case newTab
}

public struct WorkspaceTabClosedEntry: Equatable, Sendable {
    public let relativePathKey: String
    public let originalIndex: Int

    public init(relativePathKey: String, originalIndex: Int) {
        self.relativePathKey = relativePathKey
        self.originalIndex = max(0, originalIndex)
    }
}
