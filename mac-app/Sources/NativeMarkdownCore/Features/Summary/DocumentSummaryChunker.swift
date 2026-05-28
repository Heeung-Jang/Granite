import Foundation

public struct DocumentSummaryChunk: Equatable, Sendable {
    public let headingPath: [String]
    public let text: String

    public init(headingPath: [String], text: String) {
        self.headingPath = headingPath
        self.text = text
    }
}

public enum DocumentSummaryChunker {
    public static func chunks(
        for source: String,
        contextSize: Int?,
        language: SummaryLanguage,
        limits: DocumentSummaryLimits = DocumentSummaryLimits()
    ) throws -> [DocumentSummaryChunk] {
        guard source.utf8.count <= limits.maxSourceBytes else {
            throw SummaryGenerationError.tooLarge(
                sourceByteCount: source.utf8.count,
                maxSourceBytes: limits.maxSourceBytes
            )
        }

        let body = stripFrontmatter(from: source)
        let budget = characterBudget(contextSize: contextSize, language: language, limits: limits)
        let sections = splitHeadingSections(body)
        let chunks = sections.flatMap { section in
            splitSection(section, budget: budget)
        }
        let nonEmptyChunks = chunks.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard nonEmptyChunks.count <= limits.maxChunks else {
            throw SummaryGenerationError.tooLarge(
                sourceByteCount: source.utf8.count,
                maxSourceBytes: limits.maxSourceBytes
            )
        }
        return nonEmptyChunks
    }

    public static func stripFrontmatter(from source: String) -> String {
        guard source.hasPrefix("---\n") || source == "---" else {
            return source
        }
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == "---" else {
            return source
        }
        for index in lines.indices.dropFirst() where lines[index] == "---" {
            return lines.dropFirst(index + 1).joined(separator: "\n")
        }
        return source
    }

    private static func characterBudget(
        contextSize: Int?,
        language: SummaryLanguage,
        limits: DocumentSummaryLimits
    ) -> Int {
        guard let contextSize, contextSize > 0 else {
            return language == .english ? limits.fallbackInputCharacters : limits.fallbackInputCharacters / 2
        }
        let reserve = 1_200
        let usableTokens = max(400, contextSize - reserve)
        let charsPerToken = language == .english ? 4 : 2
        return min(limits.fallbackInputCharacters, usableTokens * charsPerToken)
    }

    private static func splitHeadingSections(_ source: String) -> [DocumentSummaryChunk] {
        var sections: [DocumentSummaryChunk] = []
        var headingStack: [(level: Int, title: String)] = []
        var currentLines: [String] = []
        var currentHeadingPath: [String] = []
        var inFence = false

        func flush() {
            let text = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                sections.append(DocumentSummaryChunk(headingPath: currentHeadingPath, text: text))
            }
            currentLines.removeAll()
        }

        for line in source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                currentLines.append(line)
                continue
            }
            if !inFence, let heading = parseHeading(line) {
                flush()
                headingStack.removeAll { $0.level >= heading.level }
                headingStack.append(heading)
                currentHeadingPath = headingStack.map(\.title)
            }
            currentLines.append(line)
        }
        flush()
        return sections.isEmpty ? [DocumentSummaryChunk(headingPath: [], text: source)] : sections
    }

    private static func parseHeading(_ line: String) -> (level: Int, title: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes),
              trimmed.dropFirst(hashes).first == " "
        else {
            return nil
        }
        let title = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
        return (hashes, title)
    }

    private static func splitSection(_ section: DocumentSummaryChunk, budget: Int) -> [DocumentSummaryChunk] {
        if section.text.count <= budget {
            return [section]
        }
        let paragraphs = section.text.components(separatedBy: "\n\n")
        var result: [DocumentSummaryChunk] = []
        var current = ""
        for paragraph in paragraphs {
            if paragraph.count > budget {
                if !current.isEmpty {
                    result.append(DocumentSummaryChunk(headingPath: section.headingPath, text: current))
                    current = ""
                }
                result.append(contentsOf: splitOversizedParagraph(paragraph, headingPath: section.headingPath, budget: budget))
            } else if current.count + paragraph.count + 2 > budget {
                result.append(DocumentSummaryChunk(headingPath: section.headingPath, text: current))
                current = paragraph
            } else {
                current = current.isEmpty ? paragraph : "\(current)\n\n\(paragraph)"
            }
        }
        if !current.isEmpty {
            result.append(DocumentSummaryChunk(headingPath: section.headingPath, text: current))
        }
        return result
    }

    private static func splitOversizedParagraph(
        _ paragraph: String,
        headingPath: [String],
        budget: Int
    ) -> [DocumentSummaryChunk] {
        var chunks: [DocumentSummaryChunk] = []
        var start = paragraph.startIndex
        while start < paragraph.endIndex {
            let end = paragraph.index(start, offsetBy: budget, limitedBy: paragraph.endIndex) ?? paragraph.endIndex
            chunks.append(DocumentSummaryChunk(headingPath: headingPath, text: String(paragraph[start..<end])))
            start = end
        }
        return chunks
    }
}
