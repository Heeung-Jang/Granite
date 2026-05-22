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

public enum LivePreviewTableOperation: Equatable, Sendable {
    case insertRowBefore
    case insertRowAfter
    case duplicateRow
    case removeRow
    case moveRowUp
    case moveRowDown
    case insertColumnBefore
    case insertColumnAfter
    case duplicateColumn
    case removeColumn
    case moveColumnLeft
    case moveColumnRight
    case alignColumn(LivePreviewTableAlignment)
    case sortColumnAscending
    case sortColumnDescending

    public var identifier: String {
        switch self {
        case .insertRowBefore:
            "row.insertBefore"
        case .insertRowAfter:
            "row.insertAfter"
        case .duplicateRow:
            "row.duplicate"
        case .removeRow:
            "row.remove"
        case .moveRowUp:
            "row.moveUp"
        case .moveRowDown:
            "row.moveDown"
        case .insertColumnBefore:
            "column.insertBefore"
        case .insertColumnAfter:
            "column.insertAfter"
        case .duplicateColumn:
            "column.duplicate"
        case .removeColumn:
            "column.remove"
        case .moveColumnLeft:
            "column.moveLeft"
        case .moveColumnRight:
            "column.moveRight"
        case .alignColumn(let alignment):
            "column.align.\(alignment.identifier)"
        case .sortColumnAscending:
            "column.sortAscending"
        case .sortColumnDescending:
            "column.sortDescending"
        }
    }

    public var actionName: String {
        switch self {
        case .insertRowBefore:
            "Insert Row Before"
        case .insertRowAfter:
            "Insert Row After"
        case .duplicateRow:
            "Duplicate Row"
        case .removeRow:
            "Remove Row"
        case .moveRowUp:
            "Move Row Up"
        case .moveRowDown:
            "Move Row Down"
        case .insertColumnBefore:
            "Insert Column Before"
        case .insertColumnAfter:
            "Insert Column After"
        case .duplicateColumn:
            "Duplicate Column"
        case .removeColumn:
            "Remove Column"
        case .moveColumnLeft:
            "Move Column Left"
        case .moveColumnRight:
            "Move Column Right"
        case .alignColumn:
            "Align Column"
        case .sortColumnAscending:
            "Sort Column Ascending"
        case .sortColumnDescending:
            "Sort Column Descending"
        }
    }
}

public struct LivePreviewTableSourceEdit: Equatable, Sendable {
    public var replacementRange: LivePreviewSourceRange
    public var replacement: String
    public var editedSource: String
    public var operationID: String
    public var actionName: String

    public init(
        replacementRange: LivePreviewSourceRange,
        replacement: String,
        editedSource: String,
        operationID: String,
        actionName: String
    ) {
        self.replacementRange = replacementRange
        self.replacement = replacement
        self.editedSource = editedSource
        self.operationID = operationID
        self.actionName = actionName
    }
}

public enum LivePreviewTableEdit {
    public static func applying(
        _ operation: LivePreviewTableOperation,
        to target: LivePreviewTableCell,
        in source: String
    ) -> LivePreviewTableSourceEdit? {
        guard let table = editableTable(containing: target, in: source),
              let tableRange = LivePreviewRangeMapper.stringRange(for: table.sourceRange, in: source),
              let rowIndex = rowIndex(containing: target, in: table)
        else {
            return nil
        }

        let tableText = String(source[tableRange])
        guard var tableSource = EditableTableSource(tableText: tableText),
              tableSource.columnCount == table.header.count,
              tableSource.bodyRowCount == table.bodyRows.count
        else {
            return nil
        }

        guard tableSource.apply(
            operation,
            rowIndex: rowIndex,
            columnIndex: target.columnIndex
        ) else {
            return nil
        }

        let replacement = tableSource.rendered()
        guard replacement != tableText else {
            return nil
        }

        var edited = source
        edited.replaceSubrange(tableRange, with: replacement)
        return LivePreviewTableSourceEdit(
            replacementRange: table.sourceRange,
            replacement: replacement,
            editedSource: edited,
            operationID: operation.identifier,
            actionName: operation.actionName
        )
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
}

public enum LivePreviewTableRowInsert {
    public static func insertingRow(
        after target: LivePreviewTableCell,
        in source: String
    ) -> String? {
        LivePreviewTableEdit.applying(.insertRowAfter, to: target, in: source)?.editedSource
    }
}

public enum LivePreviewTableColumnInsert {
    public static func insertingColumn(
        after target: LivePreviewTableCell,
        in source: String
    ) -> String? {
        LivePreviewTableEdit.applying(.insertColumnAfter, to: target, in: source)?.editedSource
    }
}

private struct EditableTableSource {
    var lines: [EditableTableSourceLine]
    var lineEnding: String
    var preservesFinalLineEnding: Bool

