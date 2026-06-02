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

    public init(
        snapshot: FileTreeSnapshot,
        sortMode: FileTreeSortMode = .nameAscending,
        modifiedDates: [String: Date] = [:]
    ) {
        self.init(
            items: snapshot.items,
            folderPaths: snapshot.folderPaths,
            sortMode: sortMode,
            modifiedDates: modifiedDates
        )
    }

    public init(
        items: [FileTreeItem],
        folderPaths: [String] = [],
        sortMode: FileTreeSortMode = .nameAscending,
        modifiedDates: [String: Date] = [:]
    ) {
        itemsByID = Dictionary(
            items.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var folderIDs = Set<String>()
        for folderPath in folderPaths where !folderPath.isEmpty {
            var current = ""
            for component in folderPath.split(separator: "/") {
                current = current.isEmpty ? String(component) : "\(current)/\(component)"
                folderIDs.insert(current)
            }
        }
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
                Self.compareFolders($0, $1, sortMode: sortMode, modifiedDates: modifiedDates)
            }
        }
        childFilesByParent = filesByParent.mapValues { files in
            files.sorted {
                Self.compareFiles($0, $1, sortMode: sortMode, modifiedDates: modifiedDates)
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
        appendChildren(parent: "", depth: 0, expandedFolderIDs: expandedFolderIDs, rows: &rows)
        return rows
    }

    public func childRows(
        ofFolderID folderID: String,
        depth: Int,
        expandedFolderIDs: Set<String>
    ) -> [FileTreeOutlineRow] {
        var rows: [FileTreeOutlineRow] = []
        appendChildren(parent: folderID, depth: depth, expandedFolderIDs: expandedFolderIDs, rows: &rows)
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

    private static func compareFolders(
        _ lhs: String,
        _ rhs: String,
        sortMode: FileTreeSortMode,
        modifiedDates: [String: Date]
    ) -> Bool {
        switch sortMode {
        case .nameAscending:
            return displayName(forFolderID: lhs).localizedStandardCompare(displayName(forFolderID: rhs)) == .orderedAscending
        case .nameDescending:
            return displayName(forFolderID: lhs).localizedStandardCompare(displayName(forFolderID: rhs)) == .orderedDescending
        case .modifiedNewest:
            return compareModified(lhs, rhs, modifiedDates: modifiedDates, newestFirst: true)
        case .modifiedOldest:
            return compareModified(lhs, rhs, modifiedDates: modifiedDates, newestFirst: false)
        }
    }

    private static func compareFiles(
        _ lhs: FileTreeItem,
        _ rhs: FileTreeItem,
        sortMode: FileTreeSortMode,
        modifiedDates: [String: Date]
    ) -> Bool {
        switch sortMode {
        case .nameAscending:
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        case .nameDescending:
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedDescending
        case .modifiedNewest:
            return compareModified(lhs.relativePath, rhs.relativePath, modifiedDates: modifiedDates, newestFirst: true)
        case .modifiedOldest:
            return compareModified(lhs.relativePath, rhs.relativePath, modifiedDates: modifiedDates, newestFirst: false)
        }
    }

    private static func compareModified(
        _ lhs: String,
        _ rhs: String,
        modifiedDates: [String: Date],
        newestFirst: Bool
    ) -> Bool {
        let lhsDate = modifiedDates[lhs] ?? .distantPast
        let rhsDate = modifiedDates[rhs] ?? .distantPast
        if lhsDate != rhsDate {
            return newestFirst ? lhsDate > rhsDate : lhsDate < rhsDate
        }
        return lhs.localizedStandardCompare(rhs) == .orderedAscending
    }

    private func appendChildren(
        parent: String,
        depth: Int,
        expandedFolderIDs: Set<String>,
        rows: inout [FileTreeOutlineRow]
    ) {
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
                appendChildren(parent: folderID, depth: depth + 1, expandedFolderIDs: expandedFolderIDs, rows: &rows)
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
}
