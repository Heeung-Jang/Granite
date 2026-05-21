import Foundation
import Testing
@testable import NativeMarkdownCore

@Test
func livePreviewTableParserParsesSimpleTableCellsAndRanges() throws {
    let source = try fixture("tables.md")
    let tables = LivePreviewTableParser.parse(source)

    #expect(tables.count == 3)
    let simple = tables[0]
    #expect(simple.header.map(\.text) == ["Name", "Status"])
    #expect(simple.alignments == [.none, .none])
    #expect(simple.bodyRows.map { $0.map(\.text) } == [
        ["Alpha", "Draft"],
        ["Beta", "Done"]
    ])
    #expect(simple.cellCount == 6)
    #expect(string(for: simple.alignmentRowRange, in: source) == "| --- | --- |")
    #expect(string(for: simple.bodyRows[0][0].contentRange, in: source) == "Alpha")
    #expect(string(for: simple.bodyRows[0][0].sourceRange, in: source) == " Alpha ")
}

@Test
func livePreviewTableParserParsesAlignmentMarkers() throws {
    let source = try fixture("tables.md")
    let tables = LivePreviewTableParser.parse(source)
    let aligned = tables[1]

    #expect(aligned.header.map(\.text) == ["Left", "Center", "Right"])
    #expect(aligned.alignments == [.left, .center, .right])
    #expect(aligned.bodyRows[1].map(\.text) == ["four", "five", "six"])
}

@Test
func livePreviewTableParserFindsEditableCellAtOffset() {
    let source = """
    | Name | Status |
    | --- | --- |
    | Alpha | Draft |
    """
    let draftOffset = (source as NSString).range(of: "Draft").location
    let cell = LivePreviewTableParser.cell(atUTF16Offset: draftOffset, in: source)

    #expect(cell?.text == "Draft")
    #expect(cell?.columnIndex == 1)
    #expect(LivePreviewTableParser.cell(atUTF16Offset: (source as NSString).range(of: "---").location, in: source) == nil)
}

@Test
func livePreviewEditableTableContractAcceptsSimpleTable() throws {
    let source = """
    | Name | Status |
    | --- | --- |
    | Alpha | Draft |
    """
    let table = try #require(LivePreviewTableParser.parse(source).first)

    #expect(LivePreviewTableParser.editableTable(table, in: source) == table)
}

@Test
func livePreviewEditableTableContractRejectsInconsistentRows() throws {
    let source = """
    | Name | Status |
    | --- | --- |
    | Alpha |
    """
    let table = try #require(LivePreviewTableParser.parse(source).first)

    #expect(LivePreviewTableParser.editableTable(table, in: source) == nil)
}

@Test
func livePreviewEditableTableContractRejectsStaleRanges() throws {
    let source = """
    | Name | Status |
    | --- | --- |
    | Alpha | Draft |
    """
    let table = try #require(LivePreviewTableParser.parse(source).first)

    #expect(LivePreviewTableParser.editableTable(table, in: "Prefix\n" + source) == nil)
}

@Test
func livePreviewEditableTableContractRejectsAmbiguousSyntax() throws {
    let escaped = """
    | Name | Status |
    | --- | --- |
    | Alpha \\| Beta | Draft |
    """
    let adjacentEmpty = """
    | Name | Status |
    | --- | --- |
    | Alpha || Draft |
    """
    let indented = """
        | Name | Status |
        | --- | --- |
        | Alpha | Draft |
    """

    for source in [escaped, adjacentEmpty, indented] {
        if let table = LivePreviewTableParser.parse(source).first {
            #expect(LivePreviewTableParser.editableTable(table, in: source) == nil)
        } else {
            #expect(LivePreviewTableParser.parse(source).isEmpty)
        }
    }
}

@Test
func livePreviewTableParserIgnoresMalformedTables() {
    let source = """
    | Missing | Alignment |
    | row without enough cells |
    """

    #expect(LivePreviewTableParser.parse(source).isEmpty)
}

