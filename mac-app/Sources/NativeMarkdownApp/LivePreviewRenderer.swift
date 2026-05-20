import AppKit
import Foundation
import NativeMarkdownCore

@MainActor
enum LivePreviewRenderer {
    @discardableResult
    static func render(
        in textView: NSTextView,
        range requestedRange: NSRange? = nil,
        mode: LivePreviewMode = .livePreview,
        revealRange: NSRange? = nil
    ) -> MarkdownDecorationResult {
        let start = DispatchTime.now().uptimeNanoseconds
        if textView.hasMarkedText() {
            return MarkdownDecorationResult(
                mode: "marked-text-deferred",
                reason: nil,
                rangeLength: 0,
                appliedRuns: 0,
                changedRangeCount: 0,
                changedUTF16Length: 0,
                elapsedMilliseconds: elapsedMilliseconds(since: start)
            )
        }

        if mode.rendersSourceOnly {
            return applySourceMode(in: textView, range: requestedRange, mode: mode, start: start)
        }

        let text = textView.string as NSString
        let visibleRange = clamped(requestedRange ?? inferredVisibleRange(in: textView), length: text.length)
        guard visibleRange.length > 0, let storage = textView.textStorage else {
            return MarkdownDecorationResult(
                mode: "live-preview",
                reason: nil,
                rangeLength: 0,
                appliedRuns: 0,
                changedRangeCount: 0,
                changedUTF16Length: 0,
                elapsedMilliseconds: elapsedMilliseconds(since: start)
            )
        }

        let selection = textView.selectedRange()
        let resolvedRevealRange = revealRange ?? selection
        let result = storage.withPreservedSelection(textView: textView, textLength: text.length) {
            var changes = AttributeChangeCounter()
            changes.apply(
                baseAttributes(),
                to: storage,
                range: visibleRange
            )
            renderBlocks(
                source: textView.string,
                storage: storage,
                visibleRange: visibleRange,
                revealRange: resolvedRevealRange,
                changes: &changes
            )
            return changes
        }
        textView.setSelectedRange(clamped(selection, length: text.length))

        return MarkdownDecorationResult(
            mode: "live-preview",
            reason: nil,
            rangeLength: visibleRange.length,
            appliedRuns: result.appliedRuns,
            changedRangeCount: result.changedRangeCount,
            changedUTF16Length: result.changedUTF16Length,
            elapsedMilliseconds: elapsedMilliseconds(since: start)
        )
    }

    private static func applySourceMode(
        in textView: NSTextView,
        range requestedRange: NSRange?,
        mode: LivePreviewMode,
        start: UInt64
    ) -> MarkdownDecorationResult {
        let text = textView.string as NSString
        let visibleRange = clamped(requestedRange ?? inferredVisibleRange(in: textView), length: text.length)
        guard visibleRange.length > 0, let storage = textView.textStorage else {
            return MarkdownDecorationResult(
                mode: resultMode(for: mode),
                reason: fallbackReason(for: mode),
                rangeLength: 0,
                appliedRuns: 0,
                changedRangeCount: 0,
                changedUTF16Length: 0,
                elapsedMilliseconds: elapsedMilliseconds(since: start)
            )
        }

        let selection = textView.selectedRange()
        let changes = storage.withPreservedSelection(textView: textView, textLength: text.length) {
            var changes = AttributeChangeCounter()
            changes.apply(sourceAttributes(), to: storage, range: visibleRange)
            return changes
        }
        textView.setSelectedRange(clamped(selection, length: text.length))

        return MarkdownDecorationResult(
            mode: resultMode(for: mode),
            reason: fallbackReason(for: mode),
            rangeLength: visibleRange.length,
            appliedRuns: 0,
            changedRangeCount: changes.changedRangeCount,
            changedUTF16Length: changes.changedUTF16Length,
            elapsedMilliseconds: elapsedMilliseconds(since: start)
        )
    }

