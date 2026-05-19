import Foundation

public enum MarkdownEditorInteraction: Equatable, Sendable {
    case wikiLink(EditorWikiLink)
    case externalLink(EditorExternalLink)
    case tag(String)
}

public struct EditorWikiLink: Equatable, Sendable {
    public let raw: String
    public let target: String
    public let heading: String?
    public let alias: String?

    public init(raw: String, target: String, heading: String?, alias: String?) {
        self.raw = raw
        self.target = target
        self.heading = heading
        self.alias = alias
    }
}

public struct EditorExternalLink: Equatable, Sendable {
    public let rawTarget: String

    public init(rawTarget: String) {
        self.rawTarget = rawTarget
    }

    public var url: URL? {
        URL(string: rawTarget)
    }

    public var isUserConfirmableExternalURL: Bool {
        guard let scheme = url?.scheme?.lowercased() else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }
}

public enum MarkdownEditorInteractionResolver {
    public static func interaction(in text: String, utf16Offset: Int) -> MarkdownEditorInteraction? {
        let nsText = text as NSString
        guard utf16Offset >= 0, utf16Offset < nsText.length else {
            return nil
        }

        if let link = wikiLink(in: text, utf16Offset: utf16Offset) {
            return .wikiLink(link)
        }
        if let link = externalLink(in: text, utf16Offset: utf16Offset) {
            return .externalLink(link)
        }
        if let tag = tag(in: text, utf16Offset: utf16Offset) {
            return .tag(tag)
        }
        return nil
    }

    private static func wikiLink(in text: String, utf16Offset: Int) -> EditorWikiLink? {
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in wikiLinkRegex.matches(in: text, range: nsRange) where match.range.contains(utf16Offset) {
            guard let range = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return parseWikiLinkContent(String(text[range]))
        }
        return nil
    }

    private static func externalLink(in text: String, utf16Offset: Int) -> EditorExternalLink? {
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in markdownLinkRegex.matches(in: text, range: nsRange) where match.range.contains(utf16Offset) {
            guard let range = Range(match.range(at: 1), in: text) else {
                return nil
            }
            let target = String(text[range])
            guard targetScheme(target) != nil else {
                return nil
            }
            return EditorExternalLink(rawTarget: target)
        }
        return nil
    }

    private static func tag(in text: String, utf16Offset: Int) -> String? {
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in tagRegex.matches(in: text, range: nsRange) where match.range(at: 2).contains(utf16Offset) {
            guard let range = Range(match.range(at: 2), in: text) else {
                return nil
            }
            let tag = String(text[range])
            return tag.isEmpty ? nil : tag
        }
        return nil
    }

    private static func parseWikiLinkContent(_ rawContent: String) -> EditorWikiLink? {
        let raw = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return nil
        }

        let aliasParts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let targetPart = String(aliasParts[0])
        let alias = aliasParts.count > 1 ? String(aliasParts[1]).trimmingCharacters(in: .whitespaces) : nil
        let headingParts = targetPart.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let target = String(headingParts[0]).trimmingCharacters(in: .whitespaces)
        let heading = headingParts.count > 1 ? String(headingParts[1]).trimmingCharacters(in: .whitespaces) : nil
        guard !target.isEmpty else {
            return nil
        }

        return EditorWikiLink(
            raw: raw,
            target: target,
            heading: heading?.isEmpty == false ? heading : nil,
            alias: alias?.isEmpty == false ? alias : nil
        )
    }

    private static let wikiLinkRegex = regex(#"!?\[\[([^\]\n]+)\]\]"#)
    private static let markdownLinkRegex = regex(#"!?\[[^\]\n]*\]\(([^)\s]+)(?:\s+[^)]*)?\)"#)
    private static let tagRegex = regex(#"(^|\s)#([\p{L}\p{N}_/-]+)"#)

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }
}

public struct FileSystemEditorWikiLinkResolver: Sendable {
    public init() {}

    public func resolve(
        _ link: EditorWikiLink,
        at vaultURL: URL,
        maxFiles: Int = 5_000
    ) throws -> LinkResolutionState {
        let tree = try FileSystemFileTreeLoader().loadFileTree(at: vaultURL, maxItems: maxFiles)
        let candidates = Dictionary(grouping: tree.items) { file in
            (file.displayName as NSString).deletingPathExtension.lowercased()
        }[link.target.lowercased()] ?? []

        if candidates.isEmpty {
            return .missing
        }
        if candidates.count > 1 {
            return .duplicate(candidates)
        }
        let file = candidates[0]
        if let heading = link.heading, !fileContainsHeading(file, in: vaultURL, heading: heading) {
            return .missingHeading(file, heading)
        }
        return .resolved(file)
    }

    private func fileContainsHeading(_ file: FileTreeItem, in vaultURL: URL, heading: String) -> Bool {
        guard let document = try? FileSystemNoteDocumentLoader().loadNote(at: vaultURL, file: file) else {
            return false
        }
        return parseHeadings(document.contents).contains(normalizedHeading(heading))
    }
}

private extension NSRange {
    func contains(_ utf16Offset: Int) -> Bool {
        utf16Offset >= location && utf16Offset < location + length
    }
}

private func targetScheme(_ target: String) -> String? {
    guard let colon = target.firstIndex(of: ":") else {
        return nil
    }
    let colonDistance = target.distance(from: target.startIndex, to: colon)
    let slashDistance = target
        .firstIndex(of: "/")
        .map { target.distance(from: target.startIndex, to: $0) } ?? Int.max
    guard colonDistance <= slashDistance else {
        return nil
    }

    let scheme = String(target[..<colon])
    guard let first = scheme.unicodeScalars.first,
          isASCIIAlpha(first),
          scheme.unicodeScalars.allSatisfy(isSchemeScalar)
    else {
        return nil
    }
    return scheme
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

private func normalizedHeading(_ heading: String) -> String {
    heading.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

private func isASCIIAlpha(_ scalar: UnicodeScalar) -> Bool {
    (65...90).contains(Int(scalar.value)) || (97...122).contains(Int(scalar.value))
}

private func isSchemeScalar(_ scalar: UnicodeScalar) -> Bool {
    isASCIIAlpha(scalar)
        || (48...57).contains(Int(scalar.value))
        || scalar == "+"
        || scalar == "-"
        || scalar == "."
}