    init?(tableText: String) {
        let lineEnding = preferredLineEnding(in: tableText)
        let rawLines = tableLinesText(in: tableText, lineEnding: lineEnding)
        let parsedLines = rawLines.compactMap(EditableTableSourceLine.init(line:))
        guard rawLines.count == parsedLines.count,
              parsedLines.count >= 2,
              let columnCount = parsedLines.first?.cells.count,
              columnCount >= 2,
              parsedLines.allSatisfy({ $0.cells.count == columnCount })
        else {
            return nil
        }
        lines = parsedLines
        self.lineEnding = lineEnding
        preservesFinalLineEnding = tableText.hasSuffix(lineEnding)
    }

    var columnCount: Int {
        lines.first?.cells.count ?? 0
    }

    var bodyRowCount: Int {
        max(0, lines.count - 2)
    }

    mutating func apply(
        _ operation: LivePreviewTableOperation,
        rowIndex: Int,
        columnIndex: Int
    ) -> Bool {
        switch operation {
        case .insertRowBefore:
            insertRow(relativeTo: rowIndex, before: true)
        case .insertRowAfter:
            insertRow(relativeTo: rowIndex, before: false)
        case .duplicateRow:
            duplicateRow(rowIndex)
        case .removeRow:
            removeRow(rowIndex)
        case .moveRowUp:
            moveRow(rowIndex, offset: -1)
        case .moveRowDown:
            moveRow(rowIndex, offset: 1)
        case .insertColumnBefore:
            insertColumn(relativeTo: columnIndex, before: true)
        case .insertColumnAfter:
            insertColumn(relativeTo: columnIndex, before: false)
        case .duplicateColumn:
            duplicateColumn(columnIndex)
        case .removeColumn:
            removeColumn(columnIndex)
        case .moveColumnLeft:
            moveColumn(columnIndex, offset: -1)
        case .moveColumnRight:
            moveColumn(columnIndex, offset: 1)
        case .alignColumn(let alignment):
            alignColumn(columnIndex, alignment: alignment)
        case .sortColumnAscending:
            sortColumn(columnIndex, ascending: true)
        case .sortColumnDescending:
            sortColumn(columnIndex, ascending: false)
        }
    }

    func rendered() -> String {
        var rendered = lines.map(\.rendered).joined(separator: lineEnding)
        if preservesFinalLineEnding {
            rendered += lineEnding
        }
        return rendered
    }

    private mutating func insertRow(relativeTo rowIndex: Int, before: Bool) -> Bool {
        guard lines.indices.contains(rowIndex) else {
            return false
        }
        let insertIndex = rowIndex == 0 ? 2 : (before ? rowIndex : rowIndex + 1)
        guard insertIndex <= lines.count else {
            return false
        }
        lines.insert(EditableTableSourceLine.blank(columnCount: columnCount, like: lines[0]), at: insertIndex)
        return true
    }

    private mutating func duplicateRow(_ rowIndex: Int) -> Bool {
        guard isBodyRow(rowIndex), lines.indices.contains(rowIndex) else {
            return false
        }
        lines.insert(lines[rowIndex], at: rowIndex + 1)
        return true
    }

    private mutating func removeRow(_ rowIndex: Int) -> Bool {
        guard isBodyRow(rowIndex), lines.indices.contains(rowIndex), bodyRowCount > 1 else {
            return false
        }
        lines.remove(at: rowIndex)
        return true
    }

    private mutating func moveRow(_ rowIndex: Int, offset: Int) -> Bool {
        let destination = rowIndex + offset
        guard isBodyRow(rowIndex),
              isBodyRow(destination),
              lines.indices.contains(rowIndex),
              lines.indices.contains(destination)
        else {
            return false
        }
        lines.swapAt(rowIndex, destination)
        return true
    }

    private mutating func insertColumn(relativeTo columnIndex: Int, before: Bool) -> Bool {
        guard isColumn(columnIndex) else {
            return false
        }
        let insertIndex = before ? columnIndex : columnIndex + 1
        guard insertIndex <= columnCount else {
            return false
        }
        for index in lines.indices {
            lines[index].cells.insert(index == 1 ? " --- " : "  ", at: insertIndex)
        }
        return true
    }