    private static func renderBlocks(
        source: String,
        storage: NSTextStorage,
        visibleRange: NSRange,
        revealRange: NSRange,
        changes: inout AttributeChangeCounter
    ) {
        let parseWindow = LivePreviewVisibleParseWindow.window(
            in: source,
            visibleRange: LivePreviewSourceRange(location: visibleRange.location, length: visibleRange.length),
            paddingLines: 2,
            maxUTF16Length: max(visibleRange.length + 4_096, 8_192)
        )
        let parsed = LivePreviewParser.parse(source, in: parseWindow)
        for block in parsed.blocks {
            let blockRange = NSIntersectionRange(block.sourceRange.nsRange, visibleRange)
            guard blockRange.length > 0 else {
                continue
            }
            applyBlockAttributes(block, storage: storage, range: blockRange, changes: &changes)
            applyInlineAttributes(block, storage: storage, visibleRange: visibleRange, changes: &changes)
            concealTokens(block, source: source, storage: storage, visibleRange: visibleRange, revealRange: revealRange, changes: &changes)
        }
    }

    private static func applyBlockAttributes(
        _ block: LivePreviewBlockSpan,
        storage: NSTextStorage,
        range: NSRange,
        changes: inout AttributeChangeCounter
    ) {
        switch block.kind {
        case .heading(let level):
            changes.apply([
                .font: LivePreviewTheme.headingFont(level: level),
                .foregroundColor: LivePreviewTheme.textColor
            ], to: storage, range: range)
        case .blockquote:
            changes.apply([.foregroundColor: LivePreviewTheme.quoteColor], to: storage, range: range)
        case .callout:
            changes.apply([.foregroundColor: LivePreviewTheme.quoteColor], to: storage, range: range)
        case .fencedCode:
            changes.apply([
                .font: LivePreviewTheme.codeFont,
                .foregroundColor: LivePreviewTheme.codeColor
            ], to: storage, range: range)
        case .table:
            changes.apply([.font: LivePreviewTheme.codeFont], to: storage, range: range)
        case .embed:
            changes.apply([.foregroundColor: LivePreviewTheme.secondaryTextColor], to: storage, range: range)
        case .unorderedList, .orderedList, .taskList:
            changes.apply([.foregroundColor: LivePreviewTheme.textColor], to: storage, range: range)
        case .frontmatter:
            changes.apply([.foregroundColor: LivePreviewTheme.secondaryTextColor], to: storage, range: range)
        case .paragraph:
            break
        }
    }

    private static func applyInlineAttributes(
        _ block: LivePreviewBlockSpan,
        storage: NSTextStorage,
        visibleRange: NSRange,
        changes: inout AttributeChangeCounter
    ) {
        for inline in block.inlineSpans {
            let range = NSIntersectionRange(inline.sourceRange.nsRange, visibleRange)
            guard range.length > 0 else {
                continue
            }
            switch inline.kind {
            case .strong:
                changes.apply([.font: LivePreviewTheme.strongFont], to: storage, range: range)
            case .emphasis:
                changes.apply([.obliqueness: 0.12], to: storage, range: range)
            case .inlineCode:
                changes.apply([
                    .font: LivePreviewTheme.codeFont,
                    .foregroundColor: LivePreviewTheme.codeColor
                ], to: storage, range: range)
            case .wikiLink, .markdownLink:
                changes.apply([.foregroundColor: LivePreviewTheme.linkColor], to: storage, range: range)
            case .tag:
                changes.apply([.foregroundColor: LivePreviewTheme.tagColor], to: storage, range: range)
            }
        }
    }

    private static func concealTokens(
        _ block: LivePreviewBlockSpan,
        source: String,
        storage: NSTextStorage,
        visibleRange: NSRange,
        revealRange: NSRange,
        changes: inout AttributeChangeCounter
    ) {
        guard !block.sourceRange.nsRange.intersects(revealRange) else {
            return
        }

        for range in concealmentRanges(for: block, source: source) {
            let range = NSIntersectionRange(range, visibleRange)
            guard range.length > 0 else {
                continue
            }
            changes.apply([
                .foregroundColor: LivePreviewTheme.concealedColor
            ], to: storage, range: range)
        }
    }

