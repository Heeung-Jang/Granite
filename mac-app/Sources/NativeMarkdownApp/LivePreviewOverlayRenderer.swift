import AppKit
import NativeMarkdownCore

@MainActor
enum LivePreviewOverlayRenderer {
    private struct RenderBlock {
        var block: LivePreviewBlockSpan
        var properties: LivePreviewPropertyBlock?
        var table: LivePreviewTable?
    }

    private struct LineFragment {
        var characterRange: NSRange
        var lineRect: NSRect
        var usedRect: NSRect
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

    static func drawBackgrounds(in textView: MarkdownInteractionTextView, dirtyRect: NSRect) {
        guard textView.livePreviewMode == .livePreview else {
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

    static func drawForegrounds(in textView: MarkdownInteractionTextView, dirtyRect: NSRect) {
        guard textView.livePreviewMode == .livePreview else {
            return
        }
        for renderBlock in visibleBlocks(in: textView) {
            switch renderBlock.block.kind {
            case .frontmatter:
                if let properties = renderBlock.properties {
                    drawProperties(properties, title: textView.livePreviewDocumentTitle, in: textView, dirtyRect: dirtyRect)
                }
            case .table:
                if let table = renderBlock.table {
                    drawTableForeground(table, in: textView, dirtyRect: dirtyRect)
                }
            default:
                continue
            }
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
        let frontmatter = LivePreviewPropertyParser.parse(source)

        return parsed.blocks.compactMap { block in
            let range = block.sourceRange.nsRange
            guard range.intersects(visibleRange) else {
                return nil
            }
            return RenderBlock(
                block: block,
                properties: frontmatterProperties(frontmatter, for: block),
                table: LivePreviewTableParser.parse(block, in: source)
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
        guard let layout = tableLayout(table, in: textView),
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

    private static func drawTableForeground(_ table: LivePreviewTable, in textView: NSTextView, dirtyRect: NSRect) {
        guard let layout = tableLayout(table, in: textView),
              layout.outerRect.intersects(dirtyRect)
        else {
            return
        }

        drawTableGrid(layout)
        let rows = [table.header] + table.bodyRows
        for (rowIndex, row) in rows.enumerated() where rowIndex < layout.rowRects.count {
            let rowRect = layout.rowRects[rowIndex]
            for (columnIndex, cell) in row.enumerated() where columnIndex < layout.columnRects.count {
                let columnRect = layout.columnRects[columnIndex]
                let cellRect = NSRect(
                    x: columnRect.minX + 8,
                    y: rowRect.minY + 6,
                    width: max(10, columnRect.width - 16),
                    height: max(10, rowRect.height - 12)
                )
                markdownInlineString(
                    displayValue(cell.text, key: nil),
                    isHeader: rowIndex == 0
                ).draw(with: cellRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
            }
        }
    }

    private struct TableLayout {
        var outerRect: NSRect
        var rowRects: [NSRect]
        var columnRects: [NSRect]
    }

    private static func tableLayout(_ table: LivePreviewTable, in textView: NSTextView) -> TableLayout? {
        let rows = [table.header] + table.bodyRows
        guard !rows.isEmpty else {
            return nil
        }

        let rowRects = rows.compactMap { row -> NSRect? in
            guard let range = unionRange(row.map(\.sourceRange.nsRange)) else {
                return nil
            }
            return unionLineRect(for: range, in: textView)
                .map { NSRect(x: $0.minX, y: $0.minY - 3, width: $0.width, height: max(30, $0.height + 6)) }
        }
        guard rowRects.count == rows.count,
              let first = rowRects.first
        else {
            return nil
        }

        let x = first.minX
        let width = min(920, max(420, textView.bounds.width - x - 36))
        let weights = columnWeights(for: table)
        var columnRects: [NSRect] = []
        var cursor = x
        let totalWeight = max(1, weights.reduce(0, +))
        for (index, weight) in weights.enumerated() {
            let isLast = index == weights.count - 1
            let columnWidth = isLast ? x + width - cursor : width * CGFloat(weight) / CGFloat(totalWeight)
            columnRects.append(NSRect(x: cursor, y: first.minY, width: columnWidth, height: 1))
            cursor += columnWidth
        }

        let outer = rowRects.reduce(NSRect(x: x, y: first.minY, width: width, height: first.height)) {
            $0.union(NSRect(x: x, y: $1.minY, width: width, height: $1.height))
        }
        return TableLayout(outerRect: outer, rowRects: rowRects, columnRects: columnRects)
    }

    private static func drawTableGrid(_ layout: TableLayout) {
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

    private static func columnWeights(for table: LivePreviewTable) -> [Int] {
        let rows = [table.header] + table.bodyRows
        let columnCount = rows.map(\.count).max() ?? 0
        return (0..<columnCount).map { column in
            let maxLength = rows
                .compactMap { row in row.indices.contains(column) ? row[column].text.count : nil }
                .max() ?? 8
            return min(34, max(8, maxLength))
        }
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

private extension NSRange {
    func intersects(_ other: NSRange) -> Bool {
        location < other.location + other.length && other.location < location + length
    }
}
