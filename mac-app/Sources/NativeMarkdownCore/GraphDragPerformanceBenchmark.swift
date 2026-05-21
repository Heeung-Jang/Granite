import Foundation

public struct GraphDragPerformanceBenchmarkResult: Equatable, Sendable {
    public let nodeCount: Int
    public let sampleCount: Int
    public let p95FrameDurationMilliseconds: Double
    public let p99FrameDurationMilliseconds: Double
    public let mainThreadStallMilliseconds: Double
    public let finishedDragResult: GraphNodeDragResult?
}

public enum GraphDragPerformanceBenchmark {
    public static let defaultNodeCount = 60_000
    public static let defaultSampleCount = 120
    public static let strictP95BudgetMilliseconds = 16.67
    public static let strictP99BudgetMilliseconds = 33.33
    public static let strictMainThreadStallBudgetMilliseconds = 50.0

    public static func run(
        nodeCount: Int = defaultNodeCount,
        sampleCount: Int = defaultSampleCount
    ) -> GraphDragPerformanceBenchmarkResult {
        let layout = syntheticLayout(nodeCount: nodeCount)
        let hitTestIndex = GraphHitTestIndex(layout: layout)
        let canvasSize = GraphSize(width: 1_200, height: 800)
        var interaction = GraphInteractionState()
        var durations: [Double] = []

        guard let firstNode = layout.nodes.first else {
            return GraphDragPerformanceBenchmarkResult(
                nodeCount: 0,
                sampleCount: 0,
                p95FrameDurationMilliseconds: 0,
                p99FrameDurationMilliseconds: 0,
                mainThreadStallMilliseconds: 0,
                finishedDragResult: nil
            )
        }

        interaction.beginDrag(
            nodeID: firstNode.nodeID,
            nodePosition: firstNode.position,
            pointerGraphPoint: firstNode.position,
            graphMovementThreshold: 1
        )

        for sample in 0..<sampleCount {
            let timer = AppTelemetryTimer()
            let pointer = GraphPoint(
                x: firstNode.position.x + Double(sample + 1),
                y: firstNode.position.y + Double(sample % 7)
            )
            interaction.updateDrag(to: pointer)
            let overrides = positionOverrides(from: interaction)
            let input = GraphRendererInput(
                layout: layout,
                positionOverrides: overrides
            )
            _ = hitTestIndex.nearestNode(
                at: screenPoint(for: pointer, canvasSize: canvasSize),
                viewport: input.viewport,
                canvasSize: canvasSize,
                positionOverrides: overrides
            )
            durations.append(timer.elapsedMilliseconds())
        }

        let result = interaction.finishDrag()
        return GraphDragPerformanceBenchmarkResult(
            nodeCount: nodeCount,
            sampleCount: durations.count,
            p95FrameDurationMilliseconds: percentile(0.95, values: durations),
            p99FrameDurationMilliseconds: percentile(0.99, values: durations),
            mainThreadStallMilliseconds: durations.max() ?? 0,
            finishedDragResult: result
        )
    }

    private static func positionOverrides(
        from interaction: GraphInteractionState
    ) -> GraphNodePositionOverrides {
        var overrides = GraphNodePositionOverrides()
        if let dragState = interaction.dragState {
            overrides.set(dragState.currentNodePosition, for: dragState.nodeID)
        }
        return overrides
    }

    private static func screenPoint(for graphPoint: GraphPoint, canvasSize: GraphSize) -> GraphPoint {
        GraphPoint(
            x: canvasSize.width / 2 + graphPoint.x,
            y: canvasSize.height / 2 + graphPoint.y
        )
    }

    private static func percentile(_ percentile: Double, values: [Double]) -> Double {
        guard !values.isEmpty else {
            return 0
        }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * percentile).rounded(.up))
        return sorted[min(max(index, 0), sorted.count - 1)]
    }

    private static func syntheticLayout(nodeCount: Int) -> GraphRendererSnapshot {
        let columns = max(1, Int(Double(max(1, nodeCount)).squareRoot()))
        let nodes = (0..<nodeCount).map { index in
            GraphLayoutNode(
                index: index,
                nodeID: "file:\(index)",
                fileID: "\(index).md",
                relativePath: "\(index).md",
                label: "Node \(index)",
                kind: .resolved,
                degree: 1,
                position: GraphPoint(
                    x: Double(index % columns) * 18,
                    y: Double(index / columns) * 18
                ),
                radius: GraphVisualMetrics.defaultNodeRadius
            )
        }
        return GraphRendererSnapshot(
            requestID: 1,
            generation: 1,
            nodes: nodes,
            edges: [],
            components: [
                GraphLayoutComponent(
                    nodeIndexes: Array(0..<nodeCount),
                    isOrphanRing: false
                )
            ]
        )
    }
}
