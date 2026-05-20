import Foundation

public enum LivePreviewTableAlignment: Equatable, Sendable {
    case none
    case left
    case center
    case right
}

public struct LivePreviewTableCell: Equatable, Sendable {
    public var text: String
    public var sourceRange: LivePreviewSourceRange
    public var contentRange: LivePreviewSourceRange
    public var columnIndex: Int

    public init(
        text: String,
        sourceRange: LivePreviewSourceRange,
        contentRange: LivePreviewSourceRange,
        columnIndex: Int
    ) {
        self.text = text
        self.sourceRange = sourceRange
        self.contentRange = contentRange
        self.columnIndex = columnIndex
    }
}

public struct LivePreviewTable: Equatable, Sendable {
    public var sourceRange: LivePreviewSourceRange
    public var header: [LivePreviewTableCell]
    public var alignmentRowRange: LivePreviewSourceRange
    public var alignments: [LivePreviewTableAlignment]
    public var bodyRows: [[LivePreviewTableCell]]

    public init(
        sourceRange: LivePreviewSourceRange,
        header: [LivePreviewTableCell],
        alignmentRowRange: LivePreviewSourceRange,
        alignments: [LivePreviewTableAlignment],
        bodyRows: [[LivePreviewTableCell]]
    ) {
        self.sourceRange = sourceRange
        self.header = header
        self.alignmentRowRange = alignmentRowRange
        self.alignments = alignments
        self.bodyRows = bodyRows
    }

    public var cellCount: Int {
        header.count + bodyRows.reduce(0) { $0 + $1.count }
    }

    public func cell(atUTF16Offset offset: Int) -> LivePreviewTableCell? {
        (header + bodyRows.flatMap { $0 }).first {
            contains($0.sourceRange, offset: offset)
        }
    }
}

public enum LivePreviewTableParser {
    public static func parse(_ source: String) -> [LivePreviewTable] {
        LivePreviewParser.parse(source).blocks.compactMap { block in
            parse(block, in: source)
        }
    }

    public static func cell(atUTF16Offset offset: Int, in source: String) -> LivePreviewTableCell? {
        guard offset >= 0, offset < (source as NSString).length else {
            return nil
        }
        return parse(source).lazy.compactMap {
            $0.cell(atUTF16Offset: offset)
        }.first
    }

    public static func parse(
        _ block: LivePreviewBlockSpan,
        in source: String
    ) -> LivePreviewTable? {
        guard block.kind == .table,
              let blockRange = LivePreviewRangeMapper.stringRange(for: block.sourceRange, in: source)
        else {
            return nil
        }

        let lines = tableLines(in: source, range: blockRange)
        guard lines.count >= 2,
              let header = cells(in: lines[0], source: source),
              let alignmentCells = cells(in: lines[1], source: source),
              header.count >= 2,
              alignmentCells.count >= 2,
              alignmentCells.allSatisfy({ alignment(for: $0.text) != nil })
        else {
            return nil
        }

        let bodyRows = lines.dropFirst(2).compactMap { line in
            cells(in: line, source: source)
        }

        return LivePreviewTable(
            sourceRange: block.sourceRange,
            header: header,
            alignmentRowRange: LivePreviewRangeMapper.sourceRange(for: lines[1].contentRange, in: source),
            alignments: alignmentCells.map { alignment(for: $0.text) ?? .none },
            bodyRows: bodyRows
        )
    }

    private static func alignment(for text: String) -> LivePreviewTableAlignment? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let dashText = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        guard dashText.count >= 3,
              dashText.allSatisfy({ $0 == "-" })
        else {
            return nil
        }

        let left = trimmed.hasPrefix(":")
        let right = trimmed.hasSuffix(":")
        switch (left, right) {
        case (true, true):
            return .center
        case (true, false):
            return .left
        case (false, true):
            return .right
        case (false, false):
            return LivePreviewTableAlignment.none
        }
    }

    private static func cells(
        in line: TableLine,
        source: String
    ) -> [LivePreviewTableCell]? {
        let ranges = cellRanges(in: line.contentRange, source: source)
        guard !ranges.isEmpty else {
            return nil
        }

        return ranges.enumerated().map { index, range in
            let contentRange = trimmedRange(range, in: source)
            return LivePreviewTableCell(
                text: String(source[contentRange]),
                sourceRange: LivePreviewRangeMapper.sourceRange(for: range, in: source),
                contentRange: LivePreviewRangeMapper.sourceRange(for: contentRange, in: source),
                columnIndex: index
            )
        }
    }

    private static func cellRanges(
        in lineRange: Range<String.Index>,
        source: String
    ) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var cellStart = lineRange.lowerBound
        var index = lineRange.lowerBound

        while index < lineRange.upperBound {
            if source[index] == "|" {
                if index == lineRange.lowerBound {
                    cellStart = source.index(after: index)
                } else {
                    ranges.append(cellStart..<index)
                    cellStart = source.index(after: index)
                }
            }
            index = source.index(after: index)
        }

        if cellStart < lineRange.upperBound {
            ranges.append(cellStart..<lineRange.upperBound)
        }
        return ranges.filter { !$0.isEmpty }
    }

    private static func trimmedRange(
        _ range: Range<String.Index>,
        in source: String
    ) -> Range<String.Index> {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper, source[lower].isWhitespace {
            lower = source.index(after: lower)
        }
        while lower < upper {
            let previous = source.index(before: upper)
            guard source[previous].isWhitespace else {
                break
            }
            upper = previous
        }
        return lower..<upper
    }

    private static func tableLines(
        in source: String,
        range: Range<String.Index>
    ) -> [TableLine] {
        var lines: [TableLine] = []
        var index = range.lowerBound

        while index < range.upperBound {
            let lineUpper = source[index..<range.upperBound].firstIndex(of: "\n").map {
                source.index(after: $0)
            } ?? range.upperBound
            let contentUpper = lineUpper > index && source[source.index(before: lineUpper)] == "\n"
                ? source.index(before: lineUpper)
                : lineUpper
            lines.append(TableLine(contentRange: index..<contentUpper))
            index = lineUpper
        }

        return lines
    }
}

public enum LivePreviewTableCellEdit {
    public static func replacing(
        cell: LivePreviewTableCell,
        with replacement: String,
        in source: String
    ) -> String? {
        guard isSafeCellText(replacement),
              let range = LivePreviewRangeMapper.stringRange(for: cell.contentRange, in: source)
        else {
            return nil
        }
        guard String(source[range]) == cell.text else {
            return nil
        }

        var edited = source
        edited.replaceSubrange(range, with: replacement)
        return edited
    }

    private static func isSafeCellText(_ text: String) -> Bool {
        !text.contains("\n") && !text.contains("\r") && !text.contains("|")
    }
}

private struct TableLine {
    var contentRange: Range<String.Index>
}

private func contains(_ range: LivePreviewSourceRange, offset: Int) -> Bool {
    offset >= range.location && offset < range.endLocation
}
