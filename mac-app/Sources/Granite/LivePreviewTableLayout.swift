import AppKit
import NativeMarkdownCore

@MainActor
struct LivePreviewTableLayout {
    struct Cell {
        var tableCell: LivePreviewTableCell
        var rowIndex: Int
        var columnIndex: Int
        var isHeader: Bool
        var alignment: LivePreviewTableAlignment
        var rowRect: NSRect
        var columnRect: NSRect
        var textRect: NSRect
    }

    var outerRect: NSRect
    var rowRects: [NSRect]
    var columnRects: [NSRect]
    var cells: [Cell]
    var scale: Double

    func cell(at point: NSPoint) -> LivePreviewTableCell? {
        cells.first { $0.textRect.contains(point) }?.tableCell
    }

    func layoutCell(for cell: LivePreviewTableCell) -> Cell? {
        cells.first { $0.tableCell == cell }
    }

    func rowAddControlRect(for cell: LivePreviewTableCell) -> NSRect? {
        guard let layoutCell = layoutCell(for: cell) else {
            return nil
        }
        return NSRect(
            x: outerRect.maxX + Self.scaled(6, scale: scale),
            y: layoutCell.rowRect.midY - Self.scaled(8, scale: scale),
            width: Self.scaled(16, scale: scale),
            height: Self.scaled(16, scale: scale)
        )
    }

    func columnAddControlRect(for cell: LivePreviewTableCell) -> NSRect? {
        guard let layoutCell = layoutCell(for: cell) else {
            return nil
        }
        return NSRect(
            x: layoutCell.columnRect.midX - Self.scaled(8, scale: scale),
            y: outerRect.minY - Self.scaled(22, scale: scale),
            width: Self.scaled(16, scale: scale),
            height: Self.scaled(16, scale: scale)
        )
    }

    static func tableCell(at point: NSPoint, in textView: NSTextView) -> LivePreviewTableCell? {
        LivePreviewTableParser.parse(textView.string).lazy.compactMap { table -> LivePreviewTableCell? in
            guard let layout = make(for: table, in: textView),
                  layout.outerRect.contains(point)
            else {
                return nil
            }
            return layout.cell(at: point)
        }.first
    }

    static func layoutCell(for cell: LivePreviewTableCell, in textView: NSTextView) -> Cell? {
        LivePreviewTableParser.parse(textView.string).lazy.compactMap { table -> Cell? in
            make(for: table, in: textView)?.layoutCell(for: cell)
        }.first
    }

    static func make(for table: LivePreviewTable, in textView: NSTextView) -> LivePreviewTableLayout? {
        let rows = [table.header] + table.bodyRows
        guard !rows.isEmpty else {
            return nil
        }

        let scale = scale(for: textView)
        let rowRects = rows.compactMap { row -> NSRect? in
            guard let range = unionRange(row.map(\.sourceRange.nsRange)) else {
                return nil
            }
            return unionLineRect(for: range, in: textView)
                .map {
                    NSRect(
                        x: $0.minX,
                        y: $0.minY - scaled(3, scale: scale),
                        width: $0.width,
                        height: max(scaled(30, scale: scale), $0.height + scaled(6, scale: scale))
                    )
                }
        }
        guard rowRects.count == rows.count,
              let first = rowRects.first
        else {
            return nil
        }

        let x = first.minX
        let columnWidths = columnWidths(for: table, scale: scale)
        let naturalWidth = columnWidths.reduce(0, +)
        let minTableWidth = scaled(Metrics.minTableWidth, scale: scale)
        let availableWidth = max(minTableWidth, textView.bounds.width - x - scaled(Metrics.rightPadding, scale: scale))
        let width = min(availableWidth, max(minTableWidth, naturalWidth))
        let outer = rowRects.reduce(NSRect(x: x, y: first.minY, width: width, height: first.height)) {
            $0.union(NSRect(x: x, y: $1.minY, width: width, height: $1.height))
        }
        let columnRects = columnRects(columnWidths: columnWidths, x: x, width: width, outerRect: outer)
        let cells = cellLayouts(
            rows: rows,
            alignments: table.alignments,
            rowRects: rowRects,
            columnRects: columnRects,
            scale: scale
        )

        return LivePreviewTableLayout(
            outerRect: outer,
            rowRects: rowRects,
            columnRects: columnRects,
            cells: cells,
            scale: scale
        )
    }