@Test
func livePreviewTableCellEditRewritesOnlyCellContent() throws {
    let source = """
    | Name | Status |
    | --- | --- |
    | Alpha | Draft |
    """
    let table = try #require(LivePreviewTableParser.parse(source).first)
    let cell = table.bodyRows[0][1]
    let edited = try #require(LivePreviewTableCellEdit.replacing(
        cell: cell,
        with: "Final",
        in: source
    ))

    #expect(edited == """
    | Name | Status |
    | --- | --- |
    | Alpha | Final |
    """)
    #expect(edited.replacingOccurrences(of: "Final", with: "Draft") == source)
}

@Test
func livePreviewTableCellEditRejectsStructuralText() throws {
    let source = """
    | Name | Status |
    | --- | --- |
    | Alpha | Draft |
    """
    let table = try #require(LivePreviewTableParser.parse(source).first)
    let cell = table.bodyRows[0][1]

    #expect(LivePreviewTableCellEdit.replacing(cell: cell, with: "bad|value", in: source) == nil)
    #expect(LivePreviewTableCellEdit.replacing(cell: cell, with: "bad\nvalue", in: source) == nil)
}

@Test
func livePreviewTableCellEditRejectsStaleCellContent() throws {
    let source = """
    | Name | Status |
    | --- | --- |
    | Alpha | Draft |
    """
    let table = try #require(LivePreviewTableParser.parse(source).first)
    let cell = table.bodyRows[0][1]
    let changedSource = source.replacingOccurrences(of: "Draft", with: "Queued")

    #expect(LivePreviewTableCellEdit.replacing(cell: cell, with: "Final", in: changedSource) == nil)
}

@Test
func livePreviewTableRowInsertAddsBlankRowAfterHeaderAndBodyRows() throws {
    let source = """
    | Name | Status |
    | --- | --- |
    | Alpha | Draft |
    """
    let table = try #require(LivePreviewTableParser.parse(source).first)
    let afterHeader = try #require(LivePreviewTableRowInsert.insertingRow(after: table.header[0], in: source))
    let afterBody = try #require(LivePreviewTableRowInsert.insertingRow(after: table.bodyRows[0][0], in: source))

    #expect(afterHeader == """
    | Name | Status |
    | --- | --- |
    |  |  |
    | Alpha | Draft |
    """)
    #expect(afterBody == """
    | Name | Status |
    | --- | --- |
    | Alpha | Draft |
    |  |  |
    """)
}

@Test
func livePreviewTableRowInsertPreservesCRLFAndSurroundingText() throws {
    let source = "BOM\n| Name | Status |\r\n| --- | --- |\r\n| Alpha | Draft |\r\nEOF"
    let table = try #require(LivePreviewTableParser.parse(source).first)
    let edited = try #require(LivePreviewTableRowInsert.insertingRow(after: table.bodyRows[0][0], in: source))

    #expect(edited.hasPrefix("BOM\n"))
    #expect(edited.hasSuffix("EOF"))
    #expect(edited.contains("| Alpha | Draft |\r\n|  |  |\r\nEOF"))
}

@Test
func livePreviewTableColumnInsertAddsBlankColumnAfterTarget() throws {
    let source = """
    | Name | Status |
    | --- | --- |
    | Alpha | Draft |
    """
    let table = try #require(LivePreviewTableParser.parse(source).first)
    let edited = try #require(LivePreviewTableColumnInsert.insertingColumn(after: table.header[0], in: source))

    #expect(edited == """
    | Name |  | Status |
    | --- | --- | --- |
    | Alpha |  | Draft |
    """)
}

@Test
func livePreviewTableColumnInsertRejectsMalformedOrStaleTargets() throws {
    let source = """
    | Name | Status |
    | --- | --- |
    | Alpha |
    """
    let table = try #require(LivePreviewTableParser.parse(source).first)
    #expect(LivePreviewTableColumnInsert.insertingColumn(after: table.header[0], in: source) == nil)

    let validSource = """
    | Name | Status |
    | --- | --- |
    | Alpha | Draft |
    """
    let validTable = try #require(LivePreviewTableParser.parse(validSource).first)
    #expect(LivePreviewTableColumnInsert.insertingColumn(after: validTable.header[0], in: "Prefix\n" + validSource) == nil)
}

private func fixture(_ name: String) throws -> String {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let url = repoRoot
        .appendingPathComponent("fixtures/live-preview-vault", isDirectory: true)
        .appendingPathComponent(name, isDirectory: false)
    return try String(contentsOf: url, encoding: .utf8)
}

private func string(for sourceRange: LivePreviewSourceRange, in source: String) -> String? {
    guard let range = LivePreviewRangeMapper.stringRange(for: sourceRange, in: source) else {
        return nil
    }
    return String(source[range])
}
