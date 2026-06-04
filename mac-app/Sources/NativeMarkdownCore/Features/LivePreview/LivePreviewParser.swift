import Foundation

public enum LivePreviewParser {
    private static let maxFrontmatterDelimiterLines = 512
    private static let maxFrontmatterDelimiterUTF16Length = 16_384

    private struct FenceContext {
        var fence: String
        var info: String?
    }

    private enum FenceContextResolution {
        case resolved(FenceContext?)
        case unresolved
    }

    public static func parse(_ source: String, sourceVersion: UInt64 = 0) -> LivePreviewParseResult {
        let fullRange = LivePreviewSourceRange(location: 0, length: (source as NSString).length)
        return parse(source, in: fullRange, sourceVersion: sourceVersion)
    }

    public static func parse(
        _ source: String,
        in requestedRange: LivePreviewSourceRange,
        sourceVersion: UInt64 = 0
    ) -> LivePreviewParseResult {
        let requestedSourceRange = LivePreviewRangeMapper.clamped(requestedRange, in: source)
        guard let requestedStringRange = LivePreviewRangeMapper.stringRange(for: requestedSourceRange, in: source) else {
            return LivePreviewParseResult(
                sourceVersion: sourceVersion,
                sourceRange: requestedSourceRange,
                blocks: [],
                isPartial: true
            )
        }
        let stringRange = lineAlignedRange(for: requestedStringRange, in: source)
        let sourceRange = LivePreviewRangeMapper.sourceRange(for: stringRange, in: source)

        let lines = LineIndex.lines(in: source, range: stringRange)
        let frontmatterDelimiterRanges = frontmatterDelimiterRanges(in: source)
        var blocks: [LivePreviewBlockSpan] = []
        var index = 0

        if sourceRange.location > 0,
           let fenceContext = fenceContextBeforeRange(source: source, start: stringRange.lowerBound),
           let block = parseFencedCodeContinuation(
            source: source,
            lines: lines,
            index: &index,
            context: fenceContext
           ) {
            blocks.append(block)
        }

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
            if let block = parseCallout(source: source, lines: lines, index: &index) {
                blocks.append(block)
                continue
            }
            if let block = parseSingleLineBlock(
                source: source,
                line: line,
                index: &index,
                frontmatterDelimiterRanges: frontmatterDelimiterRanges
            ) {
                blocks.append(block)
                continue
            }

            blocks.append(parseParagraph(
                source: source,
                lines: lines,
                index: &index,
                frontmatterDelimiterRanges: frontmatterDelimiterRanges
            ))
        }

