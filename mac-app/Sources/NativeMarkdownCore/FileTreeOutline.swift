import Foundation

public enum FileTreeOutlineRowKind: Equatable, Sendable {
    case folder
    case file
}

public struct FileTreeOutlineRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: FileTreeOutlineRowKind
    public let title: String
    public let depth: Int
    public let isExpanded: Bool
    public let file: FileTreeItem?

    public init(
        id: String,
        kind: FileTreeOutlineRowKind,
        title: String,
        depth: Int,
        isExpanded: Bool,
        file: FileTreeItem?
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.depth = depth
        self.isExpanded = isExpanded
        self.file = file
    }
}

public struct FileTreeOutline: Equatable, Sendable {
    private let itemsByID: [String: FileTreeItem]
    private let childFoldersByParent: [String: [String]]
    private let childFilesByParent: [String: [FileTreeItem]]

    public init(snapshot: FileTreeSnapshot) {
        self.init(items: snapshot.items)
    }

    public init(items: [FileTreeItem]) {
        itemsByID = Dictionary(
            items.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var folderIDs = Set<String>()
        var filesByParent: [String: [FileTreeItem]] = [:]
        for item in items {
            filesByParent[item.parentPath, default: []].append(item)
            var current = ""
            for component in item.parentPath.split(separator: "/") {
                current = current.isEmpty ? String(component) : "\(current)/\(component)"
                folderIDs.insert(current)
            }
        }

        var foldersByParent: [String: [String]] = [:]
        for folderID in folderIDs {
            foldersByParent[Self.parentPath(forFolderID: folderID), default: []].append(folderID)
        }

        childFoldersByParent = foldersByParent.mapValues { folders in
            folders.sorted {
                Self.displayName(forFolderID: $0).localizedStandardCompare(Self.displayName(forFolderID: $1)) == .orderedAscending
            }
        }
        childFilesByParent = filesByParent.mapValues { files in
            files.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
        }
    }

    public func item(withID id: String?) -> FileTreeItem? {
        guard let id else {
            return nil
        }
        return itemsByID[id]
    }

    public func visibleRows(expandedFolderIDs: Set<String>) -> [FileTreeOutlineRow] {
        var rows: [FileTreeOutlineRow] = []

        func appendChildren(parent: String, depth: Int) {
            for folderID in childFoldersByParent[parent] ?? [] {
                let isExpanded = expandedFolderIDs.contains(folderID)
                rows.append(FileTreeOutlineRow(
                    id: folderID,
                    kind: .folder,
                    title: Self.displayName(forFolderID: folderID),
                    depth: depth,
                    isExpanded: isExpanded,
                    file: nil
                ))
                if isExpanded {
                    appendChildren(parent: folderID, depth: depth + 1)
                }
            }

            for file in childFilesByParent[parent] ?? [] {
                rows.append(FileTreeOutlineRow(
                    id: file.id,
                    kind: .file,
                    title: (file.displayName as NSString).deletingPathExtension,
                    depth: depth,
                    isExpanded: false,
                    file: file
                ))
            }
        }

        appendChildren(parent: "", depth: 0)
        return rows
    }

    public func defaultExpandedFolderIDs(selectedFile: FileTreeItem?) -> Set<String> {
        var folderIDs = Set(childFoldersByParent[""] ?? [])
        if let selectedFile {
            folderIDs.formUnion(ancestorFolderIDs(for: selectedFile))
        }
        return folderIDs
    }

    public func ancestorFolderIDs(for file: FileTreeItem) -> Set<String> {
        var folderIDs = Set<String>()
        var current = ""
        for component in file.parentPath.split(separator: "/") {
            current = current.isEmpty ? String(component) : "\(current)/\(component)"
            folderIDs.insert(current)
        }
        return folderIDs
    }

    private static func parentPath(forFolderID folderID: String) -> String {
        let parent = (folderID as NSString).deletingLastPathComponent
        return parent == "." ? "" : parent
    }

    private static func displayName(forFolderID folderID: String) -> String {
        (folderID as NSString).lastPathComponent
    }
}