    private static func cellLayouts(
        rows: [[LivePreviewTableCell]],
        alignments: [LivePreviewTableAlignment],
        rowRects: [NSRect],
        columnRects: [NSRect],
        scale: Double
    ) -> [Cell] {
        var cells: [Cell] = []
        for (rowIndex, row) in rows.enumerated() where rowIndex < rowRects.count {
            let rowRect = rowRects[rowIndex]
            for (columnIndex, tableCell) in row.enumerated() where columnIndex < columnRects.count {
                let columnRect = columnRects[columnIndex]
                let horizontalInset = scaled(8, scale: scale)
                let verticalInset = scaled(6, scale: scale)
                cells.append(Cell(
                    tableCell: tableCell,
                    rowIndex: rowIndex,
                    columnIndex: columnIndex,
                    isHeader: rowIndex == 0,
                    alignment: alignments.indices.contains(columnIndex) ? alignments[columnIndex] : .none,
                    rowRect: rowRect,
                    columnRect: columnRect,
                    textRect: NSRect(
                        x: columnRect.minX + horizontalInset,
                        y: rowRect.minY + verticalInset,
                        width: max(scaled(10, scale: scale), columnRect.width - horizontalInset * 2),
                        height: max(scaled(10, scale: scale), rowRect.height - verticalInset * 2)
                    )
                ))
            }
        }
        return cells
    }

    private static func columnRects(
        columnWidths: [CGFloat],
        x: CGFloat,
        width: CGFloat,
        outerRect: NSRect
    ) -> [NSRect] {
        var rects: [NSRect] = []
        var cursor = x
        let naturalWidth = max(1, columnWidths.reduce(0, +))
        for (index, naturalColumnWidth) in columnWidths.enumerated() {
            let isLast = index == columnWidths.count - 1
            let columnWidth = isLast
                ? x + width - cursor
                : (naturalWidth <= width ? naturalColumnWidth : width * naturalColumnWidth / naturalWidth)
            rects.append(NSRect(x: cursor, y: outerRect.minY, width: columnWidth, height: outerRect.height))
            cursor += columnWidth
        }
        return rects
    }

    private static func columnWidths(for table: LivePreviewTable, scale: Double) -> [CGFloat] {
        let rows = [table.header] + table.bodyRows
        let columnCount = rows.map(\.count).max() ?? 0
        return (0..<columnCount).map { column in
            let measuredTextWidth = rows.enumerated()
                .compactMap { rowIndex, row -> CGFloat? in
                    guard row.indices.contains(column) else {
                        return nil
                    }
                    return textWidth(for: row[column].text, isHeader: rowIndex == 0, scale: scale)
                }
                .max() ?? scaled(Metrics.minTextWidth, scale: scale)
            return min(
                scaled(Metrics.maxColumnWidth, scale: scale),
                max(
                    scaled(Metrics.minColumnWidth, scale: scale),
                    ceil(measuredTextWidth + scaled(Metrics.cellHorizontalPadding, scale: scale))
                )
            )
        }
    }

    private static func textWidth(for text: String, isHeader: Bool, scale: Double) -> CGFloat {
        let font = isHeader ? LivePreviewTheme.strongFont(scale: scale) : LivePreviewTheme.baseFont(scale: scale)
        let measurementText = text.isEmpty ? " " : text
        return (measurementText as NSString).size(withAttributes: [.font: font]).width
    }

    private static func scale(for textView: NSTextView) -> Double {
        AppContentZoom(rawScale: (textView as? MarkdownInteractionTextView)?.appContentZoomScale ?? AppContentZoom.defaultScale).scale
    }

    private static func scaled(_ value: CGFloat, scale: Double) -> CGFloat {
        value * CGFloat(scale)
    }

    private static func unionLineRect(for range: NSRange, in textView: NSTextView) -> NSRect? {
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

        let origin = textView.textContainerOrigin
        var rects: [NSRect] = []
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { lineRect, _, _, lineGlyphRange, _ in
            let intersection = NSIntersectionRange(lineGlyphRange, glyphRange)
            guard intersection.length > 0 else {
                return
            }
            let characterRange = layoutManager.characterRange(forGlyphRange: intersection, actualGlyphRange: nil)
            guard NSIntersectionRange(characterRange, clampedRange).length > 0 else {
                return
            }
            rects.append(NSRect(
                x: lineRect.minX + origin.x,
                y: lineRect.minY + origin.y,
                width: lineRect.width,
                height: lineRect.height
            ))
        }
        guard let first = rects.first else {
            return nil
        }
        return rects.dropFirst().reduce(first) { $0.union($1) }
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

    private enum Metrics {
        static let cellHorizontalPadding: CGFloat = 24
        static let minTextWidth: CGFloat = 24
        static let minColumnWidth: CGFloat = 56
        static let maxColumnWidth: CGFloat = 320
        static let minTableWidth: CGFloat = 120
        static let rightPadding: CGFloat = 36
    }
}
