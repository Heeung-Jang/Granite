import Foundation

public enum FileTreeResultState: String, Equatable, Sendable {
    case complete
    case partial
    case stale
}

public struct FileTreeItem: Identifiable, Equatable, Sendable {
    public let relativePath: String

    public init(relativePath: String) {
        self.relativePath = relativePath
    }

    public var id: String {
        relativePath
    }

    public var displayName: String {
        (relativePath as NSString).lastPathComponent
    }

    public var parentPath: String {
        let parent = (relativePath as NSString).deletingLastPathComponent
        return parent == "." ? "" : parent
    }
}

public struct FileTreeSnapshot: Equatable, Sendable {
    public let items: [FileTreeItem]
    public let folderPaths: [String]
    public let state: FileTreeResultState

    public init(
        items: [FileTreeItem],
        folderPaths: [String] = [],
        state: FileTreeResultState
    ) {
        self.items = items
        self.folderPaths = folderPaths
        self.state = state
    }
}

public protocol FileTreeLoading: Sendable {
    func loadFileTree(at vaultURL: URL, maxItems: Int) throws -> FileTreeSnapshot
}

public enum FileTreeLoadError: Error, Equatable {
    case cannotEnumerate(URL)
}

public struct FileSystemFileTreeLoader: FileTreeLoading {
    public init() {}

    public func loadFileTree(
        at vaultURL: URL,
        maxItems: Int = 5_000
    ) throws -> FileTreeSnapshot {
        let rootURL = vaultURL.standardizedFileURL
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else {
            throw FileTreeLoadError.cannotEnumerate(rootURL)
        }

        let visibleLimit = max(1, maxItems)
        let fetchLimit = visibleLimit + 1
        var items: [FileTreeItem] = []
        var isPartial = false

        for case let fileURL as URL in enumerator {
            guard let relativePath = relativePath(for: fileURL, under: rootURL) else {
                continue
            }

            let resourceValues = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if resourceValues?.isDirectory == true, shouldSkipDirectory(relativePath) {
                enumerator.skipDescendants()
                continue
            }

            guard isMarkdownPath(fileURL),
                  resourceValues?.isRegularFile == true,
                  !shouldSkipPath(relativePath)
            else {
                continue
            }

            items.append(FileTreeItem(relativePath: relativePath))
            if items.count == fetchLimit {
                isPartial = true
                break
            }
        }

        items.sort {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        if items.count > visibleLimit {
            items = Array(items.prefix(visibleLimit))
        }

        return FileTreeSnapshot(
            items: items,
            state: isPartial ? .partial : .complete
        )
    }

    private func relativePath(for fileURL: URL, under rootURL: URL) -> String? {
        let rootPath = rootURL.path
        let path = fileURL.standardizedFileURL.path
        guard path.hasPrefix("\(rootPath)/") else {
            return nil
        }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private func isMarkdownPath(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "md", "markdown":
            return true
        default:
            return false
        }
    }

    private func shouldSkipDirectory(_ relativePath: String) -> Bool {
        guard let name = relativePath.split(separator: "/").last else {
            return false
        }
        return Self.excludedDirectories.contains(String(name))
    }

    private func shouldSkipPath(_ relativePath: String) -> Bool {
        relativePath
            .split(separator: "/")
            .contains { Self.excludedDirectories.contains(String($0)) }
    }

    private static let excludedDirectories: Set<String> = [
        ".obsidian",
        ".git",
        ".worktrees",
        ".native-markdown-index"
    ]
}

public struct FileSystemFolderTreeLoader {
    public init() {}

    public func loadFolderPaths(at vaultURL: URL) throws -> [String] {
        let rootURL = vaultURL.standardizedFileURL
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else {
            throw FileTreeLoadError.cannotEnumerate(rootURL)
        }

        var folders: [String] = []
        for case let fileURL as URL in enumerator {
            guard let relativePath = Self.relativePath(for: fileURL, under: rootURL) else {
                continue
            }

            let resourceValues = try? fileURL.resourceValues(forKeys: [.isDirectoryKey])
            guard resourceValues?.isDirectory == true else {
                continue
            }
            if Self.shouldSkipDirectory(relativePath) {
                enumerator.skipDescendants()
                continue
            }
            folders.append(relativePath)
        }

        return folders.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private static func relativePath(for fileURL: URL, under rootURL: URL) -> String? {
        let rootPath = rootURL.path
        let path = fileURL.standardizedFileURL.path
        guard path.hasPrefix("\(rootPath)/") else {
            return nil
        }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private static func shouldSkipDirectory(_ relativePath: String) -> Bool {
        guard let name = relativePath.split(separator: "/").last else {
            return false
        }
        return excludedDirectories.contains(String(name))
    }

    private static let excludedDirectories: Set<String> = [
        ".obsidian",
        ".git",
        ".worktrees",
        ".native-markdown-index"
    ]
}
