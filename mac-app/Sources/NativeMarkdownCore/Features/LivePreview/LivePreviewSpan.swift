import Foundation

public enum LivePreviewBlockKind: Equatable, Sendable {
    case frontmatter(isClosed: Bool)
    case heading(level: Int)
    case paragraph
    case fencedCode(fence: String, info: String?, isClosed: Bool)
    case unorderedList
    case orderedList
    case taskList(isChecked: Bool)
    case blockquote
    case callout(kind: String?)
    case table
    case horizontalRule
    case embed
}

public enum LivePreviewInlineKind: Equatable, Sendable {
    case inlineCode
    case strong
    case emphasis
    case wikiLink
    case markdownLink
    case tag
}

public enum LivePreviewLinkStyleState: Equatable, Sendable {
    case unknown
    case resolved
    case missing
    case duplicate
    case missingHeading

    public init(_ state: LinkResolutionState) {
        switch state {
        case .resolved:
            self = .resolved
        case .missing:
            self = .missing
        case .duplicate:
            self = .duplicate
        case .missingHeading:
            self = .missingHeading
        }
    }
}

public struct LivePreviewLinkStyleMap: Equatable, Sendable {
    private var statesByRange: [LivePreviewSourceRange: LivePreviewLinkStyleState]

    public init(statesByRange: [LivePreviewSourceRange: LivePreviewLinkStyleState] = [:]) {
        self.statesByRange = statesByRange
    }

    public init(source: String, outgoingLinks: [OutgoingLinkItem]) {
        let wikiSpans = LivePreviewParser.parse(source)
            .blocks
            .flatMap(\.inlineSpans)
            .filter { $0.kind == .wikiLink }
        var statesByRange: [LivePreviewSourceRange: LivePreviewLinkStyleState] = [:]
        for (span, link) in zip(wikiSpans, outgoingLinks) {
            statesByRange[span.sourceRange] = LivePreviewLinkStyleState(link.state)
        }
        self.init(statesByRange: statesByRange)
    }

    public var isEmpty: Bool {
        statesByRange.isEmpty
    }

    public func state(for span: LivePreviewInlineSpan) -> LivePreviewLinkStyleState {
        switch span.kind {
        case .wikiLink, .markdownLink:
            statesByRange[span.sourceRange] ?? .unknown
        case .inlineCode, .strong, .emphasis, .tag:
            .unknown
        }
    }
}

public struct LivePreviewInlineSpan: Equatable, Sendable {
    public var kind: LivePreviewInlineKind
    public var sourceRange: LivePreviewSourceRange
    public var displayRange: LivePreviewSourceRange?
    public var tokenRanges: [LivePreviewSourceRange]
    public var isInert: Bool
    public var isEditable: Bool

    public init(
        kind: LivePreviewInlineKind,
        sourceRange: LivePreviewSourceRange,
        displayRange: LivePreviewSourceRange? = nil,
        tokenRanges: [LivePreviewSourceRange] = [],
        isInert: Bool = false,
        isEditable: Bool = true
    ) {
        self.kind = kind
        self.sourceRange = sourceRange
        self.displayRange = displayRange
        self.tokenRanges = tokenRanges
        self.isInert = isInert
        self.isEditable = isEditable
    }
}

public struct LivePreviewBlockSpan: Equatable, Sendable {
    public var kind: LivePreviewBlockKind
    public var sourceRange: LivePreviewSourceRange
    public var contentRange: LivePreviewSourceRange
    public var tokenRanges: [LivePreviewSourceRange]
    public var inlineSpans: [LivePreviewInlineSpan]
    public var isInert: Bool
    public var isEditable: Bool

    public init(
        kind: LivePreviewBlockKind,
        sourceRange: LivePreviewSourceRange,
        contentRange: LivePreviewSourceRange,
        tokenRanges: [LivePreviewSourceRange] = [],
        inlineSpans: [LivePreviewInlineSpan] = [],
        isInert: Bool = false,
        isEditable: Bool = true
    ) {
        self.kind = kind
        self.sourceRange = sourceRange
        self.contentRange = contentRange
        self.tokenRanges = tokenRanges
        self.inlineSpans = inlineSpans
        self.isInert = isInert
        self.isEditable = isEditable
    }
}

public struct LivePreviewParseResult: Equatable, Sendable {
    public var sourceVersion: UInt64
    public var sourceRange: LivePreviewSourceRange
    public var blocks: [LivePreviewBlockSpan]
    public var isPartial: Bool

