import Foundation

public struct WorkspacePaneLayout: Codable, Equatable, Sendable {
    public static let defaultLeftSidebarWidth: Double = 272
    public static let defaultRightSidebarWidth: Double = 300
    public static let minSidebarWidth: Double = 200
    public static let minWorkspaceWidth: Double = 360

    public static let `default` = WorkspacePaneLayout()

    public var leftSidebarWidth: Double
    public var rightSidebarWidth: Double
    public var isLeftSidebarCollapsed: Bool
    public var isRightSidebarCollapsed: Bool

    public init(
        leftSidebarWidth: Double = Self.defaultLeftSidebarWidth,
        rightSidebarWidth: Double = Self.defaultRightSidebarWidth,
        isLeftSidebarCollapsed: Bool = false,
        isRightSidebarCollapsed: Bool = false
    ) {
        self.leftSidebarWidth = Self.normalizedSidebarWidth(
            leftSidebarWidth,
            fallback: Self.defaultLeftSidebarWidth
        )
        self.rightSidebarWidth = Self.normalizedSidebarWidth(
            rightSidebarWidth,
            fallback: Self.defaultRightSidebarWidth
        )
        self.isLeftSidebarCollapsed = isLeftSidebarCollapsed
        self.isRightSidebarCollapsed = isRightSidebarCollapsed
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            leftSidebarWidth: try container.decodeIfPresent(Double.self, forKey: .leftSidebarWidth)
                ?? Self.defaultLeftSidebarWidth,
            rightSidebarWidth: try container.decodeIfPresent(Double.self, forKey: .rightSidebarWidth)
                ?? Self.defaultRightSidebarWidth,
            isLeftSidebarCollapsed: try container.decodeIfPresent(Bool.self, forKey: .isLeftSidebarCollapsed)
                ?? false,
            isRightSidebarCollapsed: try container.decodeIfPresent(Bool.self, forKey: .isRightSidebarCollapsed)
                ?? false
        )
    }

    public func clampedToAvailableWidth(_ availableWidth: Double?) -> WorkspacePaneLayout {
        guard let availableWidth,
              availableWidth.isFinite,
              availableWidth > 0
        else {
            return self
        }

        var clamped = self
        clamped.leftSidebarWidth = Self.clampedSidebarWidth(
            proposedWidth: leftSidebarWidth,
            otherSidebarWidth: isRightSidebarCollapsed ? 0 : rightSidebarWidth,
            availableWidth: availableWidth
        )
        clamped.rightSidebarWidth = Self.clampedSidebarWidth(
            proposedWidth: rightSidebarWidth,
            otherSidebarWidth: isLeftSidebarCollapsed ? 0 : clamped.leftSidebarWidth,
            availableWidth: availableWidth
        )
        return clamped
    }

    public func settingLeftSidebarWidth(_ proposedWidth: Double, availableWidth: Double?) -> WorkspacePaneLayout {
        var updated = self
        updated.leftSidebarWidth = Self.clampedSidebarWidth(
            proposedWidth: proposedWidth,
            otherSidebarWidth: isRightSidebarCollapsed ? 0 : rightSidebarWidth,
            availableWidth: availableWidth
        )
        return updated
    }

    public func settingRightSidebarWidth(_ proposedWidth: Double, availableWidth: Double?) -> WorkspacePaneLayout {
        var updated = self
        updated.rightSidebarWidth = Self.clampedSidebarWidth(
            proposedWidth: proposedWidth,
            otherSidebarWidth: isLeftSidebarCollapsed ? 0 : leftSidebarWidth,
            availableWidth: availableWidth
        )
        return updated
    }

    public func togglingLeftSidebarCollapsed() -> WorkspacePaneLayout {
        var updated = self
        updated.isLeftSidebarCollapsed.toggle()
        return updated
    }

    public func togglingRightSidebarCollapsed() -> WorkspacePaneLayout {
        var updated = self
        updated.isRightSidebarCollapsed.toggle()
        return updated
    }

    public static func proposedLeftSidebarWidth(startWidth: Double, translationWidth: Double) -> Double {
        startWidth + translationWidth
    }

    public static func proposedRightSidebarWidth(startWidth: Double, translationWidth: Double) -> Double {
        startWidth - translationWidth
    }

    private static func normalizedSidebarWidth(_ width: Double, fallback: Double) -> Double {
        guard width.isFinite else {
            return fallback
        }
        return max(minSidebarWidth, width)
    }

    private static func clampedSidebarWidth(
        proposedWidth: Double,
        otherSidebarWidth: Double,
        availableWidth: Double?
    ) -> Double {
        let minimum = minSidebarWidth
        let normalized = normalizedSidebarWidth(proposedWidth, fallback: minimum)
        guard let availableWidth,
              availableWidth.isFinite,
              availableWidth > 0
        else {
            return normalized
        }

        let other = max(0, otherSidebarWidth.isFinite ? otherSidebarWidth : 0)
        let maximum = max(minimum, availableWidth - other - minWorkspaceWidth)
        return min(max(minimum, normalized), maximum)
    }

    private enum CodingKeys: String, CodingKey {
        case leftSidebarWidth
        case rightSidebarWidth
        case isLeftSidebarCollapsed
        case isRightSidebarCollapsed
    }
}
