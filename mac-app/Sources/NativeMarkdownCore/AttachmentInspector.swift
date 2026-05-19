import Foundation

public enum AttachmentReferenceSource: String, Equatable, Sendable {
    case wikiEmbed
    case markdownImage
    case markdownLink
}

public enum AttachmentRejectReason: String, Equatable, Sendable {
    case containsNul
    case urlScheme
    case tildePrefix
    case absolutePath
    case outsideVault
    case symlinkEscape
    case invalidRoot
}

public enum AttachmentResolutionState: Equatable, Sendable {
    case resolved(FileTreeItem)
    case missing
    case unreadable(FileTreeItem)
    case duplicate([FileTreeItem])
    case remote
    case rejected(AttachmentRejectReason)
    case unsupported
}

public struct AttachmentReferenceItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let source: AttachmentReferenceSource
    public let rawTarget: String
    public let state: AttachmentResolutionState

    public init(
        id: String,
        source: AttachmentReferenceSource,
        rawTarget: String,
        state: AttachmentResolutionState
    ) {
        self.id = id
        self.source = source
        self.rawTarget = rawTarget
        self.state = state
    }
}

public enum AttachmentReferenceLoadError: Error, Equatable {
    case cannotEnumerate(URL)
}

public struct FileSystemAttachmentReferenceLoader: Sendable {
    public init() {}

    public func loadAttachments(
        at vaultURL: URL,
        file: FileTreeItem,
        contents: String
    ) throws -> [AttachmentReferenceItem] {
        let rootURL = vaultURL.standardizedFileURL
        let references = parseAttachmentReferences(in: bodyWithoutFrontmatter(contents))
        guard !references.isEmpty else {
            return []
        }

        let candidates = references.contains(where: needsVaultAttachmentScan)
            ? try scanAttachmentCandidates(at: rootURL)
            : []
        let resolver = AttachmentResolver(rootURL: rootURL, candidates: candidates)

        return references.enumerated()
            .map { index, reference in
                AttachmentReferenceItem(
                    id: "\(index)-\(reference.source.rawValue)-\(reference.rawTarget)",
                    source: reference.source,
                    rawTarget: reference.rawTarget,
                    state: resolver.resolve(reference, from: file)
                )
            }
    }

    private func scanAttachmentCandidates(at rootURL: URL) throws -> [AttachmentCandidate] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else {
            throw AttachmentReferenceLoadError.cannotEnumerate(rootURL)
        }

        var candidates: [AttachmentCandidate] = []
        for case let fileURL as URL in enumerator {
            guard let relativePath = relativePath(for: fileURL, under: rootURL) else {
                continue
            }

            let resourceValues = try? fileURL.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            if resourceValues?.isDirectory == true, shouldSkipDirectory(relativePath) {
                enumerator.skipDescendants()
                continue
            }

            guard resourceValues?.isSymbolicLink != true,
                  resourceValues?.isRegularFile == true,
                  isAttachmentPath(relativePath),
                  !shouldSkipPath(relativePath)
            else {
                continue
            }

            candidates.append(
                AttachmentCandidate(
                    file: FileTreeItem(relativePath: relativePath),
                    isReadable: fileManager.isReadableFile(atPath: fileURL.path)
                )
            )
        }

        return candidates.sorted {
            $0.file.relativePath.localizedStandardCompare($1.file.relativePath) == .orderedAscending
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
}

private struct RawAttachmentReference {
    let source: AttachmentReferenceSource
    let rawTarget: String
    let position: Int
}

private struct AttachmentCandidate {
    let file: FileTreeItem
    let isReadable: Bool
}

private struct AttachmentResolver {
    let rootURL: URL
    let candidatesByPath: [String: AttachmentCandidate]
    let candidatesByName: [String: [AttachmentCandidate]]

