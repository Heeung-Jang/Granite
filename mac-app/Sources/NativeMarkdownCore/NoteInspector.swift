import Foundation

public enum LinkResolutionState: Equatable, Sendable {
    case resolved(FileTreeItem)
    case missing
    case duplicate([FileTreeItem])
    case missingHeading(FileTreeItem, String)
}

public struct OutgoingLinkItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let target: String
    public let heading: String?
    public let state: LinkResolutionState

    public init(
        id: String,
        label: String,
        target: String,
        heading: String?,
        state: LinkResolutionState
    ) {
        self.id = id
        self.label = label
        self.target = target
        self.heading = heading
        self.state = state
    }
}

public struct BacklinkItem: Identifiable, Equatable, Sendable {
    public let file: FileTreeItem
    public let snippet: String

    public init(file: FileTreeItem, snippet: String) {
        self.file = file
        self.snippet = snippet
    }

    public var id: String {
        file.id
    }
}

public struct PropertyItem: Identifiable, Equatable, Sendable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }

    public var id: String {
        key
    }
}

public struct TagNoteGroup: Identifiable, Equatable, Sendable {
    public let tag: String
    public let files: [FileTreeItem]

    public init(tag: String, files: [FileTreeItem]) {
        self.tag = tag
        self.files = files
    }

    public var id: String {
        tag
    }
}

public enum LocalGraphDepth: String, CaseIterable, Equatable, Sendable {
    case oneHop
    case twoHop

    public var displayName: String {
        switch self {
        case .oneHop:
            "1-hop"
        case .twoHop:
            "2-hop"
        }
    }
}

public struct LocalGraphRequest: Equatable, Sendable {
    public let depth: LocalGraphDepth
    public let maxNodes: Int
    public let maxEdges: Int

    public init(depth: LocalGraphDepth = .oneHop, maxNodes: Int = 80, maxEdges: Int = 160) {
        self.depth = depth
        self.maxNodes = max(1, maxNodes)
        self.maxEdges = max(1, maxEdges)
    }
}

public struct LocalGraphSnapshot: Equatable, Sendable {
    public let centerNodeID: String
    public let nodes: [LocalGraphNode]
    public let edges: [LocalGraphEdge]
    public let state: SearchResultState

    public init(
        centerNodeID: String,
        nodes: [LocalGraphNode],
        edges: [LocalGraphEdge],
        state: SearchResultState
    ) {
        self.centerNodeID = centerNodeID
        self.nodes = nodes
        self.edges = edges
        self.state = state
    }
}

public struct LocalGraphNode: Identifiable, Equatable, Sendable {
    public let id: String
    public let file: FileTreeItem?
    public let label: String
    public let kind: LocalGraphNodeKind

    public init(id: String, file: FileTreeItem?, label: String, kind: LocalGraphNodeKind) {
        self.id = id
        self.file = file
        self.label = label
        self.kind = kind
    }
}

public enum LocalGraphNodeKind: Equatable, Sendable {
    case center
    case resolved
    case unresolved
}

public struct LocalGraphEdge: Identifiable, Equatable, Sendable {
    public let id: String
    public let sourceNodeID: String
    public let targetNodeID: String
    public let targetText: String
    public let direction: LocalGraphEdgeDirection
    public let hop: Int

    public init(
        id: String,
        sourceNodeID: String,
        targetNodeID: String,
        targetText: String,
        direction: LocalGraphEdgeDirection,
        hop: Int
    ) {
        self.id = id
        self.sourceNodeID = sourceNodeID
        self.targetNodeID = targetNodeID
        self.targetText = targetText
        self.direction = direction
        self.hop = hop
    }
}

public enum LocalGraphEdgeDirection: Equatable, Sendable {
    case outgoing
    case backlink
}

public struct NoteInspectorSnapshot: Equatable, Sendable {
    public let file: FileTreeItem
    public let outgoingLinks: [OutgoingLinkItem]
    public let backlinks: [BacklinkItem]
    public let tags: [String]
    public let tagNotes: [TagNoteGroup]
    public let properties: [PropertyItem]
    public let attachments: [AttachmentReferenceItem]
    public let warnings: [String]
    public let state: SearchResultState

