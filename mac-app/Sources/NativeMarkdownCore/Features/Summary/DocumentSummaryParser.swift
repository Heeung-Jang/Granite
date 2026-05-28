import Foundation

public enum DocumentSummaryParser {
    public static func parse(_ response: String, metadata: SummaryMetadata) -> DocumentSummary {
        parseDetailed(response, metadata: metadata).summary
    }

    public static func parseFast(_ response: String, metadata: SummaryMetadata) throws -> DocumentSummary {
        let result = parseDetailed(response, metadata: metadata)
        guard result.hasRecognizedStructure else {
            throw SummaryGenerationError.malformedResponse
        }
        return result.summary
    }

    private static func parseDetailed(_ response: String, metadata: SummaryMetadata) -> ParseResult {
        let lines = response
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }

        var overview: [String] = []
        var keyPoints: [String] = []
        var actions: [String] = []
        var looseBullets: [String] = []
        var section = SummarySection.overview
        var sawSectionLabel = false

        for line in lines where !line.isEmpty {
            if let nextSection = sectionLabel(for: line) {
                sawSectionLabel = true
                section = nextSection
                let value = valueAfterColon(line)
                if !value.isEmpty {
                    append(value, to: section, overview: &overview, keyPoints: &keyPoints, actions: &actions)
                }
                continue
            }

            if !sawSectionLabel, isBullet(line) {
                looseBullets.append(cleanBullet(line))
                continue
            }

            append(line, to: section, overview: &overview, keyPoints: &keyPoints, actions: &actions)
        }

        if !sawSectionLabel, !looseBullets.isEmpty {
            overview = [looseBullets[0]]
            keyPoints = looseBullets
        }

        let summary = DocumentSummary(
            overview: overview.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines),
            keyPoints: keyPoints.filter { !$0.isEmpty },
            actionItems: actions.isEmpty ? ["없음"] : actions.filter { !$0.isEmpty },
            metadata: metadata
        )

        return ParseResult(
            summary: summary,
            hasRecognizedStructure: sawSectionLabel || !looseBullets.isEmpty
        )
    }

    private static func append(
        _ value: String,
        to section: SummarySection,
        overview: inout [String],
        keyPoints: inout [String],
        actions: inout [String]
    ) {
        switch section {
        case .overview:
            overview.append(cleanBullet(value))
        case .points:
            keyPoints.append(cleanBullet(value))
        case .actions:
            actions.append(cleanBullet(value))
        }
    }

    private static func sectionLabel(for line: String) -> SummarySection? {
        let normalized = line
            .trimmingCharacters(in: CharacterSet(charactersIn: "#: "))
            .lowercased()

        if line.hasPrefix("핵심 요약") || normalized.hasPrefix("summary") {
            return .overview
        }
        if line.hasPrefix("주요 포인트") || normalized.hasPrefix("key point") {
            return .points
        }
        if line.hasPrefix("액션")
            || line.hasPrefix("결정")
            || normalized.hasPrefix("action")
            || normalized.hasPrefix("decision") {
            return .actions
        }
        return nil
    }

    private static func valueAfterColon(_ line: String) -> String {
        guard let colon = line.firstIndex(of: ":") else {
            return ""
        }
        return String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    }

    private static func isBullet(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("- ")
            || trimmed.hasPrefix("• ")
            || trimmed.hasPrefix("* ")
    }

    private static func cleanBullet(_ line: String) -> String {
        line.trimmingCharacters(in: CharacterSet(charactersIn: "-•* \t"))
    }
}

private enum SummarySection {
    case overview
    case points
    case actions
}

private struct ParseResult {
    let summary: DocumentSummary
    let hasRecognizedStructure: Bool
}