    init(rootURL: URL, candidates: [AttachmentCandidate]) {
        self.rootURL = rootURL
        var candidatesByPath: [String: AttachmentCandidate] = [:]
        for candidate in candidates {
            candidatesByPath[lookupKey(candidate.file.relativePath)] = candidate
        }
        self.candidatesByPath = candidatesByPath
        self.candidatesByName = Dictionary(grouping: candidates) { candidate in
            lookupKey((candidate.file.relativePath as NSString).lastPathComponent)
        }
    }

    func resolve(_ reference: RawAttachmentReference, from file: FileTreeItem) -> AttachmentResolutionState {
        let target = reference.rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = targetScheme(target) {
            return ["http", "https"].contains(scheme.lowercased()) ? .remote : .rejected(.urlScheme)
        }

        switch reference.source {
        case .wikiEmbed:
            if !target.contains("/") {
                return resolveByBasename(target)
            }
            return resolveExactRelative(target)
        case .markdownImage, .markdownLink:
            let targetPath = target.split(separator: "#", maxSplits: 1).first.map(String.init) ?? target
            let relativeTarget = file.parentPath.isEmpty ? targetPath : "\(file.parentPath)/\(targetPath)"
            return resolveExactRelative(relativeTarget)
        }
    }

    private func resolveByBasename(_ target: String) -> AttachmentResolutionState {
        if target.contains("\u{0}") {
            return .rejected(.containsNul)
        }
        if target.hasPrefix("~") {
            return .rejected(.tildePrefix)
        }
        guard isAttachmentPath(target) else {
            return .unsupported
        }

        let key = lookupKey((target as NSString).lastPathComponent)
        guard let candidates = candidatesByName[key], !candidates.isEmpty else {
            return normalizedRelativePath(target).map { _ in .missing } ?? .rejected(.invalidRoot)
        }
        if candidates.count > 1 {
            return .duplicate(candidates.map(\.file))
        }
        return state(for: candidates[0])
    }

    private func resolveExactRelative(_ target: String) -> AttachmentResolutionState {
        guard let normalized = normalizedRelativePath(target) else {
            return .rejected(rejectReason(for: target))
        }
        guard isAttachmentPath(normalized) else {
            return .unsupported
        }

        if let candidate = candidatesByPath[lookupKey(normalized)] {
            return state(for: candidate)
        }

        let fileURL = rootURL.appendingPathComponent(normalized)
        let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        if resourceValues?.isSymbolicLink == true {
            return .rejected(.symlinkEscape)
        }
        if resourceValues?.isRegularFile == true {
            let file = FileTreeItem(relativePath: normalized)
            return FileManager.default.isReadableFile(atPath: fileURL.path) ? .resolved(file) : .unreadable(file)
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return .unsupported
        }
        return .missing
    }

    private func state(for candidate: AttachmentCandidate) -> AttachmentResolutionState {
        candidate.isReadable ? .resolved(candidate.file) : .unreadable(candidate.file)
    }
}

private func parseAttachmentReferences(in contents: String) -> [RawAttachmentReference] {
    (parseWikiEmbeds(in: contents) + parseMarkdownAttachmentReferences(in: contents))
        .sorted { $0.position < $1.position }
}

private func parseWikiEmbeds(in contents: String) -> [RawAttachmentReference] {
    let pattern = #"!\[\[([^\]]+)\]\]"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return []
    }
    let nsRange = NSRange(contents.startIndex..<contents.endIndex, in: contents)
    return regex.matches(in: contents, range: nsRange).compactMap { match in
        guard let range = Range(match.range(at: 1), in: contents),
              let target = parseWikiTarget(String(contents[range]))
        else {
            return nil
        }
        return RawAttachmentReference(
            source: .wikiEmbed,
            rawTarget: target,
            position: match.range.location
        )
    }
}

