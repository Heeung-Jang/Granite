import Foundation

public struct LivePreviewPropertyBlock: Equatable, Sendable {
    var sourceRange: LivePreviewSourceRange
    public var rows: [LivePreviewPropertyRow]
    public var tokenRanges: [LivePreviewSourceRange]
    public var isClosed: Bool

    init(
        sourceRange: LivePreviewSourceRange,
        rows: [LivePreviewPropertyRow],
        tokenRanges: [LivePreviewSourceRange],
        isClosed: Bool
    ) {
        self.sourceRange = sourceRange
        self.rows = rows
        self.tokenRanges = tokenRanges
        self.isClosed = isClosed
    }
}

public struct LivePreviewPropertyRow: Equatable, Sendable {
    public var key: String
    public var value: String
    public var keyRange: LivePreviewSourceRange
    public var valueRange: LivePreviewSourceRange?

    init(
        key: String,
        value: String,
        keyRange: LivePreviewSourceRange,
        valueRange: LivePreviewSourceRange?
    ) {
        self.key = key
        self.value = value
        self.keyRange = keyRange
        self.valueRange = valueRange
    }
}

public enum LivePreviewPropertyParser {
    private static let maxFrontmatterLines = 512
    private static let maxFrontmatterUTF16Length = 16_384

    public static func parse(_ source: String) -> LivePreviewPropertyBlock? {
        let lines = indexedFrontmatterLines(in: source)
        guard lines.first?.trimmed == "---" else {
            return nil
        }

        var closingIndex: Int?
        for index in lines.indices.dropFirst() where lines[index].trimmed == "---" {
            closingIndex = index
            break
        }

        guard let closingIndex else {
            let upper = lines.last?.fullRange.upperBound ?? lines[0].contentRange.upperBound
            let sourceRange = LivePreviewRangeMapper.sourceRange(for: lines[0].contentRange.lowerBound..<upper, in: source)
            return LivePreviewPropertyBlock(
                sourceRange: sourceRange,
                rows: [],
                tokenRanges: [],
                isClosed: false
            )
        }

        var rows: [LivePreviewPropertyRow] = []
        var tokenRanges: [LivePreviewSourceRange] = [
            LivePreviewRangeMapper.sourceRange(for: lines[0].contentRange, in: source),
            LivePreviewRangeMapper.sourceRange(for: lines[closingIndex].contentRange, in: source)
        ]
        var currentKey: (key: String, range: LivePreviewSourceRange)?

        for line in lines[1..<closingIndex] {
            if let row = propertyRow(in: line, source: source) {
                rows.append(row.row)
                tokenRanges.append(row.tokenRange)
                currentKey = (row.row.key, row.row.keyRange)
            } else if let currentKey,
                      let listRow = listItemRow(in: line, source: source, key: currentKey) {
                rows.append(listRow.row)
                tokenRanges.append(listRow.tokenRange)
            }
        }

        return LivePreviewPropertyBlock(
            sourceRange: LivePreviewRangeMapper.sourceRange(
                for: lines[0].fullRange.lowerBound..<lines[closingIndex].fullRange.upperBound,
                in: source
            ),
            rows: rows,
            tokenRanges: tokenRanges,
            isClosed: true
        )
    }

    private static func propertyRow(
        in line: IndexedLine,
        source: String
    ) -> (row: LivePreviewPropertyRow, tokenRange: LivePreviewSourceRange)? {
        guard let colon = source[line.contentRange].firstIndex(of: ":") else {
            return nil
        }
        let keyRange = trimmedRange(line.contentRange.lowerBound..<colon, in: source)
        guard !keyRange.isEmpty else {
            return nil
        }
        let valueRange = trimmedRange(source.index(after: colon)..<line.contentRange.upperBound, in: source)
        let key = String(source[keyRange])
        let value = String(source[valueRange])
        return (
            LivePreviewPropertyRow(
                key: key,
                value: value,
                keyRange: LivePreviewRangeMapper.sourceRange(for: keyRange, in: source),
                valueRange: valueRange.isEmpty ? nil : LivePreviewRangeMapper.sourceRange(for: valueRange, in: source)
            ),
            LivePreviewRangeMapper.sourceRange(for: colon..<source.index(after: colon), in: source)
        )
    }

    private static func listItemRow(
        in line: IndexedLine,
        source: String,
        key: (key: String, range: LivePreviewSourceRange)
    ) -> (row: LivePreviewPropertyRow, tokenRange: LivePreviewSourceRange)? {
        guard let dash = source[line.contentRange].firstIndex(of: "-") else {
            return nil
        }
        let beforeDash = line.contentRange.lowerBound..<dash
        guard source[beforeDash].allSatisfy(\.isWhitespace) else {
            return nil
        }
        let tokenEnd = source.index(after: dash)
        let valueRange = trimmedRange(tokenEnd..<line.contentRange.upperBound, in: source)
        guard !valueRange.isEmpty else {
            return nil
        }
        return (
            LivePreviewPropertyRow(
                key: key.key,
                value: String(source[valueRange]),
                keyRange: key.range,
                valueRange: LivePreviewRangeMapper.sourceRange(for: valueRange, in: source)
            ),
            LivePreviewRangeMapper.sourceRange(for: line.contentRange.lowerBound..<tokenEnd, in: source)
        )
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

    private static func indexedFrontmatterLines(in source: String) -> [IndexedLine] {
        var lines: [IndexedLine] = []
        var index = source.startIndex
        while index < source.endIndex, lines.count < maxFrontmatterLines {
            let upper = source[index...].firstIndex(of: "\n").map {
                source.index(after: $0)
            } ?? source.endIndex
            let contentUpper = upper > index && source[source.index(before: upper)] == "\n"
                ? source.index(before: upper)
                : upper
            let contentRange = index..<contentUpper
            lines.append(IndexedLine(
                fullRange: index..<upper,
                contentRange: contentRange,
                trimmed: String(source[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            ))
            let scannedLength = NSRange(source.startIndex..<upper, in: source).length
            if lines.count > 1 && lines.last?.trimmed == "---" {
                break
            }
            if scannedLength >= maxFrontmatterUTF16Length {
                break
            }
            index = upper
        }
        return lines
    }
}

private struct IndexedLine {
    var fullRange: Range<String.Index>
    var contentRange: Range<String.Index>
    var trimmed: String
}
