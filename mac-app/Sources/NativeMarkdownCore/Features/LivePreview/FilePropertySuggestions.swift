import Foundation

public struct FilePropertySuggestion: Equatable, Identifiable, Sendable {
    public var id: String { name.lowercased() }
    public let name: String
    public let type: FilePropertyType
    public let existsInNote: Bool

    public init(name: String, type: FilePropertyType, existsInNote: Bool) {
        self.name = name
        self.type = type
        self.existsInNote = existsInNote
    }
}

public enum FilePropertySuggestions {
    public static let defaultNames: [String] = [
        "tags",
        "aliases",
        "cssclasses",
        "status",
        "type",
        "created",
        "modified",
        "published"
    ]

    public static func suggestions(
        source: String,
        storedTypes: [String: FilePropertyType] = [:]
    ) -> [FilePropertySuggestion] {
        let existingNames = existingPropertyNames(in: source)
        let orderedNames = orderedUniqueNames(defaultNames + existingNames + storedTypes.keys.sorted())

        return orderedNames.map { name in
            FilePropertySuggestion(
                name: name,
                type: storedTypes[name.lowercased()] ?? defaultType(for: name),
                existsInNote: existingNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
            )
        }
    }

    public static func defaultType(for propertyName: String) -> FilePropertyType {
        let normalized = propertyName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let type = FilePropertyType.defaultType(for: normalized) {
            return type
        }
        switch normalized {
        case "created", "modified", "date":
            return .date
        case "published", "draft", "archived":
            return .checkbox
        default:
            return .text
        }
    }

    private static func existingPropertyNames(in source: String) -> [String] {
        guard let block = FrontmatterBlockLocator.locateClosedBlock(in: source) else {
            return []
        }
        return FrontmatterEditPlanner.topLevelPropertyRanges(in: source, block: block).map(\.key)
    }

    private static func orderedUniqueNames(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()
            guard !trimmed.isEmpty, !seen.contains(key) else {
                continue
            }
            seen.insert(key)
            result.append(trimmed)
        }
        return result
    }
}
