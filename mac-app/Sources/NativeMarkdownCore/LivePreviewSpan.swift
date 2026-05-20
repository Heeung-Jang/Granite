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

public struct LivePreviewInlineSpan: Equatable, Sendable {
    public var kind: LivePreviewInlineKind
    public var sourceRange: LivePreviewSourceRange
    public var tokenRanges: [LivePreviewSourceRange]
    public var isInert: Bool
    public var isEditable: Bool

    public init(
        kind: LivePreviewInlineKind,
        sourceRange: LivePreviewSourceRange,
        tokenRanges: [LivePreviewSourceRange] = [],
        isInert: Bool = false,
        isEditable: Bool = true
    ) {
        self.kind = kind
        self.sourceRange = sourceRange
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
    public var sourceRange: LivePreviewSourceRange
    public var blocks: [LivePreviewBlockSpan]
    public var isPartial: Bool

    public init(
        sourceRange: LivePreviewSourceRange,
        blocks: [LivePreviewBlockSpan],
        isPartial: Bool = false
    ) {
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
    public private(set) var entries: [LivePreviewSourceRange: LivePreviewParseResult]

    public init(entries: [LivePreviewSourceRange: LivePreviewParseResult] = [:]) {
        self.entries = entries
    }

    public mutating func store(_ result: LivePreviewParseResult) {
        entries[result.sourceRange] = result
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
        entries = entries.filter { !$0.key.intersects(invalidatedRange) }
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
}
