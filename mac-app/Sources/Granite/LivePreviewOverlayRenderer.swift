import AppKit
import NativeMarkdownCore

@MainActor
enum LivePreviewOverlayRenderer {
    private struct RenderBlock {
        var block: LivePreviewBlockSpan
        var properties: LivePreviewPropertyBlock?
        var table: LivePreviewTable?
        var listContext: LivePreviewListMarkerContext?
    }

    private struct LineFragment {
        var characterRange: NSRange
        var lineRect: NSRect
        var usedRect: NSRect
    }

    struct ListGuideSegment: Codable, Equatable {
        var depth: Int
        var x: Double
        var startY: Double
        var endY: Double
    }

    private struct PropertyGroup {
        var key: String
        var values: [String]
    }

    private enum PropertyLayout {
        static let maxWidth: CGFloat = 760
        static let minWidth: CGFloat = 420
        static let rightPadding: CGFloat = 36
        static let titleYOffset: CGFloat = 0
        static let titleHeight: CGFloat = 36
        static let sectionYOffset: CGFloat = 1
        static let sectionHeight: CGFloat = 22
        static let rowYOffset: CGFloat = 3
        static let rowTextHeight: CGFloat = 22
        static let iconX: CGFloat = 2
        static let iconYOffset: CGFloat = 3
        static let iconSize: CGFloat = 16
        static let keyX: CGFloat = 28
        static let keyWidth: CGFloat = 126
        static let valueX: CGFloat = 166
        static let tagHeight: CGFloat = 20
        static let tagGap: CGFloat = 6
        static let tagHorizontalPadding: CGFloat = 18
    }

    static func drawBackgrounds(
        in textView: MarkdownInteractionTextView,
        dirtyRect: NSRect,
        state: LivePreviewOverlayState
    ) {
        guard state.drawsLivePreviewChrome else {
            return
        }
        for renderBlock in visibleBlocks(in: textView) {
            switch renderBlock.block.kind {
            case .callout:
                drawCalloutBackground(renderBlock.block, in: textView, dirtyRect: dirtyRect)
            case .table:
                if let table = renderBlock.table {
                    drawTableBackground(table, in: textView, dirtyRect: dirtyRect)
                }
            default:
                continue
            }
        }
    }

    static func drawForegrounds(
        in textView: MarkdownInteractionTextView,
        dirtyRect: NSRect,
        state: LivePreviewOverlayState
    ) {
        guard state.drawsLivePreviewChrome else {
            return
        }
        let renderBlocks = visibleBlocks(in: textView)
        for renderBlock in renderBlocks {
            switch renderBlock.block.kind {
            case .frontmatter:
                if let properties = renderBlock.properties {
                    drawProperties(properties, title: textView.livePreviewDocumentTitle, in: textView, dirtyRect: dirtyRect)
                }
            case .table:
                if let table = renderBlock.table {
                    drawTableForeground(table, in: textView, dirtyRect: dirtyRect, state: state)
                }
            case .horizontalRule:
                drawHorizontalRule(renderBlock.block, in: textView, dirtyRect: dirtyRect, state: state)
            case .unorderedList, .orderedList, .taskList:
                drawMarkerOverlay(renderBlock, in: textView, dirtyRect: dirtyRect, state: state)
            default:
                continue
            }
        }
        if state.markerStyle == .obsidian {
            drawListGuideSegments(
                renderBlocks
                    .compactMap(\.listContext)
                    .sorted { $0.blockRange.location < $1.blockRange.location }
                    .guideSegments(in: textView),
                dirtyRect: dirtyRect
            )
        }
    }

    private static func visibleBlocks(in textView: NSTextView) -> [RenderBlock] {
        let source = textView.string
        let textLength = (source as NSString).length
        guard textLength > 0,
              let visibleRange = visibleCharacterRange(in: textView)
        else {
            return []
        }

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
        let frontmatter = LivePreviewPropertyParser.parse(source)

        return parsed.blocks.compactMap { block in
            let range = block.sourceRange.nsRange
            guard range.intersects(visibleRange) else {
                return nil
            }
            return RenderBlock(
                block: block,
                properties: frontmatterProperties(frontmatter, for: block),
                table: LivePreviewTableParser.parse(block, in: source),
                listContext: listResolution.contextsByBlockRange[block.sourceRange]
            )
        }
    }

