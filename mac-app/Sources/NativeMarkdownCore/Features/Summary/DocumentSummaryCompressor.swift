import Foundation

public struct DocumentSummaryCompressionResult: Equatable, Sendable {
    public let text: String
    public let originalByteCount: Int
    public let compressedByteCount: Int
    public let includedSegmentCount: Int
    public let truncatedSegmentCount: Int

    public init(
        text: String,
        originalByteCount: Int,
        includedSegmentCount: Int,
        truncatedSegmentCount: Int
    ) {
        self.text = text
        self.originalByteCount = originalByteCount
        self.compressedByteCount = text.utf8.count
        self.includedSegmentCount = includedSegmentCount
        self.truncatedSegmentCount = truncatedSegmentCount
    }
}

public struct DocumentSummaryCompressor: Sendable {
    public let maxCharacters: Int

    public init(maxCharacters: Int = 12_000) {
        self.maxCharacters = max(256, maxCharacters)
    }

    public func compress(_ source: String) -> DocumentSummaryCompressionResult {
        let lines = source.components(separatedBy: .newlines)
        let frontmatter = Self.parseFrontmatter(lines)
        let bodyStart = Self.frontmatterEndIndex(lines) ?? 0
        let body = Self.scanBody(Array(lines.dropFirst(bodyStart)))
        var segments: [String] = []

        if let title = frontmatter.first(where: { $0.key == "title" })?.renderedValue {
            segments.append("Title:\n\(title)")
        } else if let firstH1 = body.headings.first(where: { $0.hasPrefix("# ") }) {
            segments.append("Title:\n\(Self.headingText(firstH1))")
        }

        let frontmatterLines = frontmatter
            .filter { $0.key != "title" }
            .map { "\($0.key): \($0.renderedValue)" }
        if !frontmatterLines.isEmpty {
            segments.append("Frontmatter:\n" + frontmatterLines.joined(separator: "\n"))
        }

        if !body.headings.isEmpty {
            segments.append("Heading Outline:\n" + body.headings.prefix(40).joined(separator: "\n"))
        }
        if !body.paragraphs.isEmpty {
            segments.append("First Paragraphs:\n" + body.paragraphs.prefix(24).joined(separator: "\n"))
        }
        if !body.listItems.isEmpty {
            segments.append("Lists:\n" + body.listItems.prefix(40).joined(separator: "\n"))
        }
        if !body.callouts.isEmpty {
            segments.append("Callouts:\n" + body.callouts.prefix(12).joined(separator: "\n"))
        }
        if !body.tables.isEmpty {
            segments.append("Tables:\n" + body.tables.prefix(8).joined(separator: "\n\n"))
        }

        return boundedResult(
            from: segments,
            originalByteCount: source.utf8.count
        )
    }

    private func boundedResult(
        from segments: [String],
        originalByteCount: Int
    ) -> DocumentSummaryCompressionResult {
        var output: [String] = []
        var usedCharacters = 0
        var truncated = 0

        for segment in segments {
            let separatorLength = output.isEmpty ? 0 : 2
            let nextLength = usedCharacters + separatorLength + segment.count
            if nextLength <= maxCharacters {
                output.append(segment)
                usedCharacters = nextLength
                continue
            }

            let remaining = maxCharacters - usedCharacters - separatorLength
            if remaining > 20 {
                let suffix = "\n[truncated]"
                let prefixLength = max(0, remaining - suffix.count)
                output.append(String(segment.prefix(prefixLength)) + suffix)
                usedCharacters = maxCharacters
            }
            truncated += 1
            break
        }

        let text = output.joined(separator: "\n\n")
        return DocumentSummaryCompressionResult(
            text: text,
            originalByteCount: originalByteCount,
            includedSegmentCount: output.count,
            truncatedSegmentCount: truncated
        )
    }
}

private struct CompressorBodyScan {
    var headings: [String] = []
    var paragraphs: [String] = []
    var listItems: [String] = []
    var callouts: [String] = []
    var tables: [String] = []
}

private struct FrontmatterEntry {
    let key: String
    var values: [String]

    var renderedValue: String {
        values.joined(separator: ", ")
    }
}

private extension DocumentSummaryCompressor {
    static let safeFrontmatterKeys: Set<String> = ["title", "date", "tags", "type", "project"]
    static let deniedFrontmatterKeyFragments = ["token", "password", "secret", "api_key", "private", "credential"]
    static let maxScannedHeadings = 80
    static let maxScannedParagraphs = 48
    static let maxScannedListItems = 80
    static let maxScannedCallouts = 24
    static let maxScannedTables = 16

