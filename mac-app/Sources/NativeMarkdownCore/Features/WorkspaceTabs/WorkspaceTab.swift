import Foundation

public enum WorkspaceTabViewMode: String, Equatable, Sendable {
    case livePreview
    case reading
}

public struct WorkspaceTab: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var file: FileTreeItem?
    public var relativePathKey: String?
    public var backStack: [FileTreeItem]
    public var forwardStack: [FileTreeItem]
    public var viewMode: WorkspaceTabViewMode

    public init(
        id: UUID = UUID(),
        file: FileTreeItem? = nil,
        backStack: [FileTreeItem] = [],
        forwardStack: [FileTreeItem] = [],
        viewMode: WorkspaceTabViewMode = .livePreview
    ) {
        self.id = id
        self.file = file
        self.relativePathKey = file.flatMap(WorkspacePathIdentity.key(for:))
        self.backStack = backStack
        self.forwardStack = forwardStack
        self.viewMode = viewMode
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
