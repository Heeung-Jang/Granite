import Foundation

public enum LivePreviewParser {
    public static func parse(_ source: String) -> LivePreviewParseResult {
        let fullRange = LivePreviewSourceRange(location: 0, length: (source as NSString).length)
        return parse(source, in: fullRange)
    }

    public static func parse(
        _ source: String,
        in requestedRange: LivePreviewSourceRange
    ) -> LivePreviewParseResult {
        let sourceRange = LivePreviewRangeMapper.clamped(requestedRange, in: source)
        guard let stringRange = LivePreviewRangeMapper.stringRange(for: sourceRange, in: source) else {
            return LivePreviewParseResult(sourceRange: sourceRange, blocks: [], isPartial: true)
        }

        let lines = LineIndex.lines(in: source, range: stringRange)
        var blocks: [LivePreviewBlockSpan] = []
        var index = 0

        if sourceRange.location == 0,
           let frontmatter = parseFrontmatter(source: source, lines: lines, index: &index) {
            blocks.append(frontmatter)
        }

        while index < lines.count {
            let line = lines[index]
            if line.trimmed.isEmpty {
                index += 1
                continue
            }

            if let block = parseFencedCode(source: source, lines: lines, index: &index) {
                blocks.append(block)
                continue
            }
            if let block = parseTable(source: source, lines: lines, index: &index) {
                blocks.append(block)
                continue
            }
            if let block = parseSingleLineBlock(source: source, line: line, index: &index) {
                blocks.append(block)
                continue
            }

            blocks.append(parseParagraph(source: source, lines: lines, index: &index))
        }

        return LivePreviewParseResult(
            sourceRange: sourceRange,
            blocks: blocks,
            isPartial: sourceRange.location != 0 || sourceRange.length != (source as NSString).length
        )
    }

    private static func parseFrontmatter(
        source: String,
        lines: [LineIndex.Line],
        index: inout Int
    ) -> LivePreviewBlockSpan? {
        guard index == 0, lines.indices.contains(index), lines[index].trimmed == "---" else {
            return nil
        }

        let start = index
        index += 1
        var isClosed = false
        while index < lines.count {
            if lines[index].trimmed == "---" {
                isClosed = true
                index += 1
                break
            }
            index += 1
        }
        return makeBlock(
            source: source,
            lines: lines,
            start: start,
            end: index,
            kind: .frontmatter(isClosed: isClosed),
            isInert: true
        )
    }

    private static func parseFencedCode(
        source: String,
        lines: [LineIndex.Line],
        index: inout Int
    ) -> LivePreviewBlockSpan? {
        let line = lines[index]
        guard let opener = fenceOpener(in: line.trimmed) else {
            return nil
        }

        let start = index
        index += 1
        var isClosed = false
        while index < lines.count {
            if lines[index].trimmed.hasPrefix(opener.fence) {
                isClosed = true
                index += 1
                break
            }
            index += 1
        }

        return makeBlock(
            source: source,
            lines: lines,
            start: start,
            end: index,
            kind: .fencedCode(fence: opener.fence, info: opener.info, isClosed: isClosed),
            isInert: true
        )
    }

    private static func parseTable(
        source: String,
        lines: [LineIndex.Line],
        index: inout Int
    ) -> LivePreviewBlockSpan? {
        guard lines.indices.contains(index + 1),
              lines[index].trimmed.contains("|"),
              isTableAlignment(lines[index + 1].trimmed)
        else {
            return nil
        }

        let start = index
        index += 2
        while index < lines.count, lines[index].trimmed.contains("|"), !lines[index].trimmed.isEmpty {
            index += 1
        }

        return makeBlock(
            source: source,
            lines: lines,
            start: start,
            end: index,
            kind: .table
        )
    }

    private static func parseSingleLineBlock(
        source: String,
        line: LineIndex.Line,
        index: inout Int
    ) -> LivePreviewBlockSpan? {
        let trimmed = line.trimmed
        let kind: LivePreviewBlockKind?
        if let level = headingLevel(in: trimmed) {
            kind = .heading(level: level)
        } else if isTaskList(trimmed, checked: true) {
            kind = .taskList(isChecked: true)
        } else if isTaskList(trimmed, checked: false) {
            kind = .taskList(isChecked: false)
        } else if isUnorderedList(trimmed) {
            kind = .unorderedList
        } else if isOrderedList(trimmed) {
            kind = .orderedList
        } else if let calloutKind = calloutKind(in: trimmed) {
            kind = .callout(kind: calloutKind)
        } else if trimmed.hasPrefix(">") {
            kind = .blockquote
        } else if isEmbedLine(trimmed) {
            kind = .embed
        } else {
            kind = nil
        }

        guard let kind else {
            return nil
        }
        index += 1
        return makeBlock(
            source: source,
            lines: [line],
            start: 0,
            end: 1,
            kind: kind,
            isInert: kind == .embed
        )
    }

