import Foundation

public enum LivePreviewEmbedSource: Equatable, Sendable {
    case wikiEmbed
    case markdownImage
}

public struct LivePreviewEmbedSize: Equatable, Sendable {
    public var width: Int
    public var height: Int?

    public init(width: Int, height: Int? = nil) {
        self.width = max(1, width)
        self.height = height.map { max(1, $0) }
    }
}

public struct LivePreviewEmbedSpan: Equatable, Sendable {
    public var source: LivePreviewEmbedSource
    public var sourceRange: LivePreviewSourceRange
    public var targetRange: LivePreviewSourceRange
    public var rawTarget: String
    public var requestedSize: LivePreviewEmbedSize?
    public var tokenRanges: [LivePreviewSourceRange]

    public init(
        source: LivePreviewEmbedSource,
        sourceRange: LivePreviewSourceRange,
        targetRange: LivePreviewSourceRange,
        rawTarget: String,
        requestedSize: LivePreviewEmbedSize? = nil,
        tokenRanges: [LivePreviewSourceRange] = []
    ) {
        self.source = source
        self.sourceRange = sourceRange
        self.targetRange = targetRange
        self.rawTarget = rawTarget
        self.requestedSize = requestedSize
        self.tokenRanges = tokenRanges
    }
}

public enum LivePreviewEmbedPreviewStatus: Equatable, Sendable {
    case pending
    case imageReady
    case blocked(AttachmentPreviewBlockReason)
    case nonImage
}

public struct LivePreviewEmbedPreview: Equatable, Sendable {
    public var span: LivePreviewEmbedSpan
    public var status: LivePreviewEmbedPreviewStatus

    public init(span: LivePreviewEmbedSpan, status: LivePreviewEmbedPreviewStatus) {
        self.span = span
        self.status = status
    }
}

fileprivate struct LivePreviewEmbedPreviewPair: Equatable, Sendable {
    var blockRange: LivePreviewSourceRange
    var span: LivePreviewEmbedSpan
    var referenceID: String
}

private struct LivePreviewEmbedReferenceKey: Hashable {
    var source: AttachmentReferenceSource
    var rawTarget: String
}

public struct LivePreviewEmbedPreviewPlan: Equatable, Sendable {
    fileprivate var pairs: [LivePreviewEmbedPreviewPair]

    public init(source: String, references: [AttachmentReferenceItem]) {
        self.pairs = Self.previewPairs(source: source, references: references)
    }

    public var referenceIDs: Set<String> {
        Set(pairs.map(\.referenceID))
    }

    public func previewMap(previewStatesByID: [String: AttachmentPreviewState]) -> LivePreviewEmbedPreviewMap {
        LivePreviewEmbedPreviewMap(previewPairs: pairs, previewStatesByID: previewStatesByID)
    }

    private static func previewPairs(
        source: String,
        references: [AttachmentReferenceItem]
    ) -> [LivePreviewEmbedPreviewPair] {
        let parsed = LivePreviewParser.parse(source)
        let frontmatterRange = parsed.blocks.first { block in
            if case .frontmatter = block.kind {
                return true
            }
            return false
        }?.sourceRange
        let embedBlocks = parsed.blocks.filter { $0.kind == .embed }
        let spans = LivePreviewEmbedParser.parse(source).filter { span in
            guard let frontmatterRange else {
                return true
            }
            return !frontmatterRange.intersects(span.sourceRange)
        }
        let previewReferences = references.filter {
            $0.source == .wikiEmbed || $0.source == .markdownImage
        }
        var referencesByKey = Dictionary(grouping: previewReferences) {
            LivePreviewEmbedReferenceKey(
                source: $0.source,
                rawTarget: normalizedReferenceTarget(source: $0.source, rawTarget: $0.rawTarget)
            )
        }

        return spans.compactMap { span in
            guard let block = embedBlocks.first(where: { contains($0.sourceRange, span.sourceRange) }) else {
                return nil
            }
            let key = referenceKey(for: span)
            guard var references = referencesByKey[key],
                  !references.isEmpty
            else {
                return nil
            }
            let reference = references.removeFirst()
            referencesByKey[key] = references
            return LivePreviewEmbedPreviewPair(
                blockRange: block.sourceRange,
                span: span,
                referenceID: reference.id
            )
        }
    }

    private static func contains(_ outer: LivePreviewSourceRange, _ inner: LivePreviewSourceRange) -> Bool {
        inner.location >= outer.location && inner.endLocation <= outer.endLocation
    }

    private static func referenceKey(for span: LivePreviewEmbedSpan) -> LivePreviewEmbedReferenceKey {
        let source: AttachmentReferenceSource = span.source == .wikiEmbed ? .wikiEmbed : .markdownImage
        return LivePreviewEmbedReferenceKey(
            source: source,
            rawTarget: normalizedReferenceTarget(source: source, rawTarget: span.rawTarget)
        )
    }

