import AppKit
import Foundation
import NativeMarkdownCore

@MainActor
enum LivePreviewRenderer {
    private static let headingPrefixRegex = regex(#"^#{1,6}\s"#)
    private static let unorderedListPrefixRegex = regex(#"^\s*[-*+]\s"#)
    private static let orderedListPrefixRegex = regex(#"^\s*\d+[.)]\s"#)
    private static let taskListPrefixRegex = regex(#"^\s*[-*+]\s+\[[ xX]\]\s"#)
    private static let taskCheckboxTokenRegex = regex(#"\[[ xX]\]"#)
    private static let blockquotePrefixRegex = regex(#"^\s*>\s?"#)
    private static let calloutPrefixRegex = regex(#"^\s*>\s?\[![^\]\n]+\]\s?"#)
    private static let tablePipeRegex = regex(#"\|"#)
    private static let fenceLineRegex = regex(#"^\s*(```+|~~~+).*$"#)
    private static let wikiEmbedTokenRegex = regex(#"!\[\[|\]\]"#)
    private static let wikiLinkTokenRegex = regex(#"!?\[\[|\]\]"#)

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
        let plan = LivePreviewAttributePlan(
            source: textView.string,
            visibleRange: visibleRange,
            baseAttributes: baseAttributes()
        )
        renderBlocks(
            source: textView.string,
            plan: plan,
            visibleRange: visibleRange,
            revealRange: resolvedRevealRange
        )
        let result = storage.withPreservedSelection(textView: textView, textLength: text.length) {
            var changes = AttributeChangeCounter()
            plan.apply(to: storage, changes: &changes)
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
            changes.replace(sourceAttributes(), to: storage, range: visibleRange)
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
        plan: LivePreviewAttributePlan,
        visibleRange: NSRange,
        revealRange: NSRange
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
            applyBlockAttributes(block, plan: plan, range: blockRange)
            applyBlockTokenAttributes(block, source: source, plan: plan, visibleRange: visibleRange)
            applyInlineAttributes(block, source: source, plan: plan, visibleRange: visibleRange)
            concealTokens(block, source: source, plan: plan, visibleRange: visibleRange, revealRange: revealRange)
        }
    }

    private static func applyBlockAttributes(
        _ block: LivePreviewBlockSpan,
        plan: LivePreviewAttributePlan,
        range: NSRange
    ) {
        switch block.kind {
        case .heading(let level):
            plan.addAttributes([
                .font: LivePreviewTheme.headingFont(level: level),
                .foregroundColor: LivePreviewTheme.textColor,
                .paragraphStyle: LivePreviewTheme.headingParagraphStyle(level: level)
            ], range: range)
        case .blockquote:
            plan.addAttributes([
                .foregroundColor: LivePreviewTheme.quoteColor,
                .paragraphStyle: LivePreviewTheme.quoteParagraphStyle
            ], range: range)
        case .callout:
            plan.addAttributes([
                .foregroundColor: LivePreviewTheme.quoteColor,
                .backgroundColor: LivePreviewTheme.calloutBackgroundColor,
                .paragraphStyle: LivePreviewTheme.calloutParagraphStyle
            ], range: range)
        case .fencedCode:
            plan.addAttributes([
                .font: LivePreviewTheme.codeFont,
                .foregroundColor: LivePreviewTheme.codeColor,
                .backgroundColor: LivePreviewTheme.codeBlockBackgroundColor,
                .paragraphStyle: LivePreviewTheme.codeBlockParagraphStyle
            ], range: range)
        case .table:
            plan.addAttributes([.font: LivePreviewTheme.codeFont], range: range)
        case .embed:
            plan.addAttributes([.foregroundColor: LivePreviewTheme.secondaryTextColor], range: range)
        case .unorderedList, .orderedList, .taskList:
            plan.addAttributes([
                .foregroundColor: LivePreviewTheme.textColor,
                .paragraphStyle: LivePreviewTheme.listParagraphStyle
            ], range: range)
        case .frontmatter:
            plan.addAttributes([.foregroundColor: LivePreviewTheme.secondaryTextColor], range: range)
        case .paragraph:
            break
        }
    }

    private static func applyBlockTokenAttributes(
        _ block: LivePreviewBlockSpan,
        source: String,
        plan: LivePreviewAttributePlan,
        visibleRange: NSRange
    ) {
        for range in blockTokenRanges(for: block, source: source) {
            let range = NSIntersectionRange(range, visibleRange)
            guard range.length > 0 else {
                continue
            }
            plan.addAttributes([.foregroundColor: blockTokenColor(for: block)], range: range)
        }
    }

    private static func blockTokenColor(for block: LivePreviewBlockSpan) -> NSColor {
        switch block.kind {
        case .blockquote:
            return LivePreviewTheme.quoteBarColor
        case .callout:
            return LivePreviewTheme.calloutAccentColor
        default:
            return LivePreviewTheme.listMarkerColor
        }
    }

    private static func applyInlineAttributes(
        _ block: LivePreviewBlockSpan,
        source: String,
        plan: LivePreviewAttributePlan,
        visibleRange: NSRange
    ) {
        for inline in block.inlineSpans {
            let range = NSIntersectionRange(inline.sourceRange.nsRange, visibleRange)
            guard range.length > 0 else {
                continue
            }
            switch inline.kind {
            case .strong:
                plan.addAttributes([.font: LivePreviewTheme.strongFont], range: range)
            case .emphasis:
                plan.addAttributes([.obliqueness: 0.12], range: range)
            case .inlineCode:
                plan.addAttributes([
                    .font: LivePreviewTheme.codeFont,
                    .foregroundColor: LivePreviewTheme.codeColor,
                    .backgroundColor: LivePreviewTheme.inlineCodeBackgroundColor
                ], range: range)
            case .wikiLink:
                plan.addAttributes([.foregroundColor: LivePreviewTheme.linkColor], range: range)
            case .markdownLink:
                plan.addAttributes([.foregroundColor: LivePreviewTheme.linkColor], range: range)
            case .tag:
                plan.addAttributes([.foregroundColor: LivePreviewTheme.tagColor], range: range)
            }
        }
    }

    private static func concealTokens(
        _ block: LivePreviewBlockSpan,
        source: String,
        plan: LivePreviewAttributePlan,
        visibleRange: NSRange,
        revealRange: NSRange
    ) {
        guard !block.sourceRange.nsRange.intersects(revealRange) else {
            return
        }

        for range in concealmentRanges(for: block, source: source) {
            let range = NSIntersectionRange(range, visibleRange)
            guard range.length > 0 else {
                continue
            }
            plan.addAttributes([
                .foregroundColor: LivePreviewTheme.concealedColor
            ], range: range)
        }
    }

    private static func concealmentRanges(for block: LivePreviewBlockSpan, source: String) -> [NSRange] {
        var ranges: [NSRange]
        switch block.kind {
        case .heading:
            ranges = prefixMatches(in: source, block: block, regex: headingPrefixRegex)
        case .unorderedList:
            ranges = prefixMatches(in: source, block: block, regex: unorderedListPrefixRegex)
        case .orderedList:
            ranges = prefixMatches(in: source, block: block, regex: orderedListPrefixRegex)
        case .taskList:
            ranges = taskListConcealmentRanges(for: block, source: source)
        case .blockquote:
            ranges = []
        case .callout:
            ranges = prefixMatches(in: source, block: block, regex: calloutPrefixRegex)
        case .table:
            return matches(in: source, range: block.sourceRange.nsRange, regex: tablePipeRegex)
        case .embed:
            return embedTokenRanges(for: block, source: source)
        case .paragraph:
            ranges = []
        case .fencedCode:
            return matches(in: source, range: block.sourceRange.nsRange, regex: fenceLineRegex)
        case .frontmatter:
            return []
        }
        ranges += inlineTokenRanges(block.inlineSpans, source: source)
        return ranges
    }

    private static func blockTokenRanges(for block: LivePreviewBlockSpan, source: String) -> [NSRange] {
        switch block.kind {
        case .blockquote:
            return prefixMatches(in: source, block: block, regex: blockquotePrefixRegex)
        case .callout:
            return prefixMatches(in: source, block: block, regex: calloutPrefixRegex)
        case .unorderedList:
            return prefixMatches(in: source, block: block, regex: unorderedListPrefixRegex)
        case .orderedList:
            return prefixMatches(in: source, block: block, regex: orderedListPrefixRegex)
        case .taskList:
            return prefixMatches(in: source, block: block, regex: taskListPrefixRegex)
        default:
            return []
        }
    }

    private static func taskListConcealmentRanges(for block: LivePreviewBlockSpan, source: String) -> [NSRange] {
        prefixMatches(in: source, block: block, regex: taskListPrefixRegex).flatMap { prefixRange in
            guard let checkboxRange = taskCheckboxTokenRegex
                .firstMatch(in: source, range: prefixRange)?
                .range
            else {
                return [prefixRange]
            }
            let before = NSRange(
                location: prefixRange.location,
                length: max(0, checkboxRange.location - prefixRange.location)
            )
            let afterLocation = checkboxRange.location + checkboxRange.length
            let after = NSRange(
                location: afterLocation,
                length: max(0, prefixRange.location + prefixRange.length - afterLocation)
            )
            return [before, after].filter { $0.length > 0 }
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
                return matches(in: source, range: span.sourceRange.nsRange, regex: wikiLinkTokenRegex)
            case .markdownLink:
                return markdownLinkDelimiterRanges(in: span.sourceRange.nsRange, source: source)
            case .tag:
                let range = span.sourceRange.nsRange
                return range.length > 1 ? [NSRange(location: range.location, length: 1)] : []
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

    private static func prefixMatches(
        in source: String,
        block: LivePreviewBlockSpan,
        regex: NSRegularExpression
    ) -> [NSRange] {
        matches(in: source, range: block.sourceRange.nsRange, regex: regex)
    }

    private static func matches(in source: String, range: NSRange, regex: NSRegularExpression) -> [NSRange] {
        return regex.matches(in: source, range: range).map(\.range)
    }

    private static func embedTokenRanges(for block: LivePreviewBlockSpan, source: String) -> [NSRange] {
        let range = block.sourceRange.nsRange
        let blockText = (source as NSString).substring(with: range)
        if blockText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("![[") {
            return matches(in: source, range: range, regex: wikiEmbedTokenRegex)
        }
        return markdownLinkDelimiterRanges(in: range, source: source)
    }

    private static func markdownLinkDelimiterRanges(in range: NSRange, source: String) -> [NSRange] {
        let text = (source as NSString).substring(with: range) as NSString
        let imageOpening = text.range(of: "![")
        let normalOpening = text.range(of: "[")
        let usesImageOpening = imageOpening.location != NSNotFound
            && (normalOpening.location == NSNotFound || imageOpening.location <= normalOpening.location)
        let opening = usesImageOpening ? imageOpening : normalOpening
        guard opening.location != NSNotFound else {
            return []
        }

        let closeSearchStart = opening.location + opening.length
        let closeSearchRange = NSRange(location: closeSearchStart, length: max(0, text.length - closeSearchStart))
        let closing = text.range(of: "](", options: [], range: closeSearchRange)
        guard closing.location != NSNotFound else {
            return []
        }

        return [
            NSRange(location: range.location + opening.location, length: opening.length),
            NSRange(location: range.location + closing.location, length: 1)
        ]
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }

    private static func baseAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: LivePreviewTheme.baseFont,
            .foregroundColor: LivePreviewTheme.textColor,
            .paragraphStyle: LivePreviewTheme.baseParagraphStyle
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

private final class LivePreviewAttributePlan {
    private let visibleRange: NSRange
    private let attributedString: NSMutableAttributedString

    init(source: String, visibleRange: NSRange, baseAttributes: [NSAttributedString.Key: Any]) {
        self.visibleRange = visibleRange
        let visibleText = (source as NSString).substring(with: visibleRange)
        self.attributedString = NSMutableAttributedString(string: visibleText, attributes: baseAttributes)
    }

    func addAttributes(_ attributes: [NSAttributedString.Key: Any], range: NSRange) {
        let localRange = NSIntersectionRange(range, visibleRange)
        guard localRange.length > 0 else {
            return
        }
        attributedString.addAttributes(attributes, range: toLocalRange(localRange))
    }

    func apply(to storage: NSTextStorage, changes: inout AttributeChangeCounter) {
        let fullRange = NSRange(location: 0, length: attributedString.length)
        attributedString.enumerateAttributes(in: fullRange) { attributes, localRange, _ in
            changes.replace(attributes, to: storage, range: toSourceRange(localRange))
        }
    }

    private func toLocalRange(_ range: NSRange) -> NSRange {
        NSRange(location: range.location - visibleRange.location, length: range.length)
    }

    private func toSourceRange(_ range: NSRange) -> NSRange {
        NSRange(location: range.location + visibleRange.location, length: range.length)
    }
}

private struct AttributeChangeCounter {
    var appliedRuns = 0
    var changedRangeCount = 0
    var changedUTF16Length = 0

    mutating func replace(
        _ attributes: [NSAttributedString.Key: Any],
        to storage: NSTextStorage,
        range: NSRange
    ) {
        guard range.length > 0 else {
            return
        }
        let changedRanges = rangesNeedingReplacement(attributes, in: storage, range: range)
        for changedRange in changedRanges {
            storage.setAttributes(attributes, range: changedRange)
            record(changedRange)
        }
    }

    private mutating func record(_ range: NSRange) {
        appliedRuns += 1
        changedRangeCount += 1
        changedUTF16Length += range.length
    }

    private func rangesNeedingReplacement(
        _ attributes: [NSAttributedString.Key: Any],
        in storage: NSTextStorage,
        range: NSRange
    ) -> [NSRange] {
        var ranges: [NSRange] = []
        storage.enumerateAttributes(in: range) { existing, subrange, _ in
            if !attributeDictionariesEqual(existing, attributes) {
                ranges.append(subrange)
            }
        }
        return ranges
    }

    private func attributeDictionariesEqual(
        _ lhs: [NSAttributedString.Key: Any],
        _ rhs: [NSAttributedString.Key: Any]
    ) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }
        return lhs.allSatisfy { key, value in
            attributeValueEquals(value, rhs[key])
        }
    }

    private func attributeValueEquals(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs as NSObject, rhs as NSObject):
            return lhs == rhs
        default:
            return false
        }
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