    private static func parseParagraph(
        source: String,
        lines: [LineIndex.Line],
        index: inout Int
    ) -> LivePreviewBlockSpan {
        let start = index
        index += 1
        while index < lines.count,
              !lines[index].trimmed.isEmpty,
              !startsBlock(lines[index], nextLine: lines.indices.contains(index + 1) ? lines[index + 1] : nil) {
            index += 1
        }
        return makeBlock(
            source: source,
            lines: lines,
            start: start,
            end: index,
            kind: .paragraph
        )
    }

    private static func makeBlock(
        source: String,
        lines: [LineIndex.Line],
        start: Int,
        end: Int,
        kind: LivePreviewBlockKind,
        isInert: Bool = false
    ) -> LivePreviewBlockSpan {
        let lower = lines[start].fullRange.lowerBound
        let upper = lines[end - 1].fullRange.upperBound
        let sourceRange = LivePreviewRangeMapper.sourceRange(for: lower..<upper, in: source)
        let contentRange = LivePreviewRangeMapper.sourceRange(
            for: lines[start].contentRange.lowerBound..<lines[end - 1].contentRange.upperBound,
            in: source
        )
        return LivePreviewBlockSpan(
            kind: kind,
            sourceRange: sourceRange,
            contentRange: contentRange,
            inlineSpans: parseInlineSpans(source, in: contentRange),
            isInert: isInert,
            isEditable: true
        )
    }

    private static func parseInlineSpans(
        _ source: String,
        in sourceRange: LivePreviewSourceRange
    ) -> [LivePreviewInlineSpan] {
        let range = sourceRange.nsRange
        var spans: [LivePreviewInlineSpan] = []
        spans += matches(in: source, range: range, regex: inlineCodeRegex, kind: .inlineCode)
        spans += matches(in: source, range: range, regex: strongRegex, kind: .strong)
        spans += matches(in: source, range: range, regex: emphasisRegex, kind: .emphasis)
        spans += matches(in: source, range: range, regex: wikiLinkRegex, kind: .wikiLink) { matchText in
            matchText.hasPrefix("!")
        }
        spans += matches(in: source, range: range, regex: markdownLinkRegex, kind: .markdownLink) { matchText in
            matchText.hasPrefix("!")
        }
        spans += tagMatches(in: source, range: range)
        return spans.sorted {
            if $0.sourceRange.location == $1.sourceRange.location {
                return $0.sourceRange.length < $1.sourceRange.length
            }
            return $0.sourceRange.location < $1.sourceRange.location
        }
    }

    private static func matches(
        in source: String,
        range: NSRange,
        regex: NSRegularExpression,
        kind: LivePreviewInlineKind,
        isInert: (String) -> Bool = { _ in false }
    ) -> [LivePreviewInlineSpan] {
        regex.matches(in: source, range: range).map { match in
            let matchText = (source as NSString).substring(with: match.range)
            return LivePreviewInlineSpan(
                kind: kind,
                sourceRange: LivePreviewSourceRange(location: match.range.location, length: match.range.length),
                isInert: isInert(matchText)
            )
        }
    }

    private static func tagMatches(in source: String, range: NSRange) -> [LivePreviewInlineSpan] {
        tagRegex.matches(in: source, range: range).compactMap { match in
            var tagRange = match.range(at: 2)
            guard tagRange.location != NSNotFound, tagRange.length > 1 else {
                return nil
            }
            tagRange.length = min(tagRange.length, (source as NSString).length - tagRange.location)
            return LivePreviewInlineSpan(
                kind: .tag,
                sourceRange: LivePreviewSourceRange(location: tagRange.location, length: tagRange.length)
            )
        }
    }

    private static func startsBlock(_ line: LineIndex.Line, nextLine: LineIndex.Line?) -> Bool {
        let trimmed = line.trimmed
        return headingLevel(in: trimmed) != nil ||
            fenceOpener(in: trimmed) != nil ||
            isTaskList(trimmed, checked: true) ||
            isTaskList(trimmed, checked: false) ||
            isUnorderedList(trimmed) ||
            isOrderedList(trimmed) ||
            trimmed.hasPrefix(">") ||
            isEmbedLine(trimmed) ||
            (trimmed.contains("|") && nextLine.map { isTableAlignment($0.trimmed) } == true)
    }