    private static func normalizedReferenceTarget(
        source: AttachmentReferenceSource,
        rawTarget: String
    ) -> String {
        let trimmed = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard source == .wikiEmbed else {
            return trimmed
        }
        return trimmed
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct LivePreviewEmbedPreviewMap: Equatable, Sendable {
    private var previewsByBlockRange: [LivePreviewSourceRange: LivePreviewEmbedPreview]

    public init(previewsByBlockRange: [LivePreviewSourceRange: LivePreviewEmbedPreview] = [:]) {
        self.previewsByBlockRange = previewsByBlockRange
    }

    public init(
        source: String,
        references: [AttachmentReferenceItem],
        previewStatesByID: [String: AttachmentPreviewState]
    ) {
        self = LivePreviewEmbedPreviewPlan(source: source, references: references)
            .previewMap(previewStatesByID: previewStatesByID)
    }

    fileprivate init(
        previewPairs: [LivePreviewEmbedPreviewPair],
        previewStatesByID: [String: AttachmentPreviewState]
    ) {
        var previews: [LivePreviewSourceRange: LivePreviewEmbedPreview] = [:]

        for pair in previewPairs {
            let status = previewStatesByID[pair.referenceID].map { state in
                Self.status(for: state)
            } ?? .pending
            previews[pair.blockRange] = LivePreviewEmbedPreview(span: pair.span, status: status)
        }
        self.init(previewsByBlockRange: previews)
    }

    public var isEmpty: Bool {
        previewsByBlockRange.isEmpty
    }

    public func preview(for block: LivePreviewBlockSpan) -> LivePreviewEmbedPreview? {
        guard block.kind == .embed else {
            return nil
        }
        return previewsByBlockRange[block.sourceRange]
    }

    private static func status(for state: AttachmentPreviewState) -> LivePreviewEmbedPreviewStatus {
        switch state {
        case .eligible:
            .imageReady
        case .blocked(let reason):
            switch reason {
            case .unsupportedResolution, .unsupportedType:
                .nonImage
            default:
                .blocked(reason)
            }
        }
    }
}

public enum LivePreviewEmbedParser {
    public static func parse(_ source: String) -> [LivePreviewEmbedSpan] {
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return (wikiEmbeds(in: source, range: range) + markdownImages(in: source, range: range))
            .sorted { $0.sourceRange.location < $1.sourceRange.location }
    }

    private static func wikiEmbeds(in source: String, range: NSRange) -> [LivePreviewEmbedSpan] {
        wikiEmbedRegex.matches(in: source, range: range).compactMap { match in
            guard let contentRange = Range(match.range(at: 1), in: source) else {
                return nil
            }
            let parsed = parseWikiContent(String(source[contentRange]))
            let targetUpper = source.index(contentRange.lowerBound, offsetBy: parsed.rawTarget.count)
            var tokenRanges = [
                LivePreviewSourceRange(location: match.range.location, length: 3),
                LivePreviewSourceRange(location: match.range.location + match.range.length - 2, length: 2)
            ]
            if targetUpper < contentRange.upperBound {
                tokenRanges.append(LivePreviewRangeMapper.sourceRange(for: targetUpper..<contentRange.upperBound, in: source))
            }
            return LivePreviewEmbedSpan(
                source: .wikiEmbed,
                sourceRange: LivePreviewSourceRange(location: match.range.location, length: match.range.length),
                targetRange: LivePreviewRangeMapper.sourceRange(for: contentRange.lowerBound..<targetUpper, in: source),
                rawTarget: parsed.rawTarget,
                requestedSize: parsed.requestedSize,
                tokenRanges: tokenRanges
            )
        }
    }

    private static func markdownImages(in source: String, range: NSRange) -> [LivePreviewEmbedSpan] {
        markdownImageRegex.matches(in: source, range: range).compactMap { match in
            guard let targetRange = Range(match.range(at: 1), in: source) else {
                return nil
            }
            return LivePreviewEmbedSpan(
                source: .markdownImage,
                sourceRange: LivePreviewSourceRange(location: match.range.location, length: match.range.length),
                targetRange: LivePreviewRangeMapper.sourceRange(for: targetRange, in: source),
                rawTarget: String(source[targetRange]),
                tokenRanges: markdownImageTokenRanges(match: match)
            )
        }
    }

    private static func parseWikiContent(_ raw: String) -> (rawTarget: String, requestedSize: LivePreviewEmbedSize?) {
        let parts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let target = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedSize = parts.count > 1 ? parseSize(String(parts[1])) : nil
        return (target, requestedSize)
    }

    private static func parseSize(_ raw: String) -> LivePreviewEmbedSize? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let width = Int(trimmed), width > 0 {
            return LivePreviewEmbedSize(width: width)
        }
        let parts = trimmed.split(separator: "x", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let width = Int(parts[0]),
              let height = Int(parts[1]),
              width > 0,
              height > 0
        else {
            return nil
        }
        return LivePreviewEmbedSize(width: width, height: height)
    }

    private static func markdownImageTokenRanges(match: NSTextCheckingResult) -> [LivePreviewSourceRange] {
        [
            LivePreviewSourceRange(location: match.range.location, length: 2),
            LivePreviewSourceRange(location: match.range(at: 1).location - 2, length: 2)
        ]
    }

    private static let wikiEmbedRegex = regex(#"!\[\[([^\]\n]+)\]\]"#)
    private static let markdownImageRegex = regex(#"!\[[^\]\n]*\]\(([^)\s]+)(?:\s+[^)]*)?\)"#)

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }
}

public enum LivePreviewMetadataFreshness {
    public static func accepts(candidateContents: String, currentContents: String) -> Bool {
        candidateContents == currentContents
    }
}