    static func parseFrontmatter(_ lines: [String]) -> [FrontmatterEntry] {
        guard let endIndex = frontmatterEndIndex(lines), endIndex > 1 else {
            return []
        }

        var entries: [FrontmatterEntry] = []
        var currentEntryIndex: Int?
        for line in lines[1..<(endIndex - 1)] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                continue
            }

            if let (key, value) = frontmatterKeyValue(trimmed) {
                let normalizedKey = key.lowercased()
                guard shouldIncludeFrontmatterKey(normalizedKey) else {
                    currentEntryIndex = nil
                    continue
                }
                entries.append(FrontmatterEntry(
                    key: normalizedKey,
                    values: cleanedFrontmatterValues(value)
                ))
                currentEntryIndex = entries.indices.last
                continue
            }

            guard trimmed.hasPrefix("- "),
                  let currentEntryIndex
            else {
                continue
            }
            let value = cleanFrontmatterValue(String(trimmed.dropFirst(2)))
            if !value.isEmpty {
                entries[currentEntryIndex].values.append(value)
            }
        }

        return entries.filter { !$0.values.isEmpty }
    }

    static func frontmatterEndIndex(_ lines: [String]) -> Int? {
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return nil
        }
        for index in lines.indices.dropFirst() where lines[index].trimmingCharacters(in: .whitespaces) == "---" {
            return index + 1
        }
        return nil
    }

    static func frontmatterKeyValue(_ line: String) -> (String, String)? {
        guard let colon = line.firstIndex(of: ":") else {
            return nil
        }
        let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else {
            return nil
        }
        return (key, value)
    }

    static func shouldIncludeFrontmatterKey(_ key: String) -> Bool {
        let normalized = key.replacingOccurrences(of: "-", with: "_")
        if deniedFrontmatterKeyFragments.contains(where: { normalized.contains($0) }) {
            return false
        }
        return safeFrontmatterKeys.contains(normalized)
    }

    static func cleanedFrontmatterValues(_ value: String) -> [String] {
        let cleaned = cleanFrontmatterValue(value)
        guard !cleaned.isEmpty else {
            return []
        }
        if cleaned.hasPrefix("[") && cleaned.hasSuffix("]") {
            let inner = cleaned.dropFirst().dropLast()
            return inner
                .split(separator: ",")
                .map { cleanFrontmatterValue(String($0)) }
                .filter { !$0.isEmpty }
        }
        return [cleaned]
    }

    static func cleanFrontmatterValue(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    static func scanBody(_ lines: [String]) -> CompressorBodyScan {
        var scan = CompressorBodyScan()
        var currentHeading = "Document"
        var paragraphCapturedInSection = false
        var paragraphLines: [String] = []
        var inFence = false
        var index = 0

        func flushParagraph() {
            let paragraph = paragraphLines
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            paragraphLines.removeAll(keepingCapacity: true)
            guard !paragraph.isEmpty, !paragraphCapturedInSection else {
                return
            }
            if scan.paragraphs.count < maxScannedParagraphs {
                scan.paragraphs.append("[\(currentHeading)] \(paragraph)")
            }
            paragraphCapturedInSection = true
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if isFenceLine(trimmed) {
                flushParagraph()
                inFence.toggle()
                index += 1
                continue
            }
            if inFence {
                index += 1
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }
            if let heading = headingLine(trimmed) {
                flushParagraph()
                if scan.headings.count < maxScannedHeadings {
                    scan.headings.append(heading)
                }
                currentHeading = headingText(heading)
                paragraphCapturedInSection = false
                index += 1
                continue
            }
            if isTableStart(at: index, lines: lines) {
                flushParagraph()
                let table = tableSegment(at: index, lines: lines)
                if scan.tables.count < maxScannedTables {
                    scan.tables.append(table.text)
                }
                index = table.nextIndex
                continue
            }
            if isCalloutLine(trimmed) {
                flushParagraph()
                let callout = calloutSegment(at: index, lines: lines)
                if scan.callouts.count < maxScannedCallouts {
                    scan.callouts.append(callout.text)
                }
                index = callout.nextIndex
                continue
            }
            if isListLine(trimmed) {
                flushParagraph()
                let list = listSegment(at: index, lines: lines)
                let remaining = max(0, maxScannedListItems - scan.listItems.count)
                scan.listItems.append(contentsOf: list.items.prefix(remaining))
                index = list.nextIndex
                continue
            }

            paragraphLines.append(trimmed)
            index += 1
        }

        flushParagraph()
        return scan
    }

    static func isFenceLine(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    static func headingLine(_ trimmed: String) -> String? {
        let markerCount = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(markerCount),
              trimmed.dropFirst(markerCount).first == " "
        else {
            return nil
        }
        return trimmed
    }

    static func headingText(_ heading: String) -> String {
        heading
            .drop { $0 == "#" || $0 == " " }
            .trimmingCharacters(in: .whitespaces)
    }

    static func isListLine(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("- ")
            || trimmed.hasPrefix("* ")
            || trimmed.hasPrefix("+ ")
            || numberedListPrefixLength(trimmed) != nil
    }

    static func numberedListPrefixLength(_ trimmed: String) -> Int? {
        var digitCount = 0
        for character in trimmed {
            if character.isNumber {
                digitCount += 1
                continue
            }
            guard digitCount > 0,
                  character == "."
            else {
                return nil
            }
            let nextIndex = trimmed.index(trimmed.startIndex, offsetBy: digitCount + 1)
            guard nextIndex < trimmed.endIndex, trimmed[nextIndex] == " " else {
                return nil
            }
            return digitCount + 2
        }
        return nil
    }

    static func listSegment(at index: Int, lines: [String]) -> (items: [String], nextIndex: Int) {
        var items: [String] = []
        var current = index
        while current < lines.count {
            let trimmed = lines[current].trimmingCharacters(in: .whitespaces)
            guard isListLine(trimmed) else {
                break
            }
            if items.count < 12 {
                items.append(cleanListMarker(lines[current]))
            }
            current += 1
        }
        return (items, current)
    }

    static func cleanListMarker(_ line: String) -> String {
        let leadingWhitespace = line.prefix { $0 == " " || $0 == "\t" }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let indent = leadingWhitespace.isEmpty ? "" : "  "
        if let prefixLength = numberedListPrefixLength(trimmed) {
            return indent + "- " + String(trimmed.dropFirst(prefixLength))
        }
        return indent + "- " + String(trimmed.dropFirst(2))
    }

    static func isCalloutLine(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("> [!")
    }

    static func calloutSegment(at index: Int, lines: [String]) -> (text: String, nextIndex: Int) {
        var parts: [String] = []
        var current = index
        while current < lines.count {
            let trimmed = lines[current].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(">") else {
                break
            }
            let value = trimmed
                .dropFirst()
                .trimmingCharacters(in: .whitespaces)
            if !value.isEmpty, parts.count < 3 {
                parts.append(String(value))
            }
            current += 1
        }
        return (parts.joined(separator: "\n"), current)
    }

    static func isTableStart(at index: Int, lines: [String]) -> Bool {
        guard index + 1 < lines.count else {
            return false
        }
        return isPipeRow(lines[index]) && isTableDelimiter(lines[index + 1])
    }

    static func tableSegment(at index: Int, lines: [String]) -> (text: String, nextIndex: Int) {
        let header = lines[index].trimmingCharacters(in: .whitespaces)
        let delimiter = lines[index + 1].trimmingCharacters(in: .whitespaces)
        var rows: [String] = [header, delimiter]
        var lastRow: String?
        var current = index + 2
        while current < lines.count, isPipeRow(lines[current]) {
            let row = lines[current].trimmingCharacters(in: .whitespaces)
            if rows.count < 4 {
                rows.append(row)
            }
            lastRow = row
            current += 1
        }

        if let lastRow, rows.last != lastRow {
            rows.append(lastRow)
        }
        return (rows.joined(separator: "\n"), current)
    }

    static func isPipeRow(_ line: String) -> Bool {
        line.contains("|")
    }

    static func isTableDelimiter(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else {
            return false
        }
        let cells = trimmed
            .trimmingCharacters(in: CharacterSet(charactersIn: "| "))
            .split(separator: "|", omittingEmptySubsequences: false)
        guard !cells.isEmpty else {
            return false
        }
        return cells.allSatisfy { cell in
            let value = cell.trimmingCharacters(in: .whitespaces)
            return value.count >= 3 && value.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }
}