    public init(
        file: FileTreeItem,
        outgoingLinks: [OutgoingLinkItem],
        backlinks: [BacklinkItem],
        tags: [String],
        tagNotes: [TagNoteGroup],
        properties: [PropertyItem],
        attachments: [AttachmentReferenceItem],
        warnings: [String],
        state: SearchResultState
    ) {
        self.file = file
        self.outgoingLinks = outgoingLinks
        self.backlinks = backlinks
        self.tags = tags
        self.tagNotes = tagNotes
        self.properties = properties
        self.attachments = attachments
        self.warnings = warnings
        self.state = state
    }
}

public protocol NoteInspectorLoading: Sendable {
    func loadInspector(at vaultURL: URL, file: FileTreeItem, maxFiles: Int) throws -> NoteInspectorSnapshot
}

public protocol LocalGraphLoading: Sendable {
    func loadGraph(
        at vaultURL: URL,
        file: FileTreeItem,
        request: LocalGraphRequest,
        maxFiles: Int
    ) throws -> LocalGraphSnapshot
}

public struct FileSystemNoteInspectorLoader: NoteInspectorLoading {
    public init() {}

    public func loadInspector(
        at vaultURL: URL,
        file: FileTreeItem,
        maxFiles: Int = 5_000
    ) throws -> NoteInspectorSnapshot {
        let tree = try FileSystemFileTreeLoader().loadFileTree(at: vaultURL, maxItems: maxFiles)
        let files = tree.items
        let titleIndex = titleIndex(for: files)
        let document = try FileSystemNoteDocumentLoader().loadNote(at: vaultURL, file: file)
        let parsed = parseNote(document.contents)
        let attachments = try FileSystemAttachmentReferenceLoader().loadAttachments(
            at: vaultURL,
            file: file,
            contents: document.contents
        )

        let outgoing = parsed.links.enumerated().map { index, link in
            resolve(link: link, index: index, titleIndex: titleIndex, vaultURL: vaultURL)
        }
        let backlinks = loadBacklinks(to: file, files: files, vaultURL: vaultURL)
        let tagNotes = parsed.tags.map { tag in
            TagNoteGroup(
                tag: tag,
                files: filesWithTag(tag, excluding: file, files: files, vaultURL: vaultURL)
            )
        }

        return NoteInspectorSnapshot(
            file: file,
            outgoingLinks: outgoing,
            backlinks: backlinks,
            tags: parsed.tags,
            tagNotes: tagNotes,
            properties: parsed.properties,
            attachments: attachments,
            warnings: parsed.warnings,
            state: tree.state == .partial ? .partial : .complete
        )
    }

    private func titleIndex(for files: [FileTreeItem]) -> [String: [FileTreeItem]] {
        Dictionary(grouping: files) { file in
            (file.displayName as NSString).deletingPathExtension.lowercased()
        }
    }

    private func resolve(
        link: ParsedWikiLink,
        index: Int,
        titleIndex: [String: [FileTreeItem]],
        vaultURL: URL
    ) -> OutgoingLinkItem {
        let candidates = titleIndex[link.target.lowercased()] ?? []
        let state: LinkResolutionState
        if candidates.isEmpty {
            state = .missing
        } else if candidates.count > 1 {
            state = .duplicate(candidates)
        } else if let heading = link.heading,
                  !file(candidates[0], in: vaultURL, containsHeading: heading) {
            state = .missingHeading(candidates[0], heading)
        } else {
            state = .resolved(candidates[0])
        }

        return OutgoingLinkItem(
            id: "\(index)-\(link.raw)",
            label: link.alias ?? link.raw,
            target: link.target,
            heading: link.heading,
            state: state
        )
    }

    private func loadBacklinks(
        to file: FileTreeItem,
        files: [FileTreeItem],
        vaultURL: URL
    ) -> [BacklinkItem] {
        let title = (file.displayName as NSString).deletingPathExtension
        return files.compactMap { candidate in
            guard candidate != file,
                  let document = try? FileSystemNoteDocumentLoader().loadNote(at: vaultURL, file: candidate),
                  document.contents.range(of: "[[\(title)", options: [.caseInsensitive, .diacriticInsensitive]) != nil
            else {
                return nil
            }
            return BacklinkItem(file: candidate, snippet: backlinkSnippet(in: document.contents, title: title))
        }
    }

