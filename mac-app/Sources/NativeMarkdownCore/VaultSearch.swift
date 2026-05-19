import Foundation

public enum SearchMode: String, CaseIterable, Equatable, Hashable, Sendable {
    case fileName
    case body

    public var displayName: String {
        switch self {
        case .fileName:
            return "File"
        case .body:
            return "Body"
        }
    }
}

public enum SearchResultState: String, Equatable, Sendable {
    case complete
    case partial
    case stale
    case cancelled
    case error
}

public struct SearchPageRequest: Equatable, Sendable {
    public let requestID: UInt64
    public let offset: Int
    public let limit: Int

    public init(requestID: UInt64, offset: Int, limit: Int) {
        self.requestID = requestID
        self.offset = max(0, offset)
        self.limit = max(1, limit)
    }
}

public struct SearchHitItem: Identifiable, Equatable, Sendable {
    public let file: FileTreeItem
    public let title: String
    public let snippet: String
    public let rank: Double

    public init(file: FileTreeItem, title: String, snippet: String, rank: Double) {
        self.file = file
        self.title = title
        self.snippet = snippet
        self.rank = rank
    }

    public var id: String {
        file.id
    }
}

public struct SearchPage: Equatable, Sendable {
    public let requestID: UInt64
    public let items: [SearchHitItem]
    public let nextOffset: Int?
    public let state: SearchResultState

    public init(
        requestID: UInt64,
        items: [SearchHitItem],
        nextOffset: Int?,
        state: SearchResultState
    ) {
        self.requestID = requestID
        self.items = items
        self.nextOffset = nextOffset
        self.state = state
    }
}

public protocol VaultSearchLoading: Sendable {
    func search(
        at vaultURL: URL,
        query: String,
        mode: SearchMode,
        page: SearchPageRequest
    ) throws -> SearchPage
}

public enum VaultSearchError: Error, Equatable {
    case emptyQuery
    case cannotEnumerate(URL)
}

public struct FileSystemVaultSearchLoader: VaultSearchLoading {
    public init() {}

    public func search(
        at vaultURL: URL,
        query: String,
        mode: SearchMode,
        page: SearchPageRequest
    ) throws -> SearchPage {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            throw VaultSearchError.emptyQuery
        }

        let rootURL = vaultURL.standardizedFileURL
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else {
            throw VaultSearchError.cannotEnumerate(rootURL)
        }

        let fetchLimit = page.limit + 1
        var skipped = 0
        var matches: [SearchHitItem] = []

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
                  !shouldSkipPath(relativePath),
                  let hit = searchHit(
                    fileURL: fileURL,
                    relativePath: relativePath,
                    query: normalizedQuery,
                    mode: mode
                  )
            else {
                continue
            }

            if skipped < page.offset {
                skipped += 1
                continue
            }

            matches.append(hit)
            if matches.count == fetchLimit {
                break
            }
        }

        matches.sort {
            if $0.rank == $1.rank {
                return $0.file.relativePath.localizedStandardCompare($1.file.relativePath) == .orderedAscending
            }
            return $0.rank > $1.rank
        }

        let hasNext = matches.count > page.limit
        if hasNext {
            matches = Array(matches.prefix(page.limit))
        }

        return SearchPage(
            requestID: page.requestID,
            items: matches,
            nextOffset: hasNext ? page.offset + page.limit : nil,
            state: hasNext ? .partial : .complete
        )
    }

    private func searchHit(
        fileURL: URL,
        relativePath: String,
        query: String,
        mode: SearchMode
    ) -> SearchHitItem? {
        let file = FileTreeItem(relativePath: relativePath)
        switch mode {
        case .fileName:
            guard let range = file.displayName.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
                return nil
            }
            let startsInTitle = range.lowerBound == file.displayName.startIndex
            return SearchHitItem(
                file: file,
                title: file.displayName,
                snippet: file.parentPath.isEmpty ? relativePath : file.parentPath,
                rank: startsInTitle ? 2 : 1
            )
        case .body:
            guard let contents = try? String(contentsOf: fileURL, encoding: .utf8),
                  let range = contents.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
            else {
                return nil
            }
            return SearchHitItem(
                file: file,
                title: file.displayName,
                snippet: snippet(in: contents, around: range),
                rank: 1
            )
        }
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

    private func snippet(in contents: String, around range: Range<String.Index>) -> String {
        let context = 48
        let lower = contents.index(range.lowerBound, offsetBy: -context, limitedBy: contents.startIndex) ?? contents.startIndex
        let upper = contents.index(range.upperBound, offsetBy: context, limitedBy: contents.endIndex) ?? contents.endIndex
        let raw = contents[lower..<upper]
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let excludedDirectories: Set<String> = [
        ".obsidian",
        ".git",
        ".worktrees",
        ".native-markdown-index"
    ]
}