    private static func frontmatterProperties(
        _ properties: LivePreviewPropertyBlock?,
        for block: LivePreviewBlockSpan
    ) -> LivePreviewPropertyBlock? {
        guard case .frontmatter(isClosed: true) = block.kind else {
            return nil
        }
        return properties
    }

    private static func drawCalloutBackground(
        _ block: LivePreviewBlockSpan,
        in textView: NSTextView,
        dirtyRect: NSRect
    ) {
        guard let rect = unionLineRect(for: block.sourceRange.nsRange, in: textView)?
            .insetBy(dx: -8, dy: -5),
            rect.intersects(dirtyRect)
        else {
            return
        }

        let accent = LivePreviewTheme.calloutAccentColor(for: block.kind)
        LivePreviewTheme.calloutBackgroundColor(for: block.kind).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()

        let accentRect = NSRect(x: rect.minX, y: rect.minY, width: 3, height: rect.height)
        accent.setFill()
        NSBezierPath(roundedRect: accentRect, xRadius: 1.5, yRadius: 1.5).fill()
    }

    private static func drawProperties(
        _ properties: LivePreviewPropertyBlock,
        title: String?,
        in textView: NSTextView,
        dirtyRect: NSRect
    ) {
        let fragments = lineFragments(for: properties.sourceRange.nsRange, in: textView)
        guard fragments.count >= 2 else {
            return
        }

        let x = fragments[0].lineRect.minX
        let width = min(
            PropertyLayout.maxWidth,
            max(PropertyLayout.minWidth, textView.bounds.width - x - PropertyLayout.rightPadding)
        )
        let titleText = normalizedTitle(title)
        drawString(
            titleText,
            in: NSRect(
                x: x,
                y: fragments[0].lineRect.minY + PropertyLayout.titleYOffset,
                width: width,
                height: PropertyLayout.titleHeight
            ),
            attributes: [
                .font: NSFont.systemFont(ofSize: 26, weight: .bold),
                .foregroundColor: LivePreviewTheme.textColor
            ],
            dirtyRect: dirtyRect
        )

        drawString(
            "속성",
            in: NSRect(
                x: x,
                y: fragments[1].lineRect.minY + PropertyLayout.sectionYOffset,
                width: width,
                height: PropertyLayout.sectionHeight
            ),
            attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                .foregroundColor: LivePreviewTheme.textColor
            ],
            dirtyRect: dirtyRect
        )

