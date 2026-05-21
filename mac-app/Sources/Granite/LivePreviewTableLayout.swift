import AppKit
import NativeMarkdownCore

@MainActor
struct LivePreviewTableLayout {
    struct Cell {
        var tableCell: LivePreviewTableCell
        var rowIndex: Int
        var columnIndex: Int
        var isHeader: Bool
        var rowRect: NSRect
        var columnRect: NSRect
        var textRect: NSRect
    }

    var outerRect: NSRect
    var rowRects: [NSRect]
    var columnRects: [NSRect]
    var cells: [Cell]

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
        return NSRect(x: outerRect.maxX + 6, y: layoutCell.rowRect.midY - 8, width: 16, height: 16)
    }

    func columnAddControlRect(for cell: LivePreviewTableCell) -> NSRect? {
        guard let layoutCell = layoutCell(for: cell) else {
            return nil
        }
        return NSRect(x: layoutCell.columnRect.midX - 8, y: outerRect.minY - 22, width: 16, height: 16)
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
        let outer = rowRects.reduce(NSRect(x: x, y: first.minY, width: width, height: first.height)) {
            $0.union(NSRect(x: x, y: $1.minY, width: width, height: $1.height))
        }
        let columnRects = columnRects(for: table, x: x, width: width, outerRect: outer)
        let cells = cellLayouts(rows: rows, rowRects: rowRects, columnRects: columnRects)

        return LivePreviewTableLayout(
            outerRect: outer,
            rowRects: rowRects,
            columnRects: columnRects,
            cells: cells
        )
    }

    private static func cellLayouts(
        rows: [[LivePreviewTableCell]],
        rowRects: [NSRect],
        columnRects: [NSRect]
    ) -> [Cell] {
        var cells: [Cell] = []
        for (rowIndex, row) in rows.enumerated() where rowIndex < rowRects.count {
            let rowRect = rowRects[rowIndex]
            for (columnIndex, tableCell) in row.enumerated() where columnIndex < columnRects.count {
                let columnRect = columnRects[columnIndex]
                cells.append(Cell(
                    tableCell: tableCell,
                    rowIndex: rowIndex,
                    columnIndex: columnIndex,
                    isHeader: rowIndex == 0,
                    rowRect: rowRect,
                    columnRect: columnRect,
                    textRect: NSRect(
                        x: columnRect.minX + 8,
                        y: rowRect.minY + 6,
                        width: max(10, columnRect.width - 16),
                        height: max(10, rowRect.height - 12)
                    )
                ))
            }
        }
        return cells
    }

    private static func columnRects(
        for table: LivePreviewTable,
        x: CGFloat,
        width: CGFloat,
        outerRect: NSRect
    ) -> [NSRect] {
        let weights = columnWeights(for: table)
        var rects: [NSRect] = []
        var cursor = x
        let totalWeight = max(1, weights.reduce(0, +))
        for (index, weight) in weights.enumerated() {
            let isLast = index == weights.count - 1
            let columnWidth = isLast ? x + width - cursor : width * CGFloat(weight) / CGFloat(totalWeight)
            rects.append(NSRect(x: cursor, y: outerRect.minY, width: columnWidth, height: outerRect.height))
            cursor += columnWidth
        }
        return rects
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
}
