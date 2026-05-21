import Foundation

public struct GraphViewportFitBenchmarkResult: Equatable, Sendable {
    public let nodeCount: Int
    public let boundsDurationMilliseconds: Double
    public let fitDurationMilliseconds: Double
    public let viewport: GraphViewport

    public var totalDurationMilliseconds: Double {
        boundsDurationMilliseconds + fitDurationMilliseconds
    }
}

public enum GraphViewportFitBenchmark {
    public static func run(
        nodeCount: Int = 60_000,
        canvasSize: GraphSize = GraphSize(width: 1440, height: 900)
    ) -> GraphViewportFitBenchmarkResult {
        let nodes = syntheticNodes(nodeCount: nodeCount)

        let boundsTimer = AppTelemetryTimer()
        let bounds = GraphLayoutBounds.enclosing(nodes)
        let boundsDuration = boundsTimer.elapsedMilliseconds()

        let fitTimer = AppTelemetryTimer()
        let viewport = GraphViewport.fit(layoutBounds: bounds, canvasSize: canvasSize)
        let fitDuration = fitTimer.elapsedMilliseconds()

        return GraphViewportFitBenchmarkResult(
            nodeCount: nodeCount,
            boundsDurationMilliseconds: boundsDuration,
            fitDurationMilliseconds: fitDuration,
            viewport: viewport
        )
    }

    private static func syntheticNodes(nodeCount: Int) -> [GraphLayoutNode] {
        (0..<nodeCount).map { index in
            let column = index % 300
            let row = index / 300
            return GraphLayoutNode(
                index: index,
                nodeID: "file:\(index)",
                label: "node-\(index)",
                kind: .resolved,
                degree: index % 12,
                position: GraphPoint(
                    x: Double(column) * 14.0,
                    y: Double(row) * 14.0
                ),
                radius: GraphVisualMetrics.nodeRadius(forDegree: index % 12)
            )
        }
    }
}
