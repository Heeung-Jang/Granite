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
    public static let labelCullingPadding = 160.0
    public static let fitPadding = 48.0
    public static let minimumZoomScale = 0.01
    public static let maximumZoomScale = 10.0
    public static let maximumFitZoomScale = 2.5

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

    public static func resolvedNodeOpacity(nodeCount: Int) -> Double {
        densityAdjustedAlpha(
            base: resolvedNodeAlpha,
            minimum: 0.20,
            count: nodeCount,
            denseCount: 10_000
        )
    }

    public static func unresolvedNodeOpacity(nodeCount: Int) -> Double {
        densityAdjustedAlpha(
            base: unresolvedNodeAlpha,
            minimum: 0.12,
            count: nodeCount,
            denseCount: 10_000
        )
    }

    public static func resolvedEdgeOpacity(edgeCount: Int) -> Double {
        densityAdjustedAlpha(
            base: resolvedEdgeAlpha,
            minimum: 0.018,
            count: edgeCount,
            denseCount: 20_000
        )
    }

    public static func unresolvedEdgeOpacity(edgeCount: Int) -> Double {
        densityAdjustedAlpha(
            base: unresolvedEdgeAlpha,
            minimum: 0.01,
            count: edgeCount,
            denseCount: 20_000
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

    private static func densityAdjustedAlpha(
        base: Double,
        minimum: Double,
        count: Int,
        denseCount: Int
    ) -> Double {
        guard count > 1_000 else {
            return base
        }

        let denominator = max(1, denseCount - 1_000)
        let progress = min(1.0, Double(count - 1_000) / Double(denominator))
        return base + (minimum - base) * progress
    }
}
