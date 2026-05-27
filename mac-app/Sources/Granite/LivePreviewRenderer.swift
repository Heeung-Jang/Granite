import AppKit
import Foundation
import NativeMarkdownCore

@MainActor
enum LivePreviewRenderer {
    private static let headingPrefixRegex = regex(#"^#{1,6}\s"#)
    private static let unorderedListPrefixRegex = regex(#"^\s*[-*+]\s"#)
    private static let orderedListPrefixRegex = regex(#"^\s*\d+[.)]\s"#)
    private static let taskListPrefixRegex = regex(#"^\s*[-*+]\s+\[[ xX]\]\s"#)
    private static let taskListMarkerRegex = regex(#"[-*+]"#)
    private static let taskCheckboxTokenRegex = regex(#"\[[ xX]\]"#)
    private static let blockquotePrefixRegex = regex(#"^\s*>\s?"#)
    private static let calloutPrefixRegex = regex(#"^\s*>\s?\[![^\]\n]+\]\s?"#)
    private static let calloutQuotePrefixRegex = regex(#"^\s*>\s?"#)
    private static let tablePipeRegex = regex(#"\|"#)
    private static let fenceLineRegex = regex(#"^\s*(```+|~~~+).*$"#)
    private static let wikiEmbedTokenRegex = regex(#"!\[\[|\]\]"#)
    private static let wikiLinkTokenRegex = regex(#"!?\[\[|\]\]"#)

    @discardableResult
    static func render(
        in textView: NSTextView,
        range requestedRange: NSRange? = nil,
        mode: LivePreviewMode = .livePreview,
        revealRange: NSRange? = nil,
        linkStyleMap: LivePreviewLinkStyleMap = LivePreviewLinkStyleMap(),
        embedPreviewMap: LivePreviewEmbedPreviewMap = LivePreviewEmbedPreviewMap(),
        markerStyle: LivePreviewMarkerStyle = .defaultValue,
        scale: Double = AppContentZoom.defaultScale
    ) -> MarkdownDecorationResult {
        let scale = AppContentZoom(rawScale: scale).scale
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
            return applySourceMode(in: textView, range: requestedRange, mode: mode, scale: scale, start: start)
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
            baseAttributes: baseAttributes(scale: scale)
        )
        renderBlocks(
            source: textView.string,
            plan: plan,
            visibleRange: visibleRange,
            revealRange: resolvedRevealRange,
            linkStyleMap: linkStyleMap,
            embedPreviewMap: embedPreviewMap,
            markerStyle: markerStyle,
            scale: scale
        )
        let result = storage.withPreservedSelection(textView: textView, textLength: text.length) {
            var changes = AttributeChangeCounter()
            plan.apply(to: storage, changes: &changes)
            return changes
        }
        textView.needsDisplay = true

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
        scale: Double,
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

        let changes = storage.withPreservedSelection(textView: textView, textLength: text.length) {
            var changes = AttributeChangeCounter()
            changes.replace(sourceAttributes(scale: scale), to: storage, range: visibleRange)
            return changes
        }

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
        revealRange: NSRange,
        linkStyleMap: LivePreviewLinkStyleMap,
        embedPreviewMap: LivePreviewEmbedPreviewMap,
        markerStyle: LivePreviewMarkerStyle,
        scale: Double
    ) {
        let parseWindow = LivePreviewVisibleParseWindow.window(
            in: source,
            visibleRange: LivePreviewSourceRange(location: visibleRange.location, length: visibleRange.length),
            paddingLines: 2,
            maxUTF16Length: max(visibleRange.length + 4_096, 8_192)
        )
        let parsed = LivePreviewParser.parse(source, in: parseWindow)
        let listResolution = LivePreviewListMarkerResolver.resolve(
            source: source,
            blocks: parsed.blocks,
            parseWindow: parseWindow
        )
        var listParagraphStylesByDepth: [Int: NSParagraphStyle] = [:]
        for block in parsed.blocks {
            let blockRange = NSIntersectionRange(block.sourceRange.nsRange, visibleRange)
            guard blockRange.length > 0 else {
                continue
            }
            let listContext = listResolution.contextsByBlockRange[block.sourceRange]
            let properties = frontmatterProperties(for: block, source: source)
            let embedPreview = embedPreviewMap.preview(for: block)
            let table = tableModel(for: block, source: source)
            applyBlockAttributes(
                block,
                plan: plan,
                range: blockRange,
                listParagraphStyle: listContext.map {
                    cachedListParagraphStyle(depth: $0.depth, scale: scale, in: &listParagraphStylesByDepth)
                },
                scale: scale
            )
            applyBlockTokenAttributes(
                block,
                source: source,
                plan: plan,
                visibleRange: visibleRange,
                markerStyle: markerStyle
            )
            applyPropertyAttributes(properties, source: source, plan: plan, visibleRange: visibleRange, scale: scale)
            applyTableAttributes(table, plan: plan, visibleRange: visibleRange, scale: scale)
            applyEmbedAttributes(embedPreview, plan: plan, visibleRange: visibleRange, scale: scale)
            applyInlineAttributes(
                block,
                source: source,
                plan: plan,
                visibleRange: visibleRange,
                linkStyleMap: linkStyleMap,
                scale: scale
            )
            concealTokens(
                block,
                source: source,
                properties: properties,
                table: table,
                embedPreview: embedPreview,
                plan: plan,
                visibleRange: visibleRange,
                revealRange: revealRange,
                markerStyle: markerStyle
            )
        }
    }

    private static func applyBlockAttributes(
        _ block: LivePreviewBlockSpan,
        plan: LivePreviewAttributePlan,
        range: NSRange,
        listParagraphStyle: NSParagraphStyle?,
        scale: Double
    ) {
        switch block.kind {
        case .heading(let level):
            plan.addAttributes([
                .font: LivePreviewTheme.headingFont(level: level, scale: scale),
                .foregroundColor: LivePreviewTheme.textColor,
                .paragraphStyle: LivePreviewTheme.headingParagraphStyle(level: level, scale: scale)
            ], range: range)
        case .blockquote:
            plan.addAttributes([
                .foregroundColor: LivePreviewTheme.quoteColor,
                .paragraphStyle: LivePreviewTheme.quoteParagraphStyle(scale: scale)
            ], range: range)
        case .callout:
            plan.addAttributes([
                .foregroundColor: LivePreviewTheme.textColor,
                .paragraphStyle: LivePreviewTheme.calloutParagraphStyle(scale: scale)
            ], range: range)
        case .fencedCode:
            plan.addAttributes([
                .font: LivePreviewTheme.codeFont(scale: scale),
                .foregroundColor: LivePreviewTheme.codeColor,
                .backgroundColor: LivePreviewTheme.codeBlockBackgroundColor,
                .paragraphStyle: LivePreviewTheme.codeBlockParagraphStyle(scale: scale)
            ], range: range)
        case .table:
            plan.addAttributes([
                .font: LivePreviewTheme.baseFont(scale: scale),
                .paragraphStyle: LivePreviewTheme.tableParagraphStyle(scale: scale)
            ], range: range)
        case .horizontalRule:
            plan.addAttributes([
                .foregroundColor: LivePreviewTheme.secondaryTextColor,
                .paragraphStyle: LivePreviewTheme.horizontalRuleParagraphStyle(scale: scale)
            ], range: range)
        case .embed:
            plan.addAttributes([
                .foregroundColor: LivePreviewTheme.embedFallbackColor,
                .backgroundColor: LivePreviewTheme.embedBackgroundColor,
                .paragraphStyle: LivePreviewTheme.embedParagraphStyle(scale: scale)
            ], range: range)
        case .unorderedList, .orderedList, .taskList:
            plan.addAttributes([
                .foregroundColor: LivePreviewTheme.textColor,
                .paragraphStyle: listParagraphStyle ?? LivePreviewTheme.listParagraphStyle
            ], range: range)
        case .frontmatter:
            plan.addAttributes([
                .font: LivePreviewTheme.baseFont(scale: scale),
                .foregroundColor: LivePreviewTheme.propertyValueColor,
                .backgroundColor: LivePreviewTheme.propertyBackgroundColor,
                .paragraphStyle: LivePreviewTheme.propertyParagraphStyle
            ], range: range)
        case .paragraph:
            break
        }
    }

    private static func cachedListParagraphStyle(
        depth: Int,
        scale: Double,
        in cache: inout [Int: NSParagraphStyle]
    ) -> NSParagraphStyle {
        let cacheKey = max(0, depth)
        if let style = cache[cacheKey] {
            return style
        }
        let style = LivePreviewTheme.listParagraphStyle(depth: cacheKey, scale: scale)
        cache[cacheKey] = style
        return style
    }

    private static func applyBlockTokenAttributes(
        _ block: LivePreviewBlockSpan,
        source: String,
        plan: LivePreviewAttributePlan,
        visibleRange: NSRange,
        markerStyle: LivePreviewMarkerStyle
    ) {
        for range in blockTokenRanges(for: block, source: source) {
            let range = NSIntersectionRange(range, visibleRange)
            guard range.length > 0 else {
                continue
            }
            plan.addAttributes([.foregroundColor: blockTokenColor(for: block, markerStyle: markerStyle)], range: range)
        }
    }

    private static func blockTokenColor(
        for block: LivePreviewBlockSpan,
        markerStyle: LivePreviewMarkerStyle
    ) -> NSColor {
        switch block.kind {
        case .horizontalRule:
            return LivePreviewTheme.secondaryTextColor
        case .blockquote:
            return LivePreviewTheme.quoteBarColor
        case .callout:
            return LivePreviewTheme.calloutAccentColor(for: block.kind)
        default:
            if markerStyle.usesMutedMarkerColor {
                return LivePreviewTheme.secondaryTextColor
            }
            return LivePreviewTheme.listMarkerColor
        }
    }

    private static func frontmatterProperties(
        for block: LivePreviewBlockSpan,
        source: String
    ) -> LivePreviewPropertyBlock? {
        guard case .frontmatter(isClosed: true) = block.kind else {
            return nil
        }
        return LivePreviewPropertyParser.parse(source)
    }

    private static func applyPropertyAttributes(
        _ properties: LivePreviewPropertyBlock?,
        source: String,
        plan: LivePreviewAttributePlan,
        visibleRange: NSRange,
        scale: Double
    ) {
        guard let properties else {
            return
        }

        applyPropertyLayoutAttributes(properties, source: source, plan: plan, visibleRange: visibleRange)

        for row in properties.rows {
            let keyRange = NSIntersectionRange(row.keyRange.nsRange, visibleRange)
            if keyRange.length > 0 {
                plan.addAttributes([
                    .font: LivePreviewTheme.strongFont(scale: scale),
                    .foregroundColor: LivePreviewTheme.propertyKeyColor,
                    .backgroundColor: LivePreviewTheme.propertyBackgroundColor
                ], range: keyRange)
            }

            guard let valueRange = row.valueRange?.nsRange else {
                continue
            }
            let visibleValueRange = NSIntersectionRange(valueRange, visibleRange)
            if visibleValueRange.length > 0 {
                plan.addAttributes([
                    .foregroundColor: LivePreviewTheme.propertyValueColor,
                    .backgroundColor: LivePreviewTheme.propertyBackgroundColor
                ], range: visibleValueRange)
            }
        }
    }

    private static func applyPropertyLayoutAttributes(
        _ properties: LivePreviewPropertyBlock,
        source: String,
        plan: LivePreviewAttributePlan,
        visibleRange: NSRange
    ) {
        let lineRanges = propertyLineRanges(for: properties, source: source)
        guard let titleRange = lineRanges.first else {
            return
        }

        addPropertyParagraphStyle(
            LivePreviewTheme.propertyTitleParagraphStyle,
            range: titleRange,
            plan: plan,
            visibleRange: visibleRange
        )

        if lineRanges.indices.contains(1) {
            addPropertyParagraphStyle(
                LivePreviewTheme.propertySectionParagraphStyle,
                range: lineRanges[1],
                plan: plan,
                visibleRange: visibleRange
            )
        }

        guard lineRanges.count > 2 else {
            return
        }
        for lineRange in lineRanges.dropFirst(2) {
            addPropertyParagraphStyle(
                LivePreviewTheme.propertyRowParagraphStyle,
                range: lineRange,
                plan: plan,
                visibleRange: visibleRange
            )
        }
    }

    private static func addPropertyParagraphStyle(
        _ style: NSParagraphStyle,
        range: NSRange,
        plan: LivePreviewAttributePlan,
        visibleRange: NSRange
    ) {
        let range = NSIntersectionRange(range, visibleRange)
        guard range.length > 0 else {
            return
        }
        plan.addAttributes([.paragraphStyle: style], range: range)
    }

    private static func propertyLineRanges(
        for properties: LivePreviewPropertyBlock,
        source: String
    ) -> [NSRange] {
        let text = source as NSString
        let blockRange = properties.sourceRange.nsRange
        let blockEnd = blockRange.location + blockRange.length
        var cursor = blockRange.location
        var ranges: [NSRange] = []

        while cursor < blockEnd {
            let searchRange = NSRange(location: cursor, length: blockEnd - cursor)
            let newlineRange = text.range(of: "\n", options: [], range: searchRange)
            let upper = newlineRange.location == NSNotFound
                ? blockEnd
                : newlineRange.location + newlineRange.length
            ranges.append(NSRange(location: cursor, length: upper - cursor))
            cursor = upper
        }

        return ranges
    }

    private static func tableModel(
        for block: LivePreviewBlockSpan,
        source: String
    ) -> LivePreviewTable? {
        guard block.kind == .table else {
            return nil
        }
        return LivePreviewTableParser.parse(block, in: source)
    }

    private static func applyTableAttributes(
        _ table: LivePreviewTable?,
        plan: LivePreviewAttributePlan,
        visibleRange: NSRange,
        scale: Double
    ) {
        guard let table else {
            return
        }

        for cell in table.header {
            let range = NSIntersectionRange(cell.contentRange.nsRange, visibleRange)
            guard range.length > 0 else {
                continue
            }
            plan.addAttributes([
                .font: LivePreviewTheme.strongFont(scale: scale),
                .backgroundColor: LivePreviewTheme.tableHeaderBackgroundColor
            ], range: range)
        }

        for row in table.bodyRows {
            for cell in row {
                let range = NSIntersectionRange(cell.contentRange.nsRange, visibleRange)
                guard range.length > 0 else {
                    continue
                }
                plan.addAttributes([
                    .backgroundColor: LivePreviewTheme.tableCellBackgroundColor
                ], range: range)
            }
        }

        let alignmentRange = NSIntersectionRange(table.alignmentRowRange.nsRange, visibleRange)
        if alignmentRange.length > 0 {
            plan.addAttributes([
                .font: LivePreviewTheme.collapsedSyntaxFont,
                .paragraphStyle: LivePreviewTheme.collapsedSyntaxParagraphStyle
            ], range: alignmentRange)
        }
    }

    private static func applyEmbedAttributes(
        _ preview: LivePreviewEmbedPreview?,
        plan: LivePreviewAttributePlan,
        visibleRange: NSRange,
        scale: Double
    ) {
        guard let preview else {
            return
        }

        let targetRange = NSIntersectionRange(preview.span.targetRange.nsRange, visibleRange)
        guard targetRange.length > 0 else {
            return
        }

        plan.addAttributes(embedAttributes(for: preview.status, scale: scale), range: targetRange)
    }

    private static func embedAttributes(
        for status: LivePreviewEmbedPreviewStatus,
        scale: Double
    ) -> [NSAttributedString.Key: Any] {
        let color: NSColor
        switch status {
        case .pending:
            color = LivePreviewTheme.embedFallbackColor
        case .imageReady:
            color = LivePreviewTheme.embedImageColor
        case .blocked:
            color = LivePreviewTheme.embedBlockedColor
        case .nonImage:
            color = LivePreviewTheme.embedFallbackColor
        }
        return [
            .font: LivePreviewTheme.strongFont(scale: scale),
            .foregroundColor: color,
            .backgroundColor: LivePreviewTheme.embedBackgroundColor
        ]
    }

    private static func applyInlineAttributes(
        _ block: LivePreviewBlockSpan,
        source: String,
        plan: LivePreviewAttributePlan,
        visibleRange: NSRange,
        linkStyleMap: LivePreviewLinkStyleMap,
        scale: Double
    ) {
        for inline in block.inlineSpans {
            let range = NSIntersectionRange(inline.sourceRange.nsRange, visibleRange)
            guard range.length > 0 else {
                continue
            }
            switch inline.kind {
            case .strong:
                plan.addAttributes([.font: LivePreviewTheme.strongFont(scale: scale)], range: range)
            case .emphasis:
                plan.addAttributes([.obliqueness: 0.12], range: range)
            case .inlineCode:
                plan.addAttributes([
                    .font: LivePreviewTheme.codeFont(scale: scale),
                    .foregroundColor: LivePreviewTheme.codeColor,
                    .backgroundColor: LivePreviewTheme.inlineCodeBackgroundColor
                ], range: range)
            case .wikiLink:
                plan.addAttributes(
                    linkAttributes(for: linkStyleMap.state(for: inline)),
                    range: inlineDisplayRange(inline, visibleRange: visibleRange)
                )
            case .markdownLink:
                plan.addAttributes(
                    linkAttributes(for: linkStyleMap.state(for: inline)),
                    range: inlineDisplayRange(inline, visibleRange: visibleRange)
                )
            case .tag:
                plan.addAttributes(tagAttributes(), range: inlineDisplayRange(inline, visibleRange: visibleRange))
            }
        }
    }

    private static func linkAttributes(
        for state: LivePreviewLinkStyleState
    ) -> [NSAttributedString.Key: Any] {
        let color: NSColor
        switch state {
        case .unknown, .resolved:
            color = LivePreviewTheme.linkColor
        case .missing:
            color = LivePreviewTheme.missingLinkColor
        case .duplicate:
            color = LivePreviewTheme.duplicateLinkColor
        case .missingHeading:
            color = LivePreviewTheme.missingHeadingLinkColor
        }

        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
        if state != .unknown && state != .resolved {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attributes[.underlineColor] = color
        }
        return attributes
    }

    private static func tagAttributes() -> [NSAttributedString.Key: Any] {
        [
            .foregroundColor: LivePreviewTheme.tagColor,
            .backgroundColor: LivePreviewTheme.tagBackgroundColor
        ]
    }

    private static func concealTokens(
        _ block: LivePreviewBlockSpan,
        source: String,
        properties: LivePreviewPropertyBlock?,
        table: LivePreviewTable?,
        embedPreview: LivePreviewEmbedPreview?,
        plan: LivePreviewAttributePlan,
        visibleRange: NSRange,
        revealRange: NSRange,
        markerStyle: LivePreviewMarkerStyle
    ) {
        let sourceReveal = sourceRevealEligibility(
            for: block,
            revealRange: revealRange,
            markerStyle: markerStyle
        )
        guard !sourceReveal.revealsSyntax else {
            return
        }

        let collapsedMarkerRanges = collapsedRawMarkerConcealmentRanges(
            for: block,
            source: source,
            markerStyle: markerStyle
        )

        for range in rawMarkerConcealmentRanges(
            for: block,
            source: source,
            properties: properties,
            table: table,
            embedPreview: embedPreview,
            markerStyle: markerStyle
        ) {
            let range = NSIntersectionRange(range, visibleRange)
            guard range.length > 0 else {
                continue
            }
            plan.addAttributes(
                rawMarkerConcealmentAttributes(collapsesWidth: rangeIsCovered(range, by: collapsedMarkerRanges)),
                range: range
            )
        }
    }

    private struct SourceRevealEligibility {
        var revealsSyntax: Bool
    }

    private struct RenderedMarkerOverlayPolicy {
        var isNeeded: Bool
    }

    private static func rawMarkerConcealmentAttributes(collapsesWidth: Bool) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: LivePreviewTheme.concealedColor
        ]
        if collapsesWidth {
            attributes[.font] = LivePreviewTheme.collapsedSyntaxFont
        }
        return attributes
    }

    private static func collapsedRawMarkerConcealmentRanges(
        for block: LivePreviewBlockSpan,
        source: String,
        markerStyle: LivePreviewMarkerStyle
    ) -> [NSRange] {
        switch block.kind {
        case .heading where !markerStyle.showsHeadingMarkersOutsideReveal:
            return prefixMatches(in: source, block: block, regex: headingPrefixRegex)
        case .unorderedList where markerStyle == .obsidian,
             .orderedList where markerStyle == .obsidian,
             .taskList where markerStyle == .obsidian:
            return LivePreviewListMarkerResolver.context(for: block, source: source)
                .map { [$0.prefixRange] } ?? []
        default:
            return []
        }
    }

    private static func rawMarkerConcealmentRanges(
        for block: LivePreviewBlockSpan,
        source: String,
        properties: LivePreviewPropertyBlock?,
        table: LivePreviewTable?,
        embedPreview: LivePreviewEmbedPreview?,
        markerStyle: LivePreviewMarkerStyle
    ) -> [NSRange] {
        var ranges: [NSRange]
        switch block.kind {
        case .heading:
            ranges = markerStyle.showsHeadingMarkersOutsideReveal
                ? []
                : prefixMatches(in: source, block: block, regex: headingPrefixRegex)
        case .unorderedList:
            ranges = markerStyle == .obsidian || !markerStyle.showsListMarkersOutsideReveal
                ? LivePreviewListMarkerResolver.context(for: block, source: source).map { [$0.prefixRange] } ?? []
                : []
        case .orderedList:
            ranges = markerStyle == .obsidian || !markerStyle.showsListMarkersOutsideReveal
                ? LivePreviewListMarkerResolver.context(for: block, source: source).map { [$0.prefixRange] } ?? []
                : []
        case .taskList:
            ranges = taskListConcealmentRanges(for: block, source: source, markerStyle: markerStyle)
        case .blockquote:
            ranges = markerStyle.keepsBlockquoteMarkersConcealed
                ? prefixMatches(in: source, block: block, regex: blockquotePrefixRegex)
                : []
        case .callout:
            ranges = prefixMatches(in: source, block: block, regex: calloutQuotePrefixRegex)
            ranges += prefixMatches(in: source, block: block, regex: calloutPrefixRegex)
        case .table:
            return [block.sourceRange.nsRange]
        case .embed:
            return embedTokenRanges(for: block, source: source, preview: embedPreview)
        case .paragraph:
            ranges = []
        case .horizontalRule:
            ranges = [block.contentRange.nsRange]
        case .fencedCode:
            return matches(in: source, range: block.sourceRange.nsRange, regex: fenceLineRegex)
        case .frontmatter:
            return [block.sourceRange.nsRange]
        }
        ranges += inlineTokenRanges(block.inlineSpans, source: source)
        return ranges
    }

    private static func sourceRevealEligibility(
        for block: LivePreviewBlockSpan,
        revealRange: NSRange,
        markerStyle: LivePreviewMarkerStyle
    ) -> SourceRevealEligibility {
        let revealsSyntax: Bool
        switch block.kind {
        case .heading:
            revealsSyntax = block.sourceRange.nsRange.intersectsOrContainsCaret(revealRange)
        case .blockquote where markerStyle.keepsBlockquoteMarkersConcealed:
            revealsSyntax = false
        case .frontmatter, .callout, .table:
            revealsSyntax = false
        default:
            revealsSyntax = block.sourceRange.nsRange.intersectsOrContainsCaret(revealRange)
        }
        return SourceRevealEligibility(revealsSyntax: revealsSyntax)
    }

    private static func renderedMarkerOverlayPolicy(
        for block: LivePreviewBlockSpan,
        revealRange: NSRange,
        markerStyle: LivePreviewMarkerStyle
    ) -> RenderedMarkerOverlayPolicy {
        let revealsSyntax = sourceRevealEligibility(
            for: block,
            revealRange: revealRange,
            markerStyle: markerStyle
        ).revealsSyntax
        let isNeeded: Bool
        switch block.kind {
        case .unorderedList, .orderedList:
            isNeeded = markerStyle == .obsidian && !revealsSyntax
        case .taskList:
            isNeeded = markerStyle == .obsidian && !revealsSyntax
        default:
            isNeeded = false
        }
        return RenderedMarkerOverlayPolicy(isNeeded: isNeeded)
    }

    private static func blockTokenRanges(for block: LivePreviewBlockSpan, source: String) -> [NSRange] {
        switch block.kind {
        case .heading:
            return prefixMatches(in: source, block: block, regex: headingPrefixRegex)
        case .blockquote:
            return prefixMatches(in: source, block: block, regex: blockquotePrefixRegex)
        case .callout:
            return prefixMatches(in: source, block: block, regex: calloutQuotePrefixRegex)
        case .unorderedList:
            return LivePreviewListMarkerResolver.context(for: block, source: source).map { [$0.prefixRange] } ?? []
        case .orderedList:
            return LivePreviewListMarkerResolver.context(for: block, source: source).map { [$0.prefixRange] } ?? []
        case .taskList:
            return LivePreviewListMarkerResolver.context(for: block, source: source).map { [$0.prefixRange] } ?? []
        case .horizontalRule:
            return [block.contentRange.nsRange]
        default:
            return []
        }
    }

    private static func taskListConcealmentRanges(
        for block: LivePreviewBlockSpan,
        source: String,
        markerStyle: LivePreviewMarkerStyle
    ) -> [NSRange] {
        guard let context = LivePreviewListMarkerResolver.context(for: block, source: source) else {
            return []
        }
        let prefixRange = context.prefixRange
        let checkboxRange = context.markerRange
            if markerStyle == .obsidian {
                return [prefixRange]
            }
            if markerStyle.showsListMarkersOutsideReveal {
                let markerRange = taskListMarkerRange(in: prefixRange, source: source)
                let markerEnd = markerRange.map { $0.location + $0.length } ?? prefixRange.location
                let beforeCheckbox = NSRange(
                    location: markerEnd,
                    length: max(0, checkboxRange.location - markerEnd)
                )
                let afterLocation = checkboxRange.location + checkboxRange.length
                let after = NSRange(
                    location: afterLocation,
                    length: max(0, prefixRange.location + prefixRange.length - afterLocation)
                )
                return [beforeCheckbox, after].filter { $0.length > 0 }
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

    private static func taskListMarkerRange(in prefixRange: NSRange, source: String) -> NSRange? {
        let text = source as NSString
        let prefix = text.substring(with: prefixRange) as NSString
        let markerMatch = taskListMarkerRegex.firstMatch(
            in: prefix as String,
            range: NSRange(location: 0, length: prefix.length)
        )
        guard let markerMatch else {
            return nil
        }
        return NSRange(location: prefixRange.location + markerMatch.range.location, length: markerMatch.range.length)
    }

    private static func tableConcealmentRanges(
        for block: LivePreviewBlockSpan,
        source: String,
        table: LivePreviewTable?
    ) -> [NSRange] {
        var ranges = matches(in: source, range: block.sourceRange.nsRange, regex: tablePipeRegex)
        if let table {
            ranges.append(table.alignmentRowRange.nsRange)
        }
        return ranges
    }

    private static func inlineTokenRanges(_ inlineSpans: [LivePreviewInlineSpan], source: String) -> [NSRange] {
        inlineSpans.flatMap { span in
            switch span.kind {
            case .strong:
                return edgeRanges(span.sourceRange.nsRange, tokenLength: 2)
            case .emphasis, .inlineCode:
                return edgeRanges(span.sourceRange.nsRange, tokenLength: 1)
            case .wikiLink:
                return wikiLinkConcealmentRanges(span, source: source)
            case .markdownLink:
                return markdownLinkConcealmentRanges(span, source: source)
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

    private static func inlineDisplayRange(_ span: LivePreviewInlineSpan, visibleRange: NSRange) -> NSRange {
        NSIntersectionRange(span.displayRange?.nsRange ?? span.sourceRange.nsRange, visibleRange)
    }

    private static func wikiLinkConcealmentRanges(_ span: LivePreviewInlineSpan, source: String) -> [NSRange] {
        guard let displayRange = span.displayRange?.nsRange else {
            return matches(in: source, range: span.sourceRange.nsRange, regex: wikiLinkTokenRegex)
        }
        let sourceRange = span.sourceRange.nsRange
        guard !NSEqualRanges(sourceRange, displayRange) else {
            return matches(in: source, range: sourceRange, regex: wikiLinkTokenRegex)
        }
        return displayOnlyConcealmentRanges(sourceRange: sourceRange, displayRange: displayRange)
    }

    private static func markdownLinkConcealmentRanges(
        _ span: LivePreviewInlineSpan,
        source: String
    ) -> [NSRange] {
        let sourceRange = span.sourceRange.nsRange
        guard !span.isInert,
              let displayRange = span.displayRange?.nsRange,
              let target = markdownLinkTarget(in: sourceRange, source: source),
              shouldConcealMarkdownLinkTarget(target)
        else {
            return markdownLinkDelimiterRanges(in: sourceRange, source: source)
        }
        return displayOnlyConcealmentRanges(sourceRange: sourceRange, displayRange: displayRange)
    }

    private static func displayOnlyConcealmentRanges(
        sourceRange: NSRange,
        displayRange: NSRange
    ) -> [NSRange] {
        let displayEnd = displayRange.location + displayRange.length
        let sourceEnd = sourceRange.location + sourceRange.length
        return [
            NSRange(location: sourceRange.location, length: max(0, displayRange.location - sourceRange.location)),
            NSRange(location: displayEnd, length: max(0, sourceEnd - displayEnd))
        ].filter { $0.length > 0 }
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

    private static func embedTokenRanges(
        for block: LivePreviewBlockSpan,
        source: String,
        preview: LivePreviewEmbedPreview?
    ) -> [NSRange] {
        if let preview {
            return preview.span.tokenRanges.map(\.nsRange)
        }
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

    private static func markdownLinkTarget(in range: NSRange, source: String) -> String? {
        let text = (source as NSString).substring(with: range) as NSString
        let labelEnd = text.range(of: "](")
        guard labelEnd.location != NSNotFound,
              text.length > labelEnd.location + labelEnd.length + 1
        else {
            return nil
        }
        let targetStart = labelEnd.location + labelEnd.length
        let targetLength = text.length - targetStart - 1
        guard targetLength > 0 else {
            return nil
        }
        return text.substring(with: NSRange(location: targetStart, length: targetLength))
    }

    private static func shouldConcealMarkdownLinkTarget(_ target: String) -> Bool {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.contains(".."),
              !trimmed.contains("["),
              !trimmed.contains("]")
        else {
            return false
        }
        guard let scheme = targetScheme(trimmed)?.lowercased() else {
            return true
        }
        return ["http", "https", "mailto"].contains(scheme)
    }

    private static func targetScheme(_ target: String) -> String? {
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

    private static func isASCIIAlpha(_ scalar: UnicodeScalar) -> Bool {
        (65...90).contains(Int(scalar.value)) || (97...122).contains(Int(scalar.value))
    }

    private static func isSchemeScalar(_ scalar: UnicodeScalar) -> Bool {
        isASCIIAlpha(scalar)
            || (48...57).contains(Int(scalar.value))
            || scalar == "+"
            || scalar == "-"
            || scalar == "."
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }

    private static func rangeIsCovered(_ range: NSRange, by ranges: [NSRange]) -> Bool {
        ranges.contains { candidate in
            let intersection = NSIntersectionRange(range, candidate)
            return intersection.location == range.location && intersection.length == range.length
        }
    }

    private static func baseAttributes(scale: Double) -> [NSAttributedString.Key: Any] {
        [
            .font: LivePreviewTheme.baseFont(scale: scale),
            .foregroundColor: LivePreviewTheme.textColor,
            .paragraphStyle: LivePreviewTheme.baseParagraphStyle(scale: scale)
        ]
    }

    private static func sourceAttributes(scale: Double) -> [NSAttributedString.Key: Any] {
        [
            .font: LivePreviewTheme.sourceFont(scale: scale),
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
        let restoredSelection = NSRange(
            location: min(selection.location, textLength),
            length: min(selection.length, max(0, textLength - min(selection.location, textLength)))
        )
        if !NSEqualRanges(textView.selectedRange(), restoredSelection) {
            textView.setSelectedRange(restoredSelection)
        }
        return value
    }
}

private extension NSRange {
    func intersectsOrContainsCaret(_ other: NSRange) -> Bool {
        if other.length == 0 {
            return other.location >= location && other.location < location + length
        }
        return location < other.location + other.length && other.location < location + length
    }
}