    public init(
        sourceVersion: UInt64 = 0,
        sourceRange: LivePreviewSourceRange,
        blocks: [LivePreviewBlockSpan],
        isPartial: Bool = false
    ) {
        self.sourceVersion = sourceVersion
        self.sourceRange = sourceRange
        self.blocks = blocks
        self.isPartial = isPartial
    }
}

public enum LivePreviewVisibleParseWindow {
    public static func window(
        in source: String,
        visibleRange: LivePreviewSourceRange,
        paddingLines: Int = 2,
        maxUTF16Length: Int = 64 * 1024
    ) -> LivePreviewSourceRange {
        let sourceLength = (source as NSString).length
        let clampedVisible = LivePreviewRangeMapper.clamped(visibleRange, in: source)
        if sourceLength > maxUTF16Length {
            let visibleLength = min(clampedVisible.length, maxUTF16Length)
            let beforeBudget = max(0, (maxUTF16Length - visibleLength) / 2)
            var lower = max(0, clampedVisible.location - beforeBudget)
            var upper = min(sourceLength, lower + maxUTF16Length)
            if upper < clampedVisible.endLocation {
                upper = min(sourceLength, clampedVisible.endLocation)
                lower = max(0, upper - maxUTF16Length)
            }
            return LivePreviewSourceRange(location: lower, length: upper - lower)
        }
        guard let visibleStringRange = LivePreviewRangeMapper.stringRange(for: clampedVisible, in: source) else {
            return LivePreviewSourceRange(location: 0, length: min(sourceLength, maxUTF16Length))
        }

        var lower = source.lineRange(for: visibleStringRange).lowerBound
        var upper = source.lineRange(for: visibleStringRange).upperBound

        for _ in 0..<max(0, paddingLines) {
            if lower > source.startIndex {
                let previousUpper = source.index(before: lower)
                lower = source.lineRange(for: previousUpper..<previousUpper).lowerBound
            }
            if upper < source.endIndex {
                upper = source.lineRange(for: upper..<upper).upperBound
            }
        }

        var expanded = LivePreviewRangeMapper.sourceRange(for: lower..<upper, in: source)
        if expanded.length > maxUTF16Length {
            expanded.length = maxUTF16Length
        }
        return expanded
    }
}

public struct LivePreviewSpanCache: Equatable, Sendable {
    public private(set) var entries: [LivePreviewSpanCacheKey: LivePreviewParseResult]

    public init(entries: [LivePreviewSpanCacheKey: LivePreviewParseResult] = [:]) {
        self.entries = entries
    }

    public mutating func store(_ result: LivePreviewParseResult) {
        entries[LivePreviewSpanCacheKey(
            sourceVersion: result.sourceVersion,
            sourceRange: result.sourceRange
        )] = result
    }

    public func result(
        for sourceRange: LivePreviewSourceRange,
        sourceVersion: UInt64
    ) -> LivePreviewParseResult? {
        entries[LivePreviewSpanCacheKey(sourceVersion: sourceVersion, sourceRange: sourceRange)]
    }

    public mutating func invalidate(
        editedRange: LivePreviewSourceRange,
        neighborUTF16Padding: Int,
        documentUTF16Length: Int
    ) {
        let invalidatedRange = editedRange.expanded(
            by: neighborUTF16Padding,
            limit: documentUTF16Length
        )
        entries = entries.filter { key, _ in
            !key.sourceRange.intersects(invalidatedRange) &&
                key.sourceRange.location < editedRange.location
        }
    }
}

public struct LivePreviewSpanCacheKey: Equatable, Hashable, Sendable {
    public var sourceVersion: UInt64
    public var sourceRange: LivePreviewSourceRange

    public init(sourceVersion: UInt64, sourceRange: LivePreviewSourceRange) {
        self.sourceVersion = sourceVersion
        self.sourceRange = sourceRange
    }
}

public struct LivePreviewRenderVersionGate: Equatable, Sendable {
    public private(set) var currentVersion: UInt64

    public init(currentVersion: UInt64 = 0) {
        self.currentVersion = currentVersion
    }

    @discardableResult
    public mutating func nextVersion() -> UInt64 {
        currentVersion += 1
        return currentVersion
    }

    public func accepts(_ version: UInt64) -> Bool {
        version == currentVersion
    }

    public func accepts(_ result: LivePreviewParseResult) -> Bool {
        accepts(result.sourceVersion)
    }
}