    private static func concealmentRanges(for block: LivePreviewBlockSpan, source: String) -> [NSRange] {
        switch block.kind {
        case .heading:
            return prefixMatches(in: source, block: block, pattern: #"^#{1,6}\s"#)
        case .unorderedList:
            return prefixMatches(in: source, block: block, pattern: #"^\s*[-*+]\s"#)
        case .orderedList:
            return prefixMatches(in: source, block: block, pattern: #"^\s*\d+[.)]\s"#)
        case .taskList:
            return prefixMatches(in: source, block: block, pattern: #"^\s*[-*+]\s+\[[ xX]\]\s"#)
        case .blockquote:
            return prefixMatches(in: source, block: block, pattern: #"^\s*>\s?"#)
        case .callout:
            return prefixMatches(in: source, block: block, pattern: #"^\s*>\s?\[![^\]\n]+\]\s?"#)
        case .table:
            return matches(in: source, range: block.sourceRange.nsRange, pattern: #"\|"#)
        case .embed:
            return matches(in: source, range: block.sourceRange.nsRange, pattern: #"!\[\[|\]\]|!\[|\]\([^\)\n]+\)"#)
        case .paragraph:
            return inlineTokenRanges(block.inlineSpans, source: source)
        case .frontmatter, .fencedCode:
            return []
        }
    }

    private static func inlineTokenRanges(_ inlineSpans: [LivePreviewInlineSpan], source: String) -> [NSRange] {
        inlineSpans.flatMap { span in
            switch span.kind {
            case .strong:
                return edgeRanges(span.sourceRange.nsRange, tokenLength: 2)
            case .emphasis, .inlineCode:
                return edgeRanges(span.sourceRange.nsRange, tokenLength: 1)
            case .wikiLink:
                return matches(in: source, range: span.sourceRange.nsRange, pattern: #"!?\[\[|\]\]"#)
            case .markdownLink:
                return matches(in: source, range: span.sourceRange.nsRange, pattern: #"!?\[|\]\([^\)\n]+\)"#)
            case .tag:
                return []
            }
        }
    }

    private static func edgeRanges(_ range: NSRange, tokenLength: Int) -> [NSRange] {
        guard range.length >= tokenLength * 2 else {
            return []
        }
        return [
            NSRange(location: range.location, length: tokenLength),
            NSRange(location: range.location + range.length - tokenLength, length: tokenLength)
        ]
    }

    private static func prefixMatches(in source: String, block: LivePreviewBlockSpan, pattern: String) -> [NSRange] {
        matches(in: source, range: block.sourceRange.nsRange, pattern: pattern)
    }

    private static func matches(in source: String, range: NSRange, pattern: String) -> [NSRange] {
        let regex = try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        return regex.matches(in: source, range: range).map(\.range)
    }

    private static func baseAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: LivePreviewTheme.baseFont,
            .foregroundColor: LivePreviewTheme.textColor
        ]
    }

    private static func sourceAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: LivePreviewTheme.sourceFont,
            .foregroundColor: LivePreviewTheme.textColor
        ]
    }

    private static func resultMode(for mode: LivePreviewMode) -> String {
        switch mode {
        case .livePreview:
            return "live-preview"
        case .source:
            return "source"
        case .fallbackSource:
            return "fallback-source"
        }
    }

    private static func fallbackReason(for mode: LivePreviewMode) -> String? {
        if case .fallbackSource(let reason) = mode {
            return reason.rawValue
        }
        return nil
    }

    private static func inferredVisibleRange(in textView: NSTextView) -> NSRange {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return NSRange(location: 0, length: (textView.string as NSString).length)
        }

        let glyphRange = layoutManager.glyphRange(
            forBoundingRect: textView.visibleRect,
            in: textContainer
        )
        return layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
    }

    private static func clamped(_ range: NSRange, length: Int) -> NSRange {
        let location = min(range.location, length)
        let maxLength = max(0, length - location)
        return NSRange(location: location, length: min(range.length, maxLength))
    }

    private static func elapsedMilliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
}

private struct AttributeChangeCounter {
    var appliedRuns = 0
    var changedRangeCount = 0
    var changedUTF16Length = 0

    mutating func apply(
        _ attributes: [NSAttributedString.Key: Any],
        to storage: NSTextStorage,
        range: NSRange
    ) {
        guard range.length > 0 else {
            return
        }
        storage.addAttributes(attributes, range: range)
        appliedRuns += 1
        changedRangeCount += 1
        changedUTF16Length += range.length
    }
}

private extension NSTextStorage {
    @MainActor
    func withPreservedSelection<T>(
        textView: NSTextView,
        textLength: Int,
        _ body: () -> T
    ) -> T {
        let selection = textView.selectedRange()
        beginEditing()
        let value = body()
        endEditing()
        textView.setSelectedRange(NSRange(
            location: min(selection.location, textLength),
            length: min(selection.length, max(0, textLength - min(selection.location, textLength)))
        ))
        return value
    }
}

private extension NSRange {
    func intersects(_ other: NSRange) -> Bool {
        location < other.location + other.length && other.location < location + length
    }
}