    private func filesWithTag(
        _ tag: String,
        excluding file: FileTreeItem,
        files: [FileTreeItem],
        vaultURL: URL
    ) -> [FileTreeItem] {
        files.filter { candidate in
            guard candidate != file,
                  let document = try? FileSystemNoteDocumentLoader().loadNote(at: vaultURL, file: candidate)
            else {
                return false
            }
            return parseNote(document.contents).tags.contains(tag)
        }
    }

    private func file(_ file: FileTreeItem, in vaultURL: URL, containsHeading heading: String) -> Bool {
        guard let document = try? FileSystemNoteDocumentLoader().loadNote(at: vaultURL, file: file) else {
            return false
        }
        return parseHeadings(document.contents).contains(normalizedHeading(heading))
    }

    private func backlinkSnippet(in contents: String, title: String) -> String {
        guard let range = contents.range(of: "[[\(title)", options: [.caseInsensitive, .diacriticInsensitive]) else {
            return title
        }
        let context = 40
        let lower = contents.index(range.lowerBound, offsetBy: -context, limitedBy: contents.startIndex) ?? contents.startIndex
        let upper = contents.index(range.upperBound, offsetBy: context, limitedBy: contents.endIndex) ?? contents.endIndex
        return contents[lower..<upper]
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct FileSystemLocalGraphLoader: LocalGraphLoading {
    public init() {}

    public func loadGraph(
        at vaultURL: URL,
        file: FileTreeItem,
        request: LocalGraphRequest = LocalGraphRequest(),
        maxFiles: Int = 5_000
    ) throws -> LocalGraphSnapshot {
        let tree = try FileSystemFileTreeLoader().loadFileTree(at: vaultURL, maxItems: maxFiles)
        let files = tree.items
        let titleIndex = titleIndex(for: files)
        let centerNodeID = localGraphNodeID(for: file)
        var builder = LocalGraphBuilder(
            centerNodeID: centerNodeID,
            maxNodes: request.maxNodes,
            maxEdges: request.maxEdges,
            isPartial: tree.state == .partial
        )

        builder.addNode(LocalGraphNode(
            id: centerNodeID,
            file: file,
            label: file.displayName,
            kind: .center
        ))

        let outgoing = outgoingGraphLinks(from: file, vaultURL: vaultURL, titleIndex: titleIndex)
        var frontier: [FileTreeItem] = []
        for link in outgoing {
            if case .resolved(let target) = link.target, target != file {
                appendUnique(target, to: &frontier)
            }
            builder.addEdge(link.edge(from: centerNodeID, hop: 1), target: link.target)
        }

        let backlinks = backlinkGraphLinks(to: file, files: files, vaultURL: vaultURL, titleIndex: titleIndex)
        for backlink in backlinks {
            appendUnique(backlink.source, to: &frontier)
            builder.addEdge(
                LocalGraphEdge(
                    id: "\(localGraphNodeID(for: backlink.source))->\(centerNodeID)-backlink-\(backlink.targetText)",
                    sourceNodeID: localGraphNodeID(for: backlink.source),
                    targetNodeID: centerNodeID,
                    targetText: backlink.targetText,
                    direction: .backlink,
                    hop: 1
                ),
                target: .resolved(backlink.source)
            )
        }

        if request.depth == .twoHop {
            for source in frontier.sorted(by: { $0.relativePath < $1.relativePath }) {
                guard !builder.isEdgeLimitReached else {
                    builder.markPartial()
                    break
                }
                let links = outgoingGraphLinks(from: source, vaultURL: vaultURL, titleIndex: titleIndex)
                for link in links {
                    builder.addEdge(link.edge(from: localGraphNodeID(for: source), hop: 2), target: link.target)
                }
            }
        }

        return builder.snapshot()
    }

    private func titleIndex(for files: [FileTreeItem]) -> [String: [FileTreeItem]] {
        Dictionary(grouping: files) { file in
            (file.displayName as NSString).deletingPathExtension.lowercased()
        }
    }

    private func outgoingGraphLinks(
        from file: FileTreeItem,
        vaultURL: URL,
        titleIndex: [String: [FileTreeItem]]
    ) -> [ResolvedGraphLink] {
        guard let document = try? FileSystemNoteDocumentLoader().loadNote(at: vaultURL, file: file) else {
            return []
        }
        return parseNote(document.contents).links.enumerated().map { index, link in
            ResolvedGraphLink(
                id: "\(file.id)-out-\(index)-\(link.raw)",
                targetText: link.target,
                target: graphTarget(for: link, titleIndex: titleIndex)
            )
        }
    }

    private func backlinkGraphLinks(
        to file: FileTreeItem,
        files: [FileTreeItem],
        vaultURL: URL,
        titleIndex: [String: [FileTreeItem]]
    ) -> [BacklinkGraphLink] {
        files.compactMap { candidate in
            guard candidate != file,
                  let document = try? FileSystemNoteDocumentLoader().loadNote(at: vaultURL, file: candidate)
            else {
                return nil
            }

            let links = parseNote(document.contents).links
            guard let link = links.first(where: { graphTarget(for: $0, titleIndex: titleIndex) == .resolved(file) }) else {
                return nil
            }
            return BacklinkGraphLink(source: candidate, targetText: link.target)
        }
    }

    private func graphTarget(
        for link: ParsedWikiLink,
        titleIndex: [String: [FileTreeItem]]
    ) -> LocalGraphTarget {
        let candidates = titleIndex[link.target.lowercased()] ?? []
        if candidates.count == 1 {
            return .resolved(candidates[0])
        }
        return .unresolved(link.target)
    }
}

private struct ResolvedGraphLink {
    let id: String
    let targetText: String
    let target: LocalGraphTarget

    func edge(from sourceNodeID: String, hop: Int) -> LocalGraphEdge {
        LocalGraphEdge(
            id: "\(sourceNodeID)->\(target.nodeID)-\(id)-hop-\(hop)",
            sourceNodeID: sourceNodeID,
            targetNodeID: target.nodeID,
            targetText: targetText,
            direction: .outgoing,
            hop: hop
        )
    }
}

private struct BacklinkGraphLink {
    let source: FileTreeItem
    let targetText: String
}

private enum LocalGraphTarget: Equatable {
    case resolved(FileTreeItem)
    case unresolved(String)

    var nodeID: String {
        switch self {
        case .resolved(let file):
            return localGraphNodeID(for: file)
        case .unresolved(let target):
            return localGraphUnresolvedNodeID(for: target)
        }
    }

    var node: LocalGraphNode {
        switch self {
        case .resolved(let file):
            LocalGraphNode(id: nodeID, file: file, label: file.displayName, kind: .resolved)
        case .unresolved(let target):
            LocalGraphNode(id: nodeID, file: nil, label: target, kind: .unresolved)
        }
    }
}

private struct LocalGraphBuilder {
    let centerNodeID: String
    let maxNodes: Int
    let maxEdges: Int
    private var nodes: [LocalGraphNode] = []
    private var edges: [LocalGraphEdge] = []
    private var isPartial: Bool

    init(centerNodeID: String, maxNodes: Int, maxEdges: Int, isPartial: Bool) {
        self.centerNodeID = centerNodeID
        self.maxNodes = maxNodes
        self.maxEdges = maxEdges
        self.isPartial = isPartial
    }

    var isEdgeLimitReached: Bool {
        edges.count >= maxEdges
    }

    mutating func addNode(_ node: LocalGraphNode) {
        guard !nodes.contains(where: { $0.id == node.id }) else {
            return
        }
        guard nodes.count < maxNodes else {
            markPartial()
            return
        }
        nodes.append(node)
    }

    mutating func addEdge(_ edge: LocalGraphEdge, target: LocalGraphTarget) {
        guard edges.count < maxEdges else {
            markPartial()
            return
        }
        let previousNodeCount = nodes.count
        addNode(target.node)
        guard nodes.contains(where: { $0.id == target.nodeID }) else {
            if nodes.count == previousNodeCount {
                markPartial()
            }
            return
        }
        edges.append(edge)
    }

    mutating func markPartial() {
        isPartial = true
    }

    func snapshot() -> LocalGraphSnapshot {
        LocalGraphSnapshot(
            centerNodeID: centerNodeID,
            nodes: nodes,
            edges: edges,
            state: isPartial ? .partial : .complete
        )
    }
}

private func localGraphNodeID(for file: FileTreeItem) -> String {
    "file:\(file.relativePath)"
}

private func localGraphUnresolvedNodeID(for target: String) -> String {
    "unresolved:\(target.lowercased())"
}

private func appendUnique(_ file: FileTreeItem, to files: inout [FileTreeItem]) {
    guard !files.contains(file) else {
        return
    }
    files.append(file)
}

private struct ParsedNote {
    let links: [ParsedWikiLink]
    let tags: [String]
    let properties: [PropertyItem]
    let warnings: [String]
}

private struct ParsedWikiLink {
    let raw: String
    let target: String
    let heading: String?
    let alias: String?
}

private func parseNote(_ contents: String) -> ParsedNote {
    let frontmatter = parseFrontmatter(contents)
    let body = frontmatter.body
    let bodyTags = parseTags(body)
    let propertyTags = frontmatter.properties
        .first { $0.key == "tags" }?
        .value
        .split(separator: ",")
        .map { normalizeTag(String($0)) }
        .filter { !$0.isEmpty } ?? []
    let tags = Array(Set(bodyTags + propertyTags)).sorted()

    return ParsedNote(
        links: parseWikiLinks(body),
        tags: tags,
        properties: frontmatter.properties,
        warnings: frontmatter.warnings
    )
}

private func parseFrontmatter(_ contents: String) -> (properties: [PropertyItem], warnings: [String], body: String) {
    guard contents.hasPrefix("---\n") || contents.hasPrefix("---\r\n") else {
        return ([], [], contents)
    }

    let lines = contents.components(separatedBy: .newlines)
    guard let closingIndex = lines.dropFirst().firstIndex(of: "---") else {
        return ([], ["Malformed frontmatter"], contents)
    }

    let properties = lines[1..<closingIndex].compactMap { line -> PropertyItem? in
        guard let separator = line.firstIndex(of: ":") else {
            return nil
        }
        let key = line[..<separator].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: separator)...]
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]\"'"))
        guard !key.isEmpty else {
            return nil
        }
        return PropertyItem(key: key, value: value)
    }
    let body = lines.dropFirst(closingIndex + 1).joined(separator: "\n")
    return (properties, [], body)
}

