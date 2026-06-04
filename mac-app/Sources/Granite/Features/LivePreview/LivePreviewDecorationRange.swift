import AppKit
import Foundation
import NativeMarkdownCore

@MainActor
enum LivePreviewTextViewRange {
    static func inferredVisibleRange(in textView: NSTextView) -> NSRange {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else {
            return NSRange(location: 0, length: (textView.string as NSString).length)
        }

        let glyphRange = layoutManager.glyphRange(
            forBoundingRect: textView.visibleRect,
            in: textContainer
        )
        return layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
    }

    static func clamped(_ range: NSRange, documentLength: Int) -> NSRange {
        let location = min(max(0, range.location), documentLength)
        let maxLength = max(0, documentLength - location)
        return NSRange(location: location, length: min(max(0, range.length), maxLength))
    }
}

@MainActor
enum LivePreviewActiveRevealRange {
    static func activeBlockRange(source: String, selection: NSRange) -> NSRange? {
        guard let resolved = activeBlock(source: source, selection: selection) else {
            return nil
        }
        return resolved.sourceRange.nsRange
    }

    private static func activeBlock(
        source: String,
        selection: NSRange
    ) -> LivePreviewBlockSpan? {
        let documentLength = (source as NSString).length
        guard documentLength > 0 else {
            return nil
        }
        let selection = LivePreviewTextViewRange.clamped(selection, documentLength: documentLength)
        let blocks = LivePreviewParser.parse(source).blocks
        return blocks.first { $0.sourceRange.nsRange.intersectsOrContainsCaret(selection) }
    }
}

@MainActor
enum LivePreviewDecorationInvalidationRange {
    static let minimumMaxExpansionLength = 24_576
    static let visibleExpansionPadding = 16_384

    static func expandedVisibleRange(
        in textView: NSTextView,
        previousActiveRange: NSRange?,
        currentActiveRange: NSRange?
    ) -> NSRange {
        let documentLength = (textView.string as NSString).length
        let visibleRange = LivePreviewTextViewRange.clamped(
            LivePreviewTextViewRange.inferredVisibleRange(in: textView),
            documentLength: documentLength
        )
        let maxExpansionLength = max(visibleRange.length + visibleExpansionPadding, minimumMaxExpansionLength)
        return union(
            visibleRange: visibleRange,
            previousActiveRange: previousActiveRange,
            currentActiveRange: currentActiveRange,
            documentLength: documentLength,
            maxExpansionLength: maxExpansionLength
        )
    }

    static func union(
        visibleRange: NSRange,
        previousActiveRange: NSRange?,
        currentActiveRange: NSRange?,
        documentLength: Int,
        maxExpansionLength: Int
    ) -> NSRange {
        let visibleRange = LivePreviewTextViewRange.clamped(visibleRange, documentLength: documentLength)
        let currentActiveRange = valid(currentActiveRange, documentLength: documentLength)
        let previousActiveRange = valid(previousActiveRange, documentLength: documentLength)
        let fullUnion = unionRange([visibleRange, currentActiveRange, previousActiveRange])
        if fullUnion.length <= maxExpansionLength {
            return fullUnion
        }
        let currentUnion = unionRange([visibleRange, currentActiveRange])
        if currentUnion.length <= maxExpansionLength {
            return currentUnion
        }
        return visibleRange
    }

    private static func valid(_ range: NSRange?, documentLength: Int) -> NSRange? {
        guard let range else {
            return nil
        }
        let clamped = LivePreviewTextViewRange.clamped(range, documentLength: documentLength)
        guard clamped.length > 0 else {
            return nil
        }
        return clamped
    }

    private static func unionRange(_ ranges: [NSRange?]) -> NSRange {
        let ranges = ranges.compactMap { $0 }
        guard let first = ranges.first else {
            return NSRange(location: 0, length: 0)
        }
        var lower = first.location
        var upper = first.upperBound
        for range in ranges.dropFirst() {
            lower = min(lower, range.location)
            upper = max(upper, range.upperBound)
        }
        return NSRange(location: lower, length: max(0, upper - lower))
    }
}

private extension NSRange {
    var upperBound: Int {
        location + length
    }

    func intersectsOrContainsCaret(_ other: NSRange) -> Bool {
        if other.length == 0 {
            return other.location >= location && other.location < upperBound
        }
        return location < other.upperBound && other.location < upperBound
    }
}