        let groups = propertyGroups(from: properties.rows)
        var lineIndex = 2
        for group in groups where lineIndex < fragments.count {
            let rect = fragments[lineIndex].lineRect
            drawPropertyRow(group, rect: rect, x: x, width: width, dirtyRect: dirtyRect)
            lineIndex += 1
        }
    }

    private static func drawPropertyRow(
        _ group: PropertyGroup,
        rect: NSRect,
        x: CGFloat,
        width: CGFloat,
        dirtyRect: NSRect
    ) {
        guard rect.intersects(dirtyRect) else {
            return
        }

        let rowY = rect.minY + PropertyLayout.rowYOffset
        drawPropertyIcon(
            for: group.key,
            in: NSRect(
                x: x + PropertyLayout.iconX,
                y: rowY + PropertyLayout.iconYOffset,
                width: PropertyLayout.iconSize,
                height: PropertyLayout.iconSize
            )
        )
        drawString(
            displayKey(group.key),
            in: NSRect(
                x: x + PropertyLayout.keyX,
                y: rowY,
                width: PropertyLayout.keyWidth,
                height: PropertyLayout.rowTextHeight
            ),
            attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .regular),
                .foregroundColor: LivePreviewTheme.propertyKeyColor
            ],
            dirtyRect: dirtyRect
        )

        if group.key == "tags" {
            drawTagPills(
                group.values.map { displayValue($0, key: group.key) },
                x: x + PropertyLayout.valueX,
                y: rowY,
                maxX: x + width,
                dirtyRect: dirtyRect
            )
            return
        }

        let value = group.values.map { displayValue($0, key: group.key) }.joined(separator: ", ")
        let isLink = group.key.lowercased().contains("link") || value.contains("://")
        drawString(
            value,
            in: NSRect(
                x: x + PropertyLayout.valueX,
                y: rowY,
                width: max(120, width - PropertyLayout.valueX),
                height: PropertyLayout.rowTextHeight
            ),
            attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .regular),
                .foregroundColor: isLink ? LivePreviewTheme.linkColor : LivePreviewTheme.propertyValueColor
            ],
            dirtyRect: dirtyRect
        )
    }

    private static func drawTableBackground(_ table: LivePreviewTable, in textView: NSTextView, dirtyRect: NSRect) {
        guard let layout = LivePreviewTableLayout.make(for: table, in: textView),
              layout.outerRect.intersects(dirtyRect)
        else {
            return
        }

        LivePreviewTheme.tableCellBackgroundColor.setFill()
        NSBezierPath(rect: layout.outerRect).fill()
        if let header = layout.rowRects.first {
            LivePreviewTheme.tableHeaderBackgroundColor.setFill()
            NSBezierPath(rect: NSRect(x: layout.outerRect.minX, y: header.minY, width: layout.outerRect.width, height: header.height)).fill()
        }
    }

    private static func drawTableForeground(
        _ table: LivePreviewTable,
        in textView: NSTextView,
        dirtyRect: NSRect,
        state: LivePreviewOverlayState
    ) {
        guard let layout = LivePreviewTableLayout.make(for: table, in: textView),
              layout.outerRect.intersects(dirtyRect)
        else {
            return
        }

        drawTableGrid(layout)
        for cell in layout.cells where shouldDrawTableCellText(cell.tableCell, state: state) {
            let text = NSMutableAttributedString(attributedString: markdownInlineString(
                displayValue(cell.tableCell.text, key: nil),
                isHeader: cell.isHeader
            ))
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = cell.alignment.textAlignment
            if text.length > 0 {
                text.addAttribute(
                    .paragraphStyle,
                    value: paragraphStyle,
                    range: NSRange(location: 0, length: text.length)
                )
            }
            text.draw(with: cell.textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
        drawTableControls(layout, state: state)
    }

    static func shouldDrawTableCellText(
        _ cell: LivePreviewTableCell,
        state: LivePreviewOverlayState
    ) -> Bool {
        !(state.allowsTransientControls && state.activeTableCell == cell)
    }

    static func shouldDrawTableControls(state: LivePreviewOverlayState) -> Bool {
        state.allowsTransientControls && state.activeTableCell != nil
    }

    private static func drawTableControls(_ layout: LivePreviewTableLayout, state: LivePreviewOverlayState) {
        guard shouldDrawTableControls(state: state),
              let cell = state.activeTableCell
        else {
            return
        }
        [layout.rowAddControlRect(for: cell), layout.columnAddControlRect(for: cell)].compactMap { $0 }.forEach { rect in
            LivePreviewTheme.tableHeaderBackgroundColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
            LivePreviewTheme.tableBorderColor.setStroke()
            let path = NSBezierPath(ovalIn: rect)
            path.lineWidth = 1
            path.stroke()
            LivePreviewTheme.textColor.setStroke()
            let plus = NSBezierPath()
            plus.lineWidth = 1.2
            plus.move(to: NSPoint(x: rect.midX - 4, y: rect.midY))
            plus.line(to: NSPoint(x: rect.midX + 4, y: rect.midY))
            plus.move(to: NSPoint(x: rect.midX, y: rect.midY - 4))
            plus.line(to: NSPoint(x: rect.midX, y: rect.midY + 4))
            plus.stroke()
        }
    }

    static func shouldDrawHorizontalRule(_ block: LivePreviewBlockSpan, selectedRange: NSRange) -> Bool {
        guard block.kind == .horizontalRule else {
            return false
        }
        return !block.sourceRange.nsRange.intersectsOrContainsCaret(selectedRange)
    }

    static func markerGeometries(in textView: NSTextView) -> [LivePreviewMarkerGeometry] {
        let source = textView.string
        guard !source.isEmpty else {
            return []
        }
        let parsed = LivePreviewParser.parse(source)
        let listResolution = LivePreviewListMarkerResolver.resolve(source: source, blocks: parsed.blocks)
        return parsed.blocks.compactMap { block in
            guard let context = listResolution.contextsByBlockRange[block.sourceRange] else {
                return nil
            }
            return markerGeometry(for: block, context: context, in: textView)
        }
    }

    static func guideSegments(in textView: NSTextView) -> [ListGuideSegment] {
        visibleBlocks(in: textView)
            .compactMap(\.listContext)
            .sorted { $0.blockRange.location < $1.blockRange.location }
            .guideSegments(in: textView)
    }

    static func shouldDrawMarkerOverlay(
        for block: LivePreviewBlockSpan,
        markerKind: LivePreviewMarkerGeometry.Kind,
        state: LivePreviewOverlayState
    ) -> Bool {
        guard state.drawsLivePreviewChrome,
              state.markerStyle == .obsidian,
              markerKind == .unorderedListMarker
                || markerKind == .orderedListMarker
                || markerKind == .taskCheckbox
        else {
            return false
        }
        return !block.sourceRange.nsRange.intersectsOrContainsCaret(state.revealRange)
    }

    static func taskCheckboxTokenRange(
        at point: NSPoint,
        in textView: NSTextView,
        state: LivePreviewOverlayState
    ) -> NSRange? {
        guard state.allowsTransientControls,
              state.markerStyle == .obsidian
        else {
            return nil
        }
        return markerGeometries(in: textView).first {
            $0.kind == .taskCheckbox && taskCheckboxRect($0).contains(point)
        }?.sourceRange
    }

    private static func drawHorizontalRule(
        _ block: LivePreviewBlockSpan,
        in textView: NSTextView,
        dirtyRect: NSRect,
        state: LivePreviewOverlayState
    ) {
        guard shouldDrawHorizontalRule(block, selectedRange: state.revealRange),
              let lineRect = unionLineRect(for: block.sourceRange.nsRange, in: textView)
        else {
            return
        }

        let x = lineRect.minX
        let width = min(760, max(120, textView.bounds.width - x - 36))
        let y = floor(lineRect.midY) + 0.5
        let rect = NSRect(x: x, y: y - 1, width: width, height: 2)
        guard rect.intersects(dirtyRect) else {
            return
        }

        let path = NSBezierPath()
        path.lineWidth = 1
        LivePreviewTheme.horizontalRuleColor.setStroke()
        path.move(to: NSPoint(x: x, y: y))
        path.line(to: NSPoint(x: x + width, y: y))
        path.stroke()
    }

    private static func drawMarkerOverlay(
        _ renderBlock: RenderBlock,
        in textView: NSTextView,
        dirtyRect: NSRect,
        state: LivePreviewOverlayState
    ) {
        guard let context = renderBlock.listContext,
              let geometry = markerGeometry(for: renderBlock.block, context: context, in: textView),
              shouldDrawMarkerOverlay(for: renderBlock.block, markerKind: geometry.kind, state: state)
        else {
            return
        }

        switch geometry.kind {
        case .unorderedListMarker:
            drawUnorderedBullet(geometry, dirtyRect: dirtyRect)
        case .orderedListMarker:
            drawOrderedMarker(geometry, source: textView.string, dirtyRect: dirtyRect)
        case .taskCheckbox:
            drawTaskCheckbox(geometry, block: renderBlock.block, dirtyRect: dirtyRect)
        }
    }

    private static func drawUnorderedBullet(_ geometry: LivePreviewMarkerGeometry, dirtyRect: NSRect) {
        let diameter: CGFloat = 4.5
        let rect = NSRect(
            x: geometry.rect.minX + 2,
            y: floor(geometry.lineRect.midY - diameter / 2),
            width: diameter,
            height: diameter
        )
        guard rect.intersects(dirtyRect) else {
            return
        }
        LivePreviewTheme.secondaryTextColor.setFill()
        NSBezierPath(ovalIn: rect).fill()
    }

    private static func drawOrderedMarker(
        _ geometry: LivePreviewMarkerGeometry,
        source: String,
        dirtyRect: NSRect
    ) {
        let marker = markerText(geometry, source: source)
        let rect = NSRect(
            x: geometry.rect.minX,
            y: geometry.lineRect.minY,
            width: max(28, geometry.rect.width),
            height: geometry.lineRect.height
        )
        drawString(
            marker,
            in: rect,
            attributes: [
                .font: LivePreviewTheme.baseFont,
                .foregroundColor: LivePreviewTheme.secondaryTextColor
            ],
            dirtyRect: dirtyRect
        )
    }

    private static func markerText(_ geometry: LivePreviewMarkerGeometry, source: String) -> String {
        let range = clamped(geometry.sourceRange, length: (source as NSString).length)
        guard range.length > 0 else {
            return ""
        }
        return (source as NSString)
            .substring(with: range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func drawTaskCheckbox(
        _ geometry: LivePreviewMarkerGeometry,
        block: LivePreviewBlockSpan,
        dirtyRect: NSRect
    ) {
        guard case .taskList(let isChecked) = block.kind else {
            return
        }
        let rect = taskCheckboxRect(geometry)
        guard rect.intersects(dirtyRect) else {
            return
        }

        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        path.lineWidth = 1.2
        LivePreviewTheme.secondaryTextColor.setStroke()
        path.stroke()

        guard isChecked else {
            return
        }
        let check = NSBezierPath()
        check.lineWidth = 1.6
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        LivePreviewTheme.secondaryTextColor.setStroke()
        check.move(to: NSPoint(x: rect.minX + 3.5, y: rect.midY))
        check.line(to: NSPoint(x: rect.midX - 0.5, y: rect.maxY - 3.5))
        check.line(to: NSPoint(x: rect.maxX - 3, y: rect.minY + 3.5))
        check.stroke()
    }

    private static func taskCheckboxRect(_ geometry: LivePreviewMarkerGeometry) -> NSRect {
        let side: CGFloat = 13
        return NSRect(
            x: geometry.rect.minX + 1,
            y: floor(geometry.lineRect.midY - side / 2),
            width: side,
            height: side
        )
    }

    private static func markerGeometry(
        for block: LivePreviewBlockSpan,
        context: LivePreviewListMarkerContext,
        in textView: NSTextView
    ) -> LivePreviewMarkerGeometry? {
        guard let lineRect = lineFragments(for: block.sourceRange.nsRange, in: textView).first?.lineRect
        else {
            return nil
        }
        return LivePreviewMarkerGeometry(
            kind: markerKind(for: context),
            sourceRange: context.markerRange,
            rect: LivePreviewTheme.listMarkerSlotRect(depth: context.depth, lineRect: lineRect),
            lineRect: lineRect
        )
    }

    private static func markerKind(for context: LivePreviewListMarkerContext) -> LivePreviewMarkerGeometry.Kind {
        switch context.kind {
        case .unordered:
            return .unorderedListMarker
        case .ordered:
            return .orderedListMarker
        case .task:
            return .taskCheckbox
        }
    }

    private static func drawListGuideSegments(_ segments: [ListGuideSegment], dirtyRect: NSRect) {
        let visibleSegments = segments.filter {
            NSRect(
                x: $0.x - 1,
                y: min($0.startY, $0.endY),
                width: 2,
                height: abs($0.endY - $0.startY)
            ).intersects(dirtyRect)
        }
        guard !visibleSegments.isEmpty else {
            return
        }

        let path = NSBezierPath()
        path.lineWidth = 1
        for segment in visibleSegments {
            let x = floor(segment.x) + 0.5
            let startY = max(min(segment.startY, segment.endY), Double(dirtyRect.minY))
            let endY = min(max(segment.startY, segment.endY), Double(dirtyRect.maxY))
            guard endY > startY else {
                continue
            }
            path.move(to: NSPoint(x: x, y: startY))
            path.line(to: NSPoint(x: x, y: endY))
        }
        LivePreviewTheme.listGuideLineColor.setStroke()
        path.stroke()
    }

    private static func drawTableGrid(_ layout: LivePreviewTableLayout) {
        LivePreviewTheme.tableBorderColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1

        for rowRect in layout.rowRects {
            path.move(to: NSPoint(x: layout.outerRect.minX, y: rowRect.minY))
            path.line(to: NSPoint(x: layout.outerRect.maxX, y: rowRect.minY))
            path.move(to: NSPoint(x: layout.outerRect.minX, y: rowRect.maxY))
            path.line(to: NSPoint(x: layout.outerRect.maxX, y: rowRect.maxY))
        }

        for columnRect in layout.columnRects {
            path.move(to: NSPoint(x: columnRect.minX, y: layout.outerRect.minY))
            path.line(to: NSPoint(x: columnRect.minX, y: layout.outerRect.maxY))
            path.move(to: NSPoint(x: columnRect.maxX, y: layout.outerRect.minY))
            path.line(to: NSPoint(x: columnRect.maxX, y: layout.outerRect.maxY))
        }
        path.stroke()
    }

    private static func markdownInlineString(_ text: String, isHeader: Bool = false) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let baseFont = isHeader ? LivePreviewTheme.strongFont : LivePreviewTheme.baseFont
        var index = text.startIndex

        while index < text.endIndex {
            if text[index] == "`",
               let end = text[text.index(after: index)...].firstIndex(of: "`") {
                let contentStart = text.index(after: index)
                output.append(NSAttributedString(
                    string: String(text[contentStart..<end]),
                    attributes: [
                        .font: LivePreviewTheme.codeFont,
                        .foregroundColor: LivePreviewTheme.codeColor,
                        .backgroundColor: LivePreviewTheme.inlineCodeBackgroundColor
                    ]
                ))
                index = text.index(after: end)
                continue
            }

            if text[index...].hasPrefix("[["),
               let end = text[index...].range(of: "]]") {
                let contentStart = text.index(index, offsetBy: 2)
                let raw = String(text[contentStart..<end.lowerBound])
                let display = raw.split(separator: "|", maxSplits: 1).last.map(String.init) ?? raw
                output.append(NSAttributedString(
                    string: display,
                    attributes: [
                        .font: baseFont,
                        .foregroundColor: LivePreviewTheme.linkColor
                    ]
                ))
                index = end.upperBound
                continue
            }

            if text[index...].hasPrefix("**"),
               let end = text[text.index(index, offsetBy: 2)...].range(of: "**") {
                let contentStart = text.index(index, offsetBy: 2)
                output.append(NSAttributedString(
                    string: String(text[contentStart..<end.lowerBound]),
                    attributes: [
                        .font: LivePreviewTheme.strongFont,
                        .foregroundColor: LivePreviewTheme.textColor
                    ]
                ))
                index = end.upperBound
                continue
            }

            let next = text.index(after: index)
            output.append(NSAttributedString(
                string: String(text[index..<next]),
                attributes: [
                    .font: baseFont,
                    .foregroundColor: LivePreviewTheme.textColor
                ]
            ))
            index = next
        }

        return output
    }

    private static func drawTagPills(_ values: [String], x: CGFloat, y: CGFloat, maxX: CGFloat, dirtyRect: NSRect) {
        var cursor = x
        for value in values where !value.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: LivePreviewTheme.tagColor
            ]
            let textSize = (value as NSString).size(withAttributes: attributes)
            let rect = NSRect(
                x: cursor,
                y: y + 1,
                width: textSize.width + PropertyLayout.tagHorizontalPadding,
                height: PropertyLayout.tagHeight
            )
            guard rect.maxX <= maxX else {
                return
            }
            if rect.intersects(dirtyRect) {
                LivePreviewTheme.tagBackgroundColor.setFill()
                NSBezierPath(
                    roundedRect: rect,
                    xRadius: PropertyLayout.tagHeight / 2,
                    yRadius: PropertyLayout.tagHeight / 2
                ).fill()
                (value as NSString).draw(
                    in: rect.insetBy(dx: 9, dy: 2),
                    withAttributes: attributes
                )
            }
            cursor = rect.maxX + PropertyLayout.tagGap
        }
    }

    private static func drawPropertyIcon(for key: String, in rect: NSRect) {
        let symbolName: String
        switch key {
        case "date":
            symbolName = "calendar"
        case "tags":
            symbolName = "tag"
        case "original_link", "url", "site":
            symbolName = "link"
        default:
            symbolName = "line.3.horizontal"
        }

        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
            return
        }
        image.isTemplate = true
        LivePreviewTheme.propertyIconColor.set()
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.85)
    }

    private static func drawString(
        _ string: String,
        in rect: NSRect,
        attributes: [NSAttributedString.Key: Any],
        dirtyRect: NSRect
    ) {
        guard rect.intersects(dirtyRect) else {
            return
        }
        (string as NSString).draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
            attributes: attributes
        )
    }

    private static func propertyGroups(from rows: [LivePreviewPropertyRow]) -> [PropertyGroup] {
        var groups: [PropertyGroup] = []
        for row in rows {
            if let lastIndex = groups.indices.last, groups[lastIndex].key == row.key {
                if !row.value.isEmpty {
                    groups[lastIndex].values.append(row.value)
                }
                continue
            }
            groups.append(PropertyGroup(key: row.key, values: row.value.isEmpty ? [] : [row.value]))
        }
        return groups
    }

    private static func displayKey(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ")
    }

    private static func displayValue(_ raw: String, key: String?) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        value = value.replacingOccurrences(of: "\\\"", with: "\"")
        if key == "tags", value.hasPrefix("#") {
            value = String(value.dropFirst())
        }
        if key == "date" {
            value = value.replacingOccurrences(of: "-", with: ". ") + "."
        }
        return value
    }

    private static func normalizedTitle(_ title: String?) -> String {
        guard var title, !title.isEmpty else {
            return "Untitled"
        }
        if title.hasSuffix(".md") {
            title.removeLast(3)
        }
        return title
    }

    private static func visibleCharacterRange(in textView: NSTextView) -> NSRange? {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else {
            return nil
        }
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: textContainer)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        return clamped(characterRange, length: (textView.string as NSString).length)
    }

    private static func unionLineRect(for range: NSRange, in textView: NSTextView) -> NSRect? {
        let fragments = lineFragments(for: range, in: textView)
        guard let first = fragments.first else {
            return nil
        }
        return fragments.dropFirst().reduce(first.lineRect) { $0.union($1.lineRect) }
    }

    static func lineRectForGuide(range: NSRange, in textView: NSTextView) -> NSRect? {
        unionLineRect(for: range, in: textView)
    }

    private static func lineFragments(for range: NSRange, in textView: NSTextView) -> [LineFragment] {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else {
            return []
        }
        let textLength = (textView.string as NSString).length
        let clampedRange = clamped(range, length: textLength)
        guard clampedRange.length > 0 else {
            return []
        }

        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: clampedRange, actualCharacterRange: nil)
        guard glyphRange.length > 0 else {
            return []
        }

        let origin = textView.textContainerOrigin
        var fragments: [LineFragment] = []
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { lineRect, usedRect, _, lineGlyphRange, _ in
            let intersection = NSIntersectionRange(lineGlyphRange, glyphRange)
            guard intersection.length > 0 else {
                return
            }
            let characterRange = layoutManager.characterRange(forGlyphRange: intersection, actualGlyphRange: nil)
            guard characterRange.intersects(clampedRange) else {
                return
            }
            fragments.append(LineFragment(
                characterRange: characterRange,
                lineRect: offset(lineRect, by: origin),
                usedRect: offset(usedRect, by: origin)
            ))
        }
        return fragments
    }

    private static func boundingRect(for range: NSRange, in textView: NSTextView) -> NSRect? {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else {
            return nil
        }
        let clampedRange = clamped(range, length: (textView.string as NSString).length)
        guard clampedRange.length > 0 else {
            return nil
        }

        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: clampedRange, actualCharacterRange: nil)
        guard glyphRange.length > 0 else {
            return nil
        }
        return offset(layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer), by: textView.textContainerOrigin)
    }

    private static func offset(_ rect: NSRect, by point: NSPoint) -> NSRect {
        NSRect(x: rect.minX + point.x, y: rect.minY + point.y, width: rect.width, height: rect.height)
    }

    private static func unionRange(_ ranges: [NSRange]) -> NSRange? {
        guard let first = ranges.first else {
            return nil
        }
        return ranges.dropFirst().reduce(first) { current, range in
            let lower = min(current.location, range.location)
            let upper = max(current.location + current.length, range.location + range.length)
            return NSRange(location: lower, length: upper - lower)
        }
    }

    private static func clamped(_ range: NSRange, length: Int) -> NSRange {
        let location = min(max(0, range.location), length)
        let maxLength = max(0, length - location)
        return NSRange(location: location, length: min(range.length, maxLength))
    }
}

