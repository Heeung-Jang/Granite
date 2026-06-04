import Foundation

public struct FrontmatterBlockLocation: Equatable {
    public var fullRange: Range<String.Index>
    public var contentRange: Range<String.Index>
    public var openingDelimiterRange: Range<String.Index>
    public var closingDelimiterRange: Range<String.Index>
    public var insertionIndex: String.Index
    public var newline: String

    public var sourceRange: LivePreviewSourceRange
    public var contentSourceRange: LivePreviewSourceRange
    public var closingSourceRange: LivePreviewSourceRange
}

public enum FrontmatterBlockLocator {
    public static func locateClosedBlock(in source: String) -> FrontmatterBlockLocation? {
        let scanStart = source.hasPrefix("\u{feff}") ? source.index(after: source.startIndex) : source.startIndex
        let opening = line(at: scanStart, upperBound: source.endIndex, in: source)
        guard let opening, opening.trimmed == "---" else {
            return nil
        }

        var cursor = opening.fullRange.upperBound
        var closing: FrontmatterIndexedLine?
        while cursor < source.endIndex {
            guard let nextLine = line(at: cursor, upperBound: source.endIndex, in: source) else {
                break
            }
            if nextLine.trimmed == "---" || nextLine.trimmed == "..." {
                closing = nextLine
                break
            }
            cursor = nextLine.fullRange.upperBound
        }

        guard let closing else {
            return nil
        }

        let contentStart = opening.fullRange.upperBound
        let contentEnd = closing.fullRange.lowerBound
        let fullRange = opening.fullRange.lowerBound..<closing.fullRange.upperBound
        let newline = opening.newline ?? dominantNewline(in: source)

        return FrontmatterBlockLocation(
            fullRange: fullRange,
            contentRange: contentStart..<contentEnd,
            openingDelimiterRange: opening.contentRange,
            closingDelimiterRange: closing.contentRange,
            insertionIndex: closing.fullRange.lowerBound,
            newline: newline,
            sourceRange: LivePreviewRangeMapper.sourceRange(for: fullRange, in: source),
            contentSourceRange: LivePreviewRangeMapper.sourceRange(for: contentStart..<contentEnd, in: source),
            closingSourceRange: LivePreviewRangeMapper.sourceRange(for: closing.contentRange, in: source)
        )
    }

    public static func insertionIndexForNewBlock(in source: String) -> String.Index {
        if source.hasPrefix("\u{feff}") {
            return source.index(after: source.startIndex)
        }
        return source.startIndex
    }

    public static func dominantNewline(in source: String) -> String {
        source.contains("\r\n") ? "\r\n" : "\n"
    }

    private static func line(
        at index: String.Index,
        upperBound: String.Index,
        in source: String
    ) -> FrontmatterIndexedLine? {
        guard index < upperBound else {
            return nil
        }
        let lineStart = index
        let newlineIndex = source[index..<upperBound].firstIndex { $0.isNewline }
        let lineEnd = newlineIndex.map { source.index(after: $0) } ?? upperBound
        let contentEnd: String.Index
        let newline: String?
        if let newlineIndex {
            contentEnd = newlineIndex
            newline = String(source[newlineIndex]) == "\r\n" ? "\r\n" : "\n"
        } else {
            contentEnd = lineEnd
            newline = nil
        }

        let contentRange = lineStart..<contentEnd
        return FrontmatterIndexedLine(
            fullRange: lineStart..<lineEnd,
            contentRange: contentRange,
            trimmed: String(source[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines),
            newline: newline
        )
    }

    static func indexedLines(in source: String) -> [FrontmatterIndexedLine] {
        var lines: [FrontmatterIndexedLine] = []
        var index = source.startIndex
        while index < source.endIndex {
            guard let nextLine = line(at: index, upperBound: source.endIndex, in: source) else {
                break
            }
            lines.append(nextLine)
            index = nextLine.fullRange.upperBound
            if lines.count > 2, lines.last?.trimmed == "---" || lines.last?.trimmed == "..." {
                break
            }
        }
        return lines
    }
}

struct FrontmatterIndexedLine {
    var fullRange: Range<String.Index>
    var contentRange: Range<String.Index>
    var trimmed: String
    var newline: String?
}
