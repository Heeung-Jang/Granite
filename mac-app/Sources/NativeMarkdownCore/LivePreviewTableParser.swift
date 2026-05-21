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

    public static func editableTable(
        _ table: LivePreviewTable,
        in source: String
    ) -> LivePreviewTable? {
        guard let current = parse(source).first(where: { $0.sourceRange == table.sourceRange }),
              current == table,
              current.header.count == current.alignments.count,
              current.bodyRows.allSatisfy({ $0.count == current.header.count }),
              rangesResolve(for: current, in: source),
              !hasAmbiguousEditableSyntax(current, in: source)
        else {
            return nil
        }
        return current
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
            let contentUpper = source[index..<range.upperBound].firstIndex { $0.isNewline } ?? range.upperBound
            let lineUpper = contentUpper < range.upperBound
                ? source.index(after: contentUpper)
                : range.upperBound
            lines.append(TableLine(contentRange: index..<contentUpper))
            index = lineUpper
        }

        return lines
    }

    private static func rangesResolve(for table: LivePreviewTable, in source: String) -> Bool {
        guard LivePreviewRangeMapper.stringRange(for: table.sourceRange, in: source) != nil,
              LivePreviewRangeMapper.stringRange(for: table.alignmentRowRange, in: source) != nil
        else {
            return false
        }
        return ([table.header] + table.bodyRows).flatMap { $0 }.allSatisfy { cell in
            guard let sourceRange = LivePreviewRangeMapper.stringRange(for: cell.sourceRange, in: source),
                  let contentRange = LivePreviewRangeMapper.stringRange(for: cell.contentRange, in: source)
            else {
                return false
            }
            return source[sourceRange].contains(source[contentRange])
                && String(source[contentRange]) == cell.text
        }
    }

    private static func hasAmbiguousEditableSyntax(_ table: LivePreviewTable, in source: String) -> Bool {
        guard let range = LivePreviewRangeMapper.stringRange(for: table.sourceRange, in: source) else {
            return true
        }
        return source[range].split(separator: "\n", omittingEmptySubsequences: false).contains { rawLine in
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return line.hasPrefix("    ")
                || line.hasPrefix("\t")
                || trimmed.hasPrefix(">")
                || trimmed.hasPrefix("- ")
                || line.contains("\\|")
                || hasInteriorEmptyCell(in: trimmed)
        }
    }

    private static func hasInteriorEmptyCell(in line: String) -> Bool {
        guard line.contains("||") else {
            return false
        }
        let withoutLeading = line.hasPrefix("|") ? String(line.dropFirst()) : line
        let withoutTrailing = withoutLeading.hasSuffix("|") ? String(withoutLeading.dropLast()) : withoutLeading
        return withoutTrailing.contains("||")
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

public enum LivePreviewTableRowInsert {
    public static func insertingRow(
        after target: LivePreviewTableCell,
        in source: String
    ) -> String? {
        guard let table = editableTable(containing: target, in: source),
              let tableRange = LivePreviewRangeMapper.stringRange(for: table.sourceRange, in: source),
              let rowIndex = rowIndex(containing: target, in: table)
        else {
            return nil
        }

        let lineEnding = preferredLineEnding(in: String(source[tableRange]))
        var lines = tableLinesText(in: String(source[tableRange]), lineEnding: lineEnding)
        let insertIndex = rowIndex == 0 ? 2 : rowIndex + 1
        guard insertIndex <= lines.count else {
            return nil
        }
        lines.insert(blankRow(columnCount: table.header.count, like: lines[0]), at: insertIndex)
        return replacingTable(in: source, range: tableRange, lines: lines, lineEnding: lineEnding)
    }

    private static func rowIndex(containing target: LivePreviewTableCell, in table: LivePreviewTable) -> Int? {
        if table.header.contains(target) {
            return 0
        }
        guard let bodyIndex = table.bodyRows.firstIndex(where: { $0.contains(target) }) else {
            return nil
        }
        return bodyIndex + 2
    }

    private static func blankRow(columnCount: Int, like line: String) -> String {
        let cells = Array(repeating: "  ", count: columnCount).joined(separator: "|")
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
            return "|" + cells + "|"
        }
        return cells
    }
}

public enum LivePreviewTableColumnInsert {
    public static func insertingColumn(
        after target: LivePreviewTableCell,
        in source: String
    ) -> String? {
        guard let table = editableTable(containing: target, in: source),
              let tableRange = LivePreviewRangeMapper.stringRange(for: table.sourceRange, in: source)
        else {
            return nil
        }

        let lineEnding = preferredLineEnding(in: String(source[tableRange]))
        let lines = tableLinesText(in: String(source[tableRange]), lineEnding: lineEnding)
        let editedLines = lines.enumerated().map { index, line in
            insertingCell(
                in: line,
                afterColumn: target.columnIndex,
                value: index == 1 ? "---" : ""
            )
        }
        guard editedLines.allSatisfy({ $0 != nil }) else {
            return nil
        }
        return replacingTable(in: source, range: tableRange, lines: editedLines.compactMap { $0 }, lineEnding: lineEnding)
    }

    private static func insertingCell(in line: String, afterColumn column: Int, value: String) -> String? {
        let hasLeadingPipe = line.trimmingCharacters(in: .whitespaces).hasPrefix("|")
        let hasTrailingPipe = line.trimmingCharacters(in: .whitespaces).hasSuffix("|")
        var parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        if hasLeadingPipe, !parts.isEmpty {
            parts.removeFirst()
        }
        if hasTrailingPipe, !parts.isEmpty {
            parts.removeLast()
        }
        guard parts.indices.contains(column) else {
            return nil
        }
        parts.insert(" \(value) ", at: column + 1)
        return (hasLeadingPipe ? "|" : "") + parts.joined(separator: "|") + (hasTrailingPipe ? "|" : "")
    }
}

private func editableTable(containing target: LivePreviewTableCell, in source: String) -> LivePreviewTable? {
    LivePreviewTableParser.parse(source).first { table in
        LivePreviewTableParser.editableTable(table, in: source) != nil
            && ([table.header] + table.bodyRows).flatMap { $0 }.contains(target)
    }
}

private func preferredLineEnding(in text: String) -> String {
    text.contains("\r\n") ? "\r\n" : "\n"
}

private func tableLinesText(in tableText: String, lineEnding: String) -> [String] {
    var lines = tableText.components(separatedBy: lineEnding)
    if tableText.hasSuffix(lineEnding) {
        lines.removeLast()
    }
    return lines
}

private func replacingTable(
    in source: String,
    range: Range<String.Index>,
    lines: [String],
    lineEnding: String
) -> String {
    let original = String(source[range])
    var replacement = lines.joined(separator: lineEnding)
    if original.hasSuffix(lineEnding) {
        replacement += lineEnding
    }
    var edited = source
    edited.replaceSubrange(range, with: replacement)
    return edited
}

private struct TableLine {
    var contentRange: Range<String.Index>
}

private func contains(_ range: LivePreviewSourceRange, offset: Int) -> Bool {
    offset >= range.location && offset < range.endLocation
}
