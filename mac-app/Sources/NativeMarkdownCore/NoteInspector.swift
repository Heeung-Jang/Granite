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
