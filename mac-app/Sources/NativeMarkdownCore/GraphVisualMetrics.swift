public enum GraphVisualMetrics {
    public static let defaultNodeRadius = 2.2
    public static let maximumHubNodeRadius = 5.0
    public static let minimumDrawRadius = 1.25

    public static let defaultLinkThickness = 0.6
    public static let minimumLinkThickness = 0.35
    public static let activeLinkThicknessBonus = 0.8

    public static let resolvedNodeAlpha = 0.7
    public static let unresolvedNodeAlpha = 0.36
    public static let activeNodeAlpha = 0.95

    public static let resolvedEdgeAlpha = 0.16
    public static let unresolvedEdgeAlpha = 0.08
    public static let activeEdgeAlpha = 0.38

    public static let defaultHitRadius = 8.0
    public static let hitRadiusPadding = 4.0

    public static func nodeRadius(forDegree degree: Int) -> Double {
        min(
            maximumHubNodeRadius,
            defaultNodeRadius + Double(max(0, degree)).squareRoot() * 0.45
        )
    }

    public static func drawRadius(forNodeRadius nodeRadius: Double, nodeSize: Double) -> Double {
        max(minimumDrawRadius, nodeRadius * nodeSize)
    }

    public static func linkThickness(base: Double, isActive: Bool) -> Double {
        max(
            minimumLinkThickness,
            base + (isActive ? activeLinkThicknessBonus : 0)
        )
    }

    public static func hitRadius(
        forNodeRadius nodeRadius: Double,
        zoomScale: Double,
        minimumHitRadius: Double = defaultHitRadius
    ) -> Double {
        max(
            minimumHitRadius,
            nodeRadius * max(0.1, zoomScale) + hitRadiusPadding
        )
    }
}