private func parseWikiLinks(_ contents: String) -> [ParsedWikiLink] {
    let pattern = #"\[\[([^\]]+)\]\]"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return []
    }
    let nsRange = NSRange(contents.startIndex..<contents.endIndex, in: contents)
    return regex.matches(in: contents, range: nsRange).compactMap { match in
        guard let range = Range(match.range(at: 1), in: contents) else {
            return nil
        }
        let raw = String(contents[range])
        let aliasSplit = raw.split(separator: "|", maxSplits: 1).map(String.init)
        let targetPart = aliasSplit[0]
        let alias = aliasSplit.count > 1 ? aliasSplit[1] : nil
        let headingSplit = targetPart.split(separator: "#", maxSplits: 1).map(String.init)
        let target = headingSplit[0].trimmingCharacters(in: .whitespaces)
        let heading = headingSplit.count > 1 ? headingSplit[1].trimmingCharacters(in: .whitespaces) : nil
        guard !target.isEmpty else {
            return nil
        }
        return ParsedWikiLink(raw: raw, target: target, heading: heading, alias: alias)
    }
}

private func parseTags(_ contents: String) -> [String] {
    let pattern = #"(^|\s)#([\p{L}\p{N}_/-]+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return []
    }
    let nsRange = NSRange(contents.startIndex..<contents.endIndex, in: contents)
    let tags = regex.matches(in: contents, range: nsRange).compactMap { match -> String? in
        guard let range = Range(match.range(at: 2), in: contents) else {
            return nil
        }
        return normalizeTag(String(contents[range]))
    }
    return Array(Set(tags)).sorted()
}

private func parseHeadings(_ contents: String) -> Set<String> {
    Set(contents
        .components(separatedBy: .newlines)
        .compactMap { line in
            guard line.hasPrefix("#") else {
                return nil
            }
            return normalizedHeading(line.trimmingCharacters(in: CharacterSet(charactersIn: "# ")))
        })
}

private func normalizeTag(_ tag: String) -> String {
    tag.trimmingCharacters(in: CharacterSet(charactersIn: "# []\"'"))
}

private func normalizedHeading(_ heading: String) -> String {
    heading.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}