private func parseMarkdownAttachmentReferences(in contents: String) -> [RawAttachmentReference] {
    let pattern = #"(!?)\[[^\]]*\]\(([^)\s]+)(?:\s+[^)]*)?\)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return []
    }
    let nsRange = NSRange(contents.startIndex..<contents.endIndex, in: contents)
    return regex.matches(in: contents, range: nsRange).compactMap { match in
        guard let imageRange = Range(match.range(at: 1), in: contents),
              let targetRange = Range(match.range(at: 2), in: contents)
        else {
            return nil
        }
        let target = String(contents[targetRange])
        let isImage = !contents[imageRange].isEmpty
        guard shouldIncludeMarkdownReference(target: target, isImage: isImage) else {
            return nil
        }
        return RawAttachmentReference(
            source: isImage ? .markdownImage : .markdownLink,
            rawTarget: target,
            position: match.range.location
        )
    }
}

private func parseWikiTarget(_ raw: String) -> String? {
    let targetPart = raw
        .split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)[0]
        .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return targetPart.isEmpty ? nil : targetPart
}

private func shouldIncludeMarkdownReference(target: String, isImage: Bool) -> Bool {
    if isImage {
        return true
    }
    if let scheme = targetScheme(target) {
        return !["http", "https"].contains(scheme.lowercased())
    }
    let targetPath = target.split(separator: "#", maxSplits: 1).first.map(String.init) ?? target
    return isAttachmentPath(targetPath)
}

private func needsVaultAttachmentScan(_ reference: RawAttachmentReference) -> Bool {
    guard reference.source == .wikiEmbed else {
        return false
    }
    let target = reference.rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
    return targetScheme(target) == nil
        && !target.contains("/")
        && !target.contains("\u{0}")
        && !target.hasPrefix("~")
        && isAttachmentPath(target)
}

private func normalizedRelativePath(_ rawPath: String) -> String? {
    if rawPath.contains("\u{0}") || targetScheme(rawPath) != nil || rawPath.hasPrefix("~") || rawPath.hasPrefix("/") {
        return nil
    }

    var components: [String] = []
    for part in rawPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init) {
        if part.isEmpty || part == "." {
            continue
        }
        if part == ".." {
            guard !components.isEmpty else {
                return nil
            }
            components.removeLast()
            continue
        }
        components.append(part)
    }
    return components.isEmpty ? nil : components.joined(separator: "/")
}

private func rejectReason(for rawPath: String) -> AttachmentRejectReason {
    if rawPath.contains("\u{0}") {
        return .containsNul
    }
    if targetScheme(rawPath) != nil {
        return .urlScheme
    }
    if rawPath.hasPrefix("~") {
        return .tildePrefix
    }
    if rawPath.hasPrefix("/") {
        return .absolutePath
    }
    if rawPath.split(separator: "/").contains("..") {
        return .outsideVault
    }
    return .invalidRoot
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

private func isAttachmentPath(_ path: String) -> Bool {
    attachmentExtensions.contains((path as NSString).pathExtension.lowercased())
}

private func lookupKey(_ path: String) -> String {
    path.lowercased()
}

private func shouldSkipDirectory(_ relativePath: String) -> Bool {
    guard let name = relativePath.split(separator: "/").last else {
        return false
    }
    return excludedDirectories.contains(String(name))
}

private func shouldSkipPath(_ relativePath: String) -> Bool {
    relativePath
        .split(separator: "/")
        .contains { excludedDirectories.contains(String($0)) }
}

private func bodyWithoutFrontmatter(_ contents: String) -> String {
    guard contents.hasPrefix("---\n") || contents.hasPrefix("---\r\n") else {
        return contents
    }
    let lines = contents.components(separatedBy: .newlines)
    guard let closingIndex = lines.dropFirst().firstIndex(of: "---") else {
        return contents
    }
    return lines.dropFirst(closingIndex + 1).joined(separator: "\n")
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

private let attachmentExtensions: Set<String> = [
    "avif", "bmp", "gif", "jpeg", "jpg", "mov", "mp3", "mp4", "pdf", "png", "svg",
    "tif", "tiff", "wav", "webp", "zip"
]

private let excludedDirectories: Set<String> = [
    ".obsidian",
    ".git",
    ".worktrees",
    ".native-markdown-index"
]