        return LivePreviewParseResult(
            sourceVersion: sourceVersion,
            sourceRange: sourceRange,
            blocks: blocks,
            isPartial: sourceRange.location != 0 || sourceRange.length != (source as NSString).length
        )
    }

    private static func lineAlignedRange(
        for range: Range<String.Index>,
        in source: String
    ) -> Range<String.Index> {
        guard !source.isEmpty else {
            return range
        }
        guard !range.isEmpty else {
            guard range.lowerBound < source.endIndex else {
                return range
            }
            return source.lineRange(for: range.lowerBound..<range.lowerBound)
        }
        return source.lineRange(for: range)
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
        var tokenRanges = [LivePreviewRangeMapper.sourceRange(for: line.contentRange, in: source)]
        while index < lines.count {
            if isFenceCloser(lines[index].trimmed, opener: opener.fence) {
                isClosed = true
                tokenRanges.append(LivePreviewRangeMapper.sourceRange(for: lines[index].contentRange, in: source))
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
            tokenRanges: tokenRanges,
            isInert: true
        )
    }

    private static func parseFencedCodeContinuation(
        source: String,
        lines: [LineIndex.Line],
        index: inout Int,
        context: FenceContext
    ) -> LivePreviewBlockSpan? {
        guard lines.indices.contains(index) else {
            return nil
        }

        let start = index
        var isClosed = false
        var tokenRanges: [LivePreviewSourceRange] = []
        while index < lines.count {
            if isFenceCloser(lines[index].trimmed, opener: context.fence) {
                isClosed = true
                tokenRanges.append(LivePreviewRangeMapper.sourceRange(for: lines[index].contentRange, in: source))
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
            kind: .fencedCode(fence: context.fence, info: context.info, isClosed: isClosed),
            tokenRanges: tokenRanges,
            isInert: true
        )
    }

    private static func fenceContextBeforeRange(source: String, start: String.Index) -> FenceContext? {
        guard start > source.startIndex else {
            return nil
        }

        switch nearbyFenceContextBeforeRange(source: source, start: start) {
        case .resolved(let context):
            return context
        case .unresolved:
            break
        }

        var index = source.startIndex
        var activeContext: FenceContext?
        while index < start,
              let line = LineIndex.line(in: source, startingAt: index) {
            if line.fullRange.upperBound > start {
                return activeContext
            }

            if let context = activeContext {
                if isFenceCloser(line.trimmed, opener: context.fence) {
                    activeContext = nil
                }
            } else if let opener = fenceOpener(in: line.trimmed) {
                activeContext = FenceContext(fence: opener.fence, info: opener.info)
            }
            index = line.fullRange.upperBound
        }

        return activeContext
    }

    private static func nearbyFenceContextBeforeRange(
        source: String,
        start: String.Index
    ) -> FenceContextResolution {
        guard let previous = previousFenceCandidateLine(in: source, before: start),
              let previousOpener = fenceOpener(in: previous.line.trimmed)
        else {
            return .resolved(nil)
        }

        if previousOpener.info != nil {
            return .resolved(FenceContext(fence: previousOpener.fence, info: previousOpener.info))
        }

        guard let beforePrevious = previousFenceCandidateLine(in: source, before: previous.nextSearchUpperBound),
              let beforePreviousOpener = fenceOpener(in: beforePrevious.line.trimmed)
        else {
            return .resolved(FenceContext(fence: previousOpener.fence, info: previousOpener.info))
        }

        if beforePrevious.nextSearchUpperBound == source.startIndex,
           isFenceCloser(previous.line.trimmed, opener: beforePreviousOpener.fence) {
            return .resolved(nil)
        }

        if beforePreviousOpener.info != nil,
           isFenceCloser(previous.line.trimmed, opener: beforePreviousOpener.fence) {
            return .resolved(nil)
        }

        return .unresolved
    }

    private static func previousFenceCandidateLine(
        in source: String,
        before upperBound: String.Index
    ) -> (line: LineIndex.Line, nextSearchUpperBound: String.Index)? {
        var searchUpperBound = upperBound
        while searchUpperBound > source.startIndex {
            let searchRange = source.startIndex..<searchUpperBound
            let backtickRange = source.range(of: "```", options: .backwards, range: searchRange)
            let tildeRange = source.range(of: "~~~", options: .backwards, range: searchRange)
            guard let markerRange = laterRange(backtickRange, tildeRange) else {
                return nil
            }

            let lineRange = source.lineRange(for: markerRange)
            searchUpperBound = lineRange.lowerBound
            guard let line = LineIndex.line(in: source, startingAt: lineRange.lowerBound, upperBound: lineRange.upperBound),
                  fenceOpener(in: line.trimmed) != nil
            else {
                continue
            }
            return (line, searchUpperBound)
        }
        return nil
    }

    private static func laterRange(
        _ lhs: Range<String.Index>?,
        _ rhs: Range<String.Index>?
    ) -> Range<String.Index>? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            return lhs.lowerBound > rhs.lowerBound ? lhs : rhs
        case let (lhs?, nil):
            return lhs
        case let (nil, rhs?):
            return rhs
        case (nil, nil):
            return nil
        }
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

    private static func parseCallout(
        source: String,
        lines: [LineIndex.Line],
        index: inout Int
    ) -> LivePreviewBlockSpan? {
        let line = lines[index]
        guard let calloutKind = calloutKind(in: line.trimmed) else {
            return nil
        }

        let start = index
        index += 1
        while index < lines.count,
              lines[index].trimmed.hasPrefix(">") {
            index += 1
        }

        return makeBlock(
            source: source,
            lines: lines,
            start: start,
            end: index,
            kind: .callout(kind: calloutKind)
        )
    }

    private static func parseSingleLineBlock(
        source: String,
        line: LineIndex.Line,
        index: inout Int,
        frontmatterDelimiterRanges: [LivePreviewSourceRange]
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
        } else if isHorizontalRule(
            line,
            source: source,
            frontmatterDelimiterRanges: frontmatterDelimiterRanges
        ) {
            kind = .horizontalRule
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
        index: inout Int,
        frontmatterDelimiterRanges: [LivePreviewSourceRange]
    ) -> LivePreviewBlockSpan {
        let start = index
        index += 1
        while index < lines.count,
              !lines[index].trimmed.isEmpty,
              !startsBlock(
                lines[index],
                nextLine: lines.indices.contains(index + 1) ? lines[index + 1] : nil,
                source: source,
                frontmatterDelimiterRanges: frontmatterDelimiterRanges
              ) {
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
        tokenRanges: [LivePreviewSourceRange] = [],
        isInert: Bool = false
    ) -> LivePreviewBlockSpan {
        let lower = lines[start].fullRange.lowerBound
        let upper = lines[end - 1].fullRange.upperBound
        let sourceRange = LivePreviewRangeMapper.sourceRange(for: lower..<upper, in: source)
        let contentRange = LivePreviewRangeMapper.sourceRange(
            for: lines[start].contentRange.lowerBound..<lines[end - 1].contentRange.upperBound,
            in: source
        )
        let inlineSpans = parsesInlineSpans(for: kind)
            ? parseInlineSpans(source, in: contentRange)
            : []
        return LivePreviewBlockSpan(
            kind: kind,
            sourceRange: sourceRange,
            contentRange: contentRange,
            tokenRanges: tokenRanges,
            inlineSpans: inlineSpans,
            isInert: isInert,
            isEditable: true
        )
    }

    private static func parsesInlineSpans(for kind: LivePreviewBlockKind) -> Bool {
        switch kind {
        case .heading, .paragraph, .unorderedList, .orderedList, .taskList, .blockquote, .callout:
            return true
        case .frontmatter, .fencedCode, .table, .horizontalRule, .embed:
            return false
        }
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
        spans += wikiLinkMatches(in: source, range: range)
        spans += markdownLinkMatches(in: source, range: range)
        spans += tagMatches(in: source, range: range)
        return spans.sorted {
            if $0.sourceRange.location == $1.sourceRange.location {
                return $0.sourceRange.length < $1.sourceRange.length
            }
            return $0.sourceRange.location < $1.sourceRange.location
        }
    }

    private static func wikiLinkMatches(in source: String, range: NSRange) -> [LivePreviewInlineSpan] {
        wikiLinkRegex.matches(in: source, range: range).map { match in
            let matchText = (source as NSString).substring(with: match.range)
            let contentRange = match.range(at: 1)
            return LivePreviewInlineSpan(
                kind: .wikiLink,
                sourceRange: LivePreviewSourceRange(location: match.range.location, length: match.range.length),
                displayRange: wikiLinkDisplayRange(in: source, contentRange: contentRange),
                isInert: matchText.hasPrefix("!")
            )
        }
    }

    private static func markdownLinkMatches(in source: String, range: NSRange) -> [LivePreviewInlineSpan] {
        markdownLinkRegex.matches(in: source, range: range).map { match in
            let matchText = (source as NSString).substring(with: match.range)
            let labelRange = match.range(at: 1)
            return LivePreviewInlineSpan(
                kind: .markdownLink,
                sourceRange: LivePreviewSourceRange(location: match.range.location, length: match.range.length),
                displayRange: LivePreviewSourceRange(location: labelRange.location, length: labelRange.length),
                isInert: matchText.hasPrefix("!")
            )
        }
    }

    private static func wikiLinkDisplayRange(in source: String, contentRange: NSRange) -> LivePreviewSourceRange {
        let content = (source as NSString).substring(with: contentRange) as NSString
        let aliasSeparator = content.range(of: "|", options: .backwards)
        guard aliasSeparator.location != NSNotFound else {
            return LivePreviewSourceRange(location: contentRange.location, length: contentRange.length)
        }
        let target = content.substring(to: aliasSeparator.location)
        guard !keepsWikiTargetVisible(target) else {
            return LivePreviewSourceRange(location: contentRange.location, length: contentRange.length)
        }

        let displayLocation = contentRange.location + aliasSeparator.location + aliasSeparator.length
        let displayLength = max(0, contentRange.location + contentRange.length - displayLocation)
        return LivePreviewSourceRange(location: displayLocation, length: displayLength)
    }

    private static func keepsWikiTargetVisible(_ target: String) -> Bool {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("/") ||
            trimmed.contains("\\") ||
            trimmed.contains("[") ||
            targetScheme(trimmed) != nil
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
            let displayRange = LivePreviewSourceRange(
                location: tagRange.location + 1,
                length: max(0, tagRange.length - 1)
            )
            return LivePreviewInlineSpan(
                kind: .tag,
                sourceRange: LivePreviewSourceRange(location: tagRange.location, length: tagRange.length),
                displayRange: displayRange
            )
        }
    }

    private static func startsBlock(
        _ line: LineIndex.Line,
        nextLine: LineIndex.Line?,
        source: String,
        frontmatterDelimiterRanges: [LivePreviewSourceRange]
    ) -> Bool {
        let trimmed = line.trimmed
        return headingLevel(in: trimmed) != nil ||
            fenceOpener(in: trimmed) != nil ||
            isTaskList(trimmed, checked: true) ||
            isTaskList(trimmed, checked: false) ||
            isUnorderedList(trimmed) ||
            isOrderedList(trimmed) ||
            trimmed.hasPrefix(">") ||
            isEmbedLine(trimmed) ||
            isHorizontalRule(line, source: source, frontmatterDelimiterRanges: frontmatterDelimiterRanges) ||
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
        guard let marker = trimmedLine.first,
              marker == "`" || marker == "~"
        else {
            return nil
        }

        let markerLength = trimmedLine.prefix { $0 == marker }.count
        guard markerLength >= 3 else {
            return nil
        }

        let fence = String(repeating: String(marker), count: markerLength)
        let info = trimmedLine.dropFirst(markerLength).trimmingCharacters(in: .whitespacesAndNewlines)
        return (fence, info.isEmpty ? nil : info)
    }

    private static func isFenceCloser(_ trimmedLine: String, opener: String) -> Bool {
        guard let marker = opener.first else {
            return false
        }

        let markerLength = trimmedLine.prefix { $0 == marker }.count
        guard markerLength >= opener.count else {
            return false
        }

        return trimmedLine.dropFirst(markerLength).allSatisfy(\.isWhitespace)
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

    private static func isHorizontalRule(
        _ line: LineIndex.Line,
        source: String,
        frontmatterDelimiterRanges: [LivePreviewSourceRange]
    ) -> Bool {
        guard isHorizontalRule(line.trimmed),
              !isIndentedCodeLine(line, source: source),
              !isFrontmatterDelimiter(line, source: source, delimiterRanges: frontmatterDelimiterRanges)
        else {
            return false
        }
        return true
    }

    private static func isHorizontalRule(_ trimmedLine: String) -> Bool {
        trimmedLine == "---" || trimmedLine == "***" || trimmedLine == "___"
    }

    private static func isIndentedCodeLine(_ line: LineIndex.Line, source: String) -> Bool {
        leadingIndentColumns(in: String(source[line.contentRange])) >= 4
    }

    private static func leadingIndentColumns(in line: String) -> Int {
        var columns = 0
        for character in line {
            if character == " " {
                columns += 1
            } else if character == "\t" {
                columns += 4
            } else {
                break
            }
        }
        return columns
    }

    private static func isFrontmatterDelimiter(
        _ line: LineIndex.Line,
        source: String,
        delimiterRanges: [LivePreviewSourceRange]
    ) -> Bool {
        let sourceRange = LivePreviewRangeMapper.sourceRange(for: line.contentRange, in: source)
        return delimiterRanges.contains(sourceRange)
    }

    private static func frontmatterDelimiterRanges(in source: String) -> [LivePreviewSourceRange] {
        guard let firstLine = LineIndex.line(in: source, startingAt: source.startIndex),
              firstLine.trimmed == "---"
        else {
            return []
        }

        var ranges = [LivePreviewRangeMapper.sourceRange(for: firstLine.contentRange, in: source)]
        var index = firstLine.fullRange.upperBound
        var scannedLineCount = 1
        while scannedLineCount < maxFrontmatterDelimiterLines,
              let line = LineIndex.line(in: source, startingAt: index) {
            defer { index = line.fullRange.upperBound }
            scannedLineCount += 1
            guard line.trimmed == "---" else {
                let scannedLength = NSRange(source.startIndex..<line.fullRange.upperBound, in: source).length
                if scannedLength >= maxFrontmatterDelimiterUTF16Length {
                    break
                }
                continue
            }
            ranges.append(LivePreviewRangeMapper.sourceRange(for: line.contentRange, in: source))
            break
        }
        return ranges
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
    private static let wikiLinkRegex = regex("!?\\[\\[([^\\]\\n]+)\\]\\]")
    private static let markdownLinkRegex = regex("!?\\[([^\\]\\n]+)\\]\\([^\\)\\n]+\\)")
    private static let tagRegex = regex("(^|\\s)(#[\\p{L}\\p{N}_/-]+)")

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }
}

private func targetScheme(_ target: String) -> String? {
    guard let colon = target.firstIndex(of: ":") else {
        return nil
    }
    let colonDistance = target.distance(from: target.startIndex, to: colon)
    let slashDistance = target
        .firstIndex(of: "/")
        .map { target.distance(from: target.startIndex, to: $0) } ?? Int.max
    guard colonDistance <= slashDistance else {
        return nil
    }

    let scheme = String(target[..<colon])
    guard let first = scheme.unicodeScalars.first,
          isASCIIAlpha(first),
          scheme.unicodeScalars.allSatisfy(isSchemeScalar)
    else {
        return nil
    }
    return scheme
}

private func isASCIIAlpha(_ scalar: UnicodeScalar) -> Bool {
    (65...90).contains(Int(scalar.value)) || (97...122).contains(Int(scalar.value))
}

private func isSchemeScalar(_ scalar: UnicodeScalar) -> Bool {
    isASCIIAlpha(scalar)
        || (48...57).contains(Int(scalar.value))
        || scalar == "+"
        || scalar == "-"
        || scalar == "."
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
            guard let line = line(in: source, startingAt: index, upperBound: range.upperBound) else {
                break
            }
            lines.append(line)
            index = line.fullRange.upperBound
        }

        return lines
    }

    static func line(
        in source: String,
        startingAt index: String.Index,
        upperBound: String.Index? = nil
    ) -> Line? {
        let upperBound = upperBound ?? source.endIndex
        guard index < upperBound else {
            return nil
        }
        let contentUpper = source[index..<upperBound].firstIndex { $0.isNewline } ?? upperBound
        let lineUpper = contentUpper < upperBound
            ? source.index(after: contentUpper)
            : upperBound
        let contentRange = index..<contentUpper
        return Line(
            fullRange: index..<lineUpper,
            contentRange: contentRange,
            trimmed: String(source[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
