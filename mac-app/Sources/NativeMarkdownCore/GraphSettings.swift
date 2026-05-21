import Foundation

public struct GraphSettings: Equatable, Sendable {
    public var semantic: GraphSemanticSettings
    public var presentation: GraphPresentationSettings
    public var searchQuery: String
    public var groupRules: [GraphGroupRule]

    public init(
        semantic: GraphSemanticSettings = GraphSemanticSettings(),
        presentation: GraphPresentationSettings = GraphPresentationSettings(),
        searchQuery: String = "",
        groupRules: [GraphGroupRule] = []
    ) {
        self.semantic = semantic
        self.presentation = presentation
        self.searchQuery = searchQuery
        self.groupRules = groupRules
    }

    public func requiresSnapshotReload(comparedTo previous: GraphSettings) -> Bool {
        semantic != previous.semantic
    }
}

public struct GraphSemanticSettings: Equatable, Sendable {
    public var includeUnresolved: Bool
    public var includeOrphans: Bool

    public init(
        includeUnresolved: Bool = false,
        includeOrphans: Bool = false
    ) {
        self.includeUnresolved = includeUnresolved
        self.includeOrphans = includeOrphans
    }

    public var resolvedLinksOnly: Bool {
        !includeUnresolved
    }
}

public struct GraphPresentationSettings: Equatable, Sendable {
    public var labelVisibility: GraphLabelVisibility
    public var showArrows: Bool
    public var nodeSize: Double
    public var linkThickness: Double

    public init(
        labelVisibility: GraphLabelVisibility = .automatic,
        showArrows: Bool = false,
        nodeSize: Double = 1.0,
        linkThickness: Double = 1.0
    ) {
        self.labelVisibility = labelVisibility
        self.showArrows = showArrows
        self.nodeSize = nodeSize
        self.linkThickness = linkThickness
    }
}

public enum GraphLabelVisibility: String, Equatable, Hashable, Sendable {
    case automatic
    case always
    case hidden
}

public struct GraphGroupRule: Equatable, Sendable, Identifiable {
    public static let maxQueryLength = 512

    public let id: String
    public var query: String
    public var colorHex: String

    public init(id: String, query: String, colorHex: String) {
        self.id = id
        self.query = String(query.prefix(Self.maxQueryLength))
        self.colorHex = GraphColorHex.normalized(colorHex) ?? GraphColorHex.defaultHex
    }

    public func matches(_ node: GraphLayoutNode) -> Bool {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return false
        }

        if trimmedQuery.hasPrefix("#") {
            let tagQuery = String(trimmedQuery.dropFirst())
            return node.tags.contains { tag in
                tag.localizedCaseInsensitiveCompare(tagQuery) == .orderedSame
            }
        }

        return node.label.localizedCaseInsensitiveContains(trimmedQuery)
            || (node.relativePath?.localizedCaseInsensitiveContains(trimmedQuery) ?? false)
    }
}

public enum GraphGroupMatcher {
    public static func groupColorHexByNodeID(
        in layout: GraphRendererSnapshot,
        rules: [GraphGroupRule]
    ) -> [String: String] {
        let activeRules = rules.filter { !$0.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !activeRules.isEmpty else {
            return [:]
        }

        var colors: [String: String] = [:]
        colors.reserveCapacity(min(layout.nodes.count, activeRules.count * 64))
        for node in layout.nodes {
            guard let rule = activeRules.first(where: { $0.matches(node) }) else {
                continue
            }
            colors[node.nodeID] = rule.colorHex
        }
        return colors
    }
}

public enum GraphColorHex {
    public static let defaultHex = "#808080"

    public static func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard hex.count == 6,
              hex.allSatisfy(\.isHexDigit)
        else {
            return nil
        }
        return "#\(hex.lowercased())"
    }
}

public struct GraphSettingsPrivacyKey: Equatable, Sendable, CustomStringConvertible {
    public let value: String

    public var description: String { value }

    public static func make(settings: GraphSettings) -> Self {
        let groupFingerprints = settings.groupRules
            .map { rule in
                "\(stableHash(rule.id)):\(stableHash(rule.query)):\(stableHash(rule.colorHex))"
            }
            .sorted()
            .joined(separator: ",")
        let payload = [
            "unresolved:\(settings.semantic.includeUnresolved)",
            "orphans:\(settings.semantic.includeOrphans)",
            "labels:\(settings.presentation.labelVisibility.rawValue)",
            "arrows:\(settings.presentation.showArrows)",
            "node:\(settings.presentation.nodeSize)",
            "link:\(settings.presentation.linkThickness)",
            "search:\(stableHash(settings.searchQuery))",
            "groups:\(groupFingerprints)"
        ].joined(separator: "|")
        return Self(value: "graph-settings-\(stableHash(payload))")
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