    private mutating func duplicateColumn(_ columnIndex: Int) -> Bool {
        guard isColumn(columnIndex) else {
            return false
        }
        for index in lines.indices {
            lines[index].cells.insert(lines[index].cells[columnIndex], at: columnIndex + 1)
        }
        return true
    }

    private mutating func removeColumn(_ columnIndex: Int) -> Bool {
        guard isColumn(columnIndex), columnCount > 2 else {
            return false
        }
        for index in lines.indices {
            lines[index].cells.remove(at: columnIndex)
        }
        return true
    }

    private mutating func moveColumn(_ columnIndex: Int, offset: Int) -> Bool {
        let destination = columnIndex + offset
        guard isColumn(columnIndex), isColumn(destination) else {
            return false
        }
        for index in lines.indices {
            lines[index].cells.swapAt(columnIndex, destination)
        }
        return true
    }

    private mutating func alignColumn(
        _ columnIndex: Int,
        alignment: LivePreviewTableAlignment
    ) -> Bool {
        guard isColumn(columnIndex), lines.indices.contains(1) else {
            return false
        }
        lines[1].cells[columnIndex] = " \(alignment.sourceMarker) "
        return true
    }

    private mutating func sortColumn(_ columnIndex: Int, ascending: Bool) -> Bool {
        guard isColumn(columnIndex), bodyRowCount > 1 else {
            return false
        }
        let sortedBodyRows = lines[2..<lines.count].enumerated().sorted { lhs, rhs in
            let lhsText = lhs.element.cells[columnIndex].trimmingCharacters(in: .whitespaces)
            let rhsText = rhs.element.cells[columnIndex].trimmingCharacters(in: .whitespaces)
            let comparison = lhsText.localizedStandardCompare(rhsText)
            if comparison == .orderedSame {
                return lhs.offset < rhs.offset
            }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }.map(\.element)

        lines.replaceSubrange(2..<lines.count, with: sortedBodyRows)
        return true
    }

    private func isBodyRow(_ rowIndex: Int) -> Bool {
        rowIndex >= 2
    }

    private func isColumn(_ columnIndex: Int) -> Bool {
        columnIndex >= 0 && columnIndex < columnCount
    }
}

private struct EditableTableSourceLine {
    var leadingWhitespace: String
    var trailingWhitespace: String
    var hasLeadingPipe: Bool
    var hasTrailingPipe: Bool
    var cells: [String]

    init?(line: String) {
        guard let leadingEnd = line.firstIndex(where: { !$0.isWhitespace }),
              let trailingContentEnd = line.lastIndex(where: { !$0.isWhitespace })
        else {
            return nil
        }
        let trailingStart = line.index(after: trailingContentEnd)
        leadingWhitespace = String(line[..<leadingEnd])
        trailingWhitespace = trailingStart < line.endIndex ? String(line[trailingStart...]) : ""

        let core = String(line[leadingEnd..<trailingStart])
        hasLeadingPipe = core.hasPrefix("|")
        hasTrailingPipe = core.hasSuffix("|")

        var cellText = core
        if hasLeadingPipe {
            cellText.removeFirst()
        }
        if hasTrailingPipe, !cellText.isEmpty {
            cellText.removeLast()
        }
        cells = cellText.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard !cells.isEmpty else {
            return nil
        }
    }

    var rendered: String {
        leadingWhitespace
            + (hasLeadingPipe ? "|" : "")
            + cells.joined(separator: "|")
            + (hasTrailingPipe ? "|" : "")
            + trailingWhitespace
    }

    static func blank(columnCount: Int, like line: EditableTableSourceLine) -> EditableTableSourceLine {
        var blank = line
        blank.cells = Array(repeating: "  ", count: columnCount)
        return blank
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

private struct TableLine {
    var contentRange: Range<String.Index>
}

private func contains(_ range: LivePreviewSourceRange, offset: Int) -> Bool {
    offset >= range.location && offset < range.endLocation
}

private extension LivePreviewTableAlignment {
    var identifier: String {
        switch self {
        case .none:
            "none"
        case .left:
            "left"
        case .center:
            "center"
        case .right:
            "right"
        }
    }

    var sourceMarker: String {
        switch self {
        case .none:
            "---"
        case .left:
            ":---"
        case .center:
            ":---:"
        case .right:
            "---:"
        }
    }
}