    private static func headingLevel(in trimmedLine: String) -> Int? {
        let hashes = trimmedLine.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes),
              trimmedLine.dropFirst(hashes).first == " "
        else {
            return nil
        }
        return hashes
    }

    private static func fenceOpener(in trimmedLine: String) -> (fence: String, info: String?)? {
        let fence: String
        if trimmedLine.hasPrefix("```") {
            fence = "```"
        } else if trimmedLine.hasPrefix("~~~") {
            fence = "~~~"
        } else {
            return nil
        }
        let info = trimmedLine.dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines)
        return (fence, info.isEmpty ? nil : info)
    }

    private static func isTaskList(_ trimmedLine: String, checked: Bool) -> Bool {
        let token = checked ? "[x]" : "[ ]"
        let lowercase = trimmedLine.lowercased()
        return lowercase.hasPrefix("- \(token)") ||
            lowercase.hasPrefix("* \(token)") ||
            lowercase.hasPrefix("+ \(token)")
    }

    private static func isUnorderedList(_ trimmedLine: String) -> Bool {
        trimmedLine.hasPrefix("- ") || trimmedLine.hasPrefix("* ") || trimmedLine.hasPrefix("+ ")
    }

    private static func isOrderedList(_ trimmedLine: String) -> Bool {
        orderedListRegex.firstMatch(
            in: trimmedLine,
            range: NSRange(location: 0, length: (trimmedLine as NSString).length)
        ) != nil
    }

    private static func calloutKind(in trimmedLine: String) -> String? {
        guard trimmedLine.hasPrefix(">") else {
            return nil
        }
        let body = trimmedLine.dropFirst().trimmingCharacters(in: .whitespaces)
        guard body.hasPrefix("[!") else {
            return nil
        }
        let end = body.firstIndex(of: "]") ?? body.endIndex
        let kindStart = body.index(body.startIndex, offsetBy: 2)
        let kind = String(body[kindStart..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return kind.isEmpty ? nil : kind.lowercased()
    }

    private static func isEmbedLine(_ trimmedLine: String) -> Bool {
        trimmedLine.hasPrefix("![[") || trimmedLine.hasPrefix("![")
    }

    private static func isTableAlignment(_ trimmedLine: String) -> Bool {
        let cells = trimmedLine
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard cells.count >= 2 else {
            return false
        }
        return cells.allSatisfy { cell in
            tableAlignmentCellRegex.firstMatch(
                in: cell,
                range: NSRange(location: 0, length: (cell as NSString).length)
            ) != nil
        }
    }

    private static let orderedListRegex = regex("^\\d+[.)]\\s+")
    private static let tableAlignmentCellRegex = regex("^:?-{3,}:?$")
    private static let inlineCodeRegex = regex("`[^`\\n]+`")
    private static let strongRegex = regex("\\*\\*[^*\\n]+\\*\\*|__[^_\\n]+__")
    private static let emphasisRegex = regex("(?<!\\*)\\*[^*\\n]+\\*(?!\\*)|_[^_\\n]+_")
    private static let wikiLinkRegex = regex("!?\\[\\[[^\\]\\n]+\\]\\]")
    private static let markdownLinkRegex = regex("!?\\[[^\\]\\n]+\\]\\([^\\)\\n]+\\)")
    private static let tagRegex = regex("(^|\\s)(#[\\p{L}\\p{N}_/-]+)")

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }
}

private enum LineIndex {
    struct Line {
        var fullRange: Range<String.Index>
        var contentRange: Range<String.Index>
        var trimmed: String
    }

    static func lines(in source: String, range: Range<String.Index>) -> [Line] {
        var lines: [Line] = []
        var index = range.lowerBound

        while index < range.upperBound {
            let lineUpper = source[index..<range.upperBound].firstIndex(of: "\n").map {
                source.index(after: $0)
            } ?? range.upperBound
            let contentUpper = lineUpper > index && source[source.index(before: lineUpper)] == "\n"
                ? source.index(before: lineUpper)
                : lineUpper
            let contentRange = index..<contentUpper
            lines.append(Line(
                fullRange: index..<lineUpper,
                contentRange: contentRange,
                trimmed: String(source[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            ))
            index = lineUpper
        }

        return lines
    }
}