struct LivePreviewMarkerGeometry: Equatable {
    enum Kind: Equatable {
        case unorderedListMarker
        case orderedListMarker
        case taskCheckbox
    }

    var kind: Kind
    var sourceRange: NSRange
    var rect: NSRect
    var lineRect: NSRect
}

private extension Array where Element == LivePreviewListMarkerContext {
    @MainActor
    func guideSegments(in textView: NSTextView) -> [LivePreviewOverlayRenderer.ListGuideSegment] {
        guard count > 1 else {
            return []
        }

        var segments: [LivePreviewOverlayRenderer.ListGuideSegment] = []
        for index in indices {
            let parent = self[index]
            let childStartIndex = index + 1
            guard childStartIndex < endIndex,
                  self[childStartIndex].clusterID == parent.clusterID,
                  self[childStartIndex].depth > parent.depth
            else {
                continue
            }

            var childEndIndex = childStartIndex
            var cursor = childStartIndex + 1
            while cursor < endIndex,
                  self[cursor].clusterID == parent.clusterID,
                  self[cursor].depth > parent.depth {
                childEndIndex = cursor
                cursor += 1
            }

            guard let firstChildLine = LivePreviewOverlayRenderer.lineRectForGuide(
                range: self[childStartIndex].blockRange,
                in: textView
            ),
                  let lastChildLine = LivePreviewOverlayRenderer.lineRectForGuide(
                    range: self[childEndIndex].blockRange,
                    in: textView
                  )
            else {
                continue
            }
            let x = LivePreviewTheme.listGuideX(depth: parent.depth + 1, lineRect: firstChildLine)
            segments.append(LivePreviewOverlayRenderer.ListGuideSegment(
                depth: parent.depth + 1,
                x: Double(x),
                startY: Double(firstChildLine.minY),
                endY: Double(lastChildLine.maxY)
            ))
        }
        return segments
    }
}

private extension NSRange {
    func intersects(_ other: NSRange) -> Bool {
        location < other.location + other.length && other.location < location + length
    }

    func intersectsOrContainsCaret(_ other: NSRange) -> Bool {
        if other.length == 0 {
            return other.location >= location && other.location < location + length
        }
        return intersects(other)
    }
}

private extension LivePreviewTableAlignment {
    var textAlignment: NSTextAlignment {
        switch self {
        case .none, .left:
            .left
        case .center:
            .center
        case .right:
            .right
        }
    }
}
