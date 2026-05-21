import Foundation
import Testing
@testable import NativeMarkdownCore

@Test
func graphHitTestPicksNearestVisibleNode() {
    let layout = interactionLayout()
    let hitTest = GraphHitTestIndex(layout: layout)

    let result = hitTest.nearestNode(
        at: GraphPoint(x: 203, y: 100),
        viewport: GraphViewport(),
        canvasSize: GraphSize(width: 400, height: 200)
    )

    #expect(result?.nodeID == "file:a")
    #expect(result?.nodeIndex == 0)
}

@Test
func graphHitTestResultUsesArrayIndex() {
    let layout = GraphRendererSnapshot(
        requestID: 1,
        generation: 1,
        nodes: [
            interactionNode(index: 42, id: "file:a", label: "Alpha", fileID: "alpha.md", kind: .resolved)
        ],
        edges: [],
        components: []
    )

    let result = GraphHitTestIndex(layout: layout).nearestNode(
        at: GraphPoint(x: 200, y: 100),
        viewport: GraphViewport(),
        canvasSize: GraphSize(width: 400, height: 200)
    )

    #expect(result?.nodeIndex == 0)
}

@Test
func graphHitTestIgnoresDistantNodes() {
    let result = GraphHitTestIndex(layout: interactionLayout()).nearestNode(
        at: GraphPoint(x: 20, y: 20),
        viewport: GraphViewport(),
        canvasSize: GraphSize(width: 400, height: 200)
    )

    #expect(result == nil)
}

@Test
func graphHitTestUsesScreenHitRadiusIndependentFromVisualRadius() {
    let layout = GraphRendererSnapshot(
        requestID: 1,
        generation: 1,
        nodes: [
            interactionNode(
                index: 0,
                id: "file:small",
                label: "Small",
                fileID: "small.md",
                relativePath: "Small.md",
                kind: .resolved,
                radius: GraphVisualMetrics.minimumDrawRadius
            )
        ],
        edges: [],
        components: []
    )
    let hitTest = GraphHitTestIndex(layout: layout)
    let canvasSize = GraphSize(width: 400, height: 200)

    let hit = hitTest.nearestNode(
        at: GraphPoint(x: 207.5, y: 100),
        viewport: GraphViewport(),
        canvasSize: canvasSize
    )
    let miss = hitTest.nearestNode(
        at: GraphPoint(x: 209.5, y: 100),
        viewport: GraphViewport(),
        canvasSize: canvasSize
    )

    #expect(hit?.nodeID == "file:small")
    #expect(miss == nil)
}

@Test
func graphHitTestBuildsSpatialBuckets() {
    let index = GraphHitTestIndex(layout: interactionLayout(), bucketCellSize: 40)

    #expect(index.bucketCount > 1)
}

@Test
func graphHitTestIndexPropagatesCancellation() {
    var checks = 0

    #expect(throws: CancellationError.self) {
        _ = try GraphHitTestIndex(layout: largeInteractionLayout(nodeCount: 3_000)) {
            checks += 1
            if checks == 2 {
                throw CancellationError()
            }
        }
    }
}

@Test
func graphHitTestUsesPositionOverrideForMovedNode() {
    let layout = interactionLayout()
    let hitTest = GraphHitTestIndex(layout: layout)
    let canvasSize = GraphSize(width: 400, height: 200)
    var overrides = GraphNodePositionOverrides()

    overrides.set(GraphPoint(x: 160, y: 0), for: "file:a")

    let movedHit = hitTest.nearestNode(
        at: GraphPoint(x: 360, y: 100),
        viewport: GraphViewport(),
        canvasSize: canvasSize,
        positionOverrides: overrides
    )
    let oldPositionHit = hitTest.nearestNode(
        at: GraphPoint(x: 200, y: 100),
        viewport: GraphViewport(),
        canvasSize: canvasSize,
        positionOverrides: overrides
    )

    #expect(movedHit?.nodeID == "file:a")
    #expect(oldPositionHit == nil)
}

@Test
func graphHitTestIndexMovesDroppedNodeIncrementally() {
    let layout = interactionLayout()
    let hitTest = GraphHitTestIndex(layout: layout, bucketCellSize: 40)
    let movedIndex = hitTest.movingNode(nodeID: "file:a", to: GraphPoint(x: 160, y: 0))
    let canvasSize = GraphSize(width: 400, height: 200)

    let movedHit = movedIndex.nearestNode(
        at: GraphPoint(x: 360, y: 100),
        viewport: GraphViewport(),
        canvasSize: canvasSize
    )
    let oldPositionHit = movedIndex.nearestNode(
        at: GraphPoint(x: 200, y: 100),
        viewport: GraphViewport(),
        canvasSize: canvasSize
    )

    #expect(movedIndex.layout.nodes[0].position == GraphPoint(x: 160, y: 0))
    #expect(movedIndex.layout.renderIdentity != hitTest.layout.renderIdentity)
    #expect(movedHit?.nodeID == "file:a")
    #expect(oldPositionHit == nil)
}

@Test
func graphInteractionKeepsSelectionIndependentFromHover() {
    var interaction = GraphInteractionState()

    interaction.select("file:a")
    interaction.hover("file:b")

    #expect(interaction.selectedNodeID == "file:a")
    #expect(interaction.hoveredNodeID == "file:b")

    interaction.hover(nil)

    #expect(interaction.selectedNodeID == "file:a")
    #expect(interaction.hoveredNodeID == nil)
}

@Test
func graphInteractionTracksNodeDragThresholdAndFinish() {
    var interaction = GraphInteractionState()

    interaction.beginDrag(
        nodeID: "file:a",
        nodePosition: GraphPoint(x: 100, y: 100),
        pointerGraphPoint: GraphPoint(x: 10, y: 10),
        graphMovementThreshold: 5
    )
    interaction.updateDrag(to: GraphPoint(x: 12, y: 14))
    let belowThreshold = interaction.dragState
    interaction.updateDrag(to: GraphPoint(x: 16, y: 18))
    let result = interaction.finishDrag()

    #expect(belowThreshold?.movedBeyondThreshold == false)
    #expect(belowThreshold?.currentNodePosition == GraphPoint(x: 102, y: 104))
    #expect(result == GraphNodeDragResult(
        nodeID: "file:a",
        nodePosition: GraphPoint(x: 106, y: 108),
        movedBeyondThreshold: true
    ))
    #expect(interaction.dragState == nil)
}

@Test
func graphInteractionCanCancelNodeDrag() {
    var interaction = GraphInteractionState()

    interaction.beginDrag(
        nodeID: "file:a",
        nodePosition: GraphPoint(x: 20, y: 20),
        pointerGraphPoint: GraphPoint(x: 0, y: 0)
    )
    interaction.updateDrag(to: GraphPoint(x: 20, y: 0))
    interaction.cancelDrag()

    #expect(interaction.dragState == nil)
    #expect(interaction.finishDrag() == nil)
}

@Test
func graphNodePositionOverridesUseDraggedPositionOnlyForMatchingNode() {
    let layout = interactionLayout()
    var overrides = GraphNodePositionOverrides()

    overrides.set(GraphPoint(x: 42, y: 84), for: "file:a")

    #expect(overrides.position(for: layout.nodes[0]) == GraphPoint(x: 42, y: 84))
    #expect(overrides.position(for: layout.nodes[1]) == layout.nodes[1].position)
    #expect(!overrides.isEmpty)
    #expect(overrides.renderIdentity != GraphNodePositionOverrides().renderIdentity)
}

@Test
func graphRendererInputUsesPositionOverridesWithoutChangingLayout() {
    let layout = interactionLayout()
    var overrides = GraphNodePositionOverrides()

    overrides.set(GraphPoint(x: 40, y: 50), for: "file:a")
    let input = GraphRendererInput(layout: layout, positionOverrides: overrides)

    #expect(input.position(for: layout.nodes[0]) == GraphPoint(x: 40, y: 50))
    #expect(input.position(for: layout.nodes[1]) == layout.nodes[1].position)
    #expect(input.layout == layout)
}

@Test
func graphGestureDecisionStartsNodeDragFromHitNode() {
    let layout = interactionLayout()
    let decision = GraphGestureDecision.dragStart(
        screenPoint: GraphPoint(x: 200, y: 100),
        viewport: GraphViewport(),
        canvasSize: GraphSize(width: 400, height: 200),
        hitTestIndex: GraphHitTestIndex(layout: layout),
        screenMovementThreshold: 6
    )

    #expect(decision == .node(GraphNodeDragStart(
        nodeID: "file:a",
        nodeIndex: 0,
        nodePosition: layout.nodes[0].position,
        pointerGraphPoint: GraphPoint(x: 0, y: 0),
        graphMovementThreshold: 6
    )))
}

@Test
func graphGestureDecisionStartsNodeDragFromOverriddenPosition() {
    let layout = interactionLayout()
    var overrides = GraphNodePositionOverrides()

    overrides.set(GraphPoint(x: 160, y: 0), for: "file:a")
    let decision = GraphGestureDecision.dragStart(
        screenPoint: GraphPoint(x: 360, y: 100),
        viewport: GraphViewport(),
        canvasSize: GraphSize(width: 400, height: 200),
        hitTestIndex: GraphHitTestIndex(layout: layout),
        positionOverrides: overrides
    )

    if case .node(let start) = decision {
        #expect(start.nodeID == "file:a")
        #expect(start.nodePosition == GraphPoint(x: 160, y: 0))
    } else {
        Issue.record("Expected node drag decision")
    }
}

@Test
func graphGestureDecisionStartsCanvasPanWhenNoNodeIsHit() {
    let decision = GraphGestureDecision.dragStart(
        screenPoint: GraphPoint(x: 20, y: 20),
        viewport: GraphViewport(),
        canvasSize: GraphSize(width: 400, height: 200),
        hitTestIndex: GraphHitTestIndex(layout: interactionLayout())
    )

    #expect(decision == .canvasPan)
}

@Test
func graphGestureDecisionConvertsScreenThresholdToGraphThreshold() {
    let decision = GraphGestureDecision.dragStart(
        screenPoint: GraphPoint(x: 200, y: 100),
        viewport: GraphViewport(zoomScale: 0.5),
        canvasSize: GraphSize(width: 400, height: 200),
        hitTestIndex: GraphHitTestIndex(layout: interactionLayout()),
        screenMovementThreshold: 6
    )

    if case .node(let start) = decision {
        #expect(start.graphMovementThreshold == 12)
    } else {
        Issue.record("Expected node drag decision")
    }
}

@Test
func graphGestureDecisionClassifiesTapAndNodeDragCompletion() {
    let tap = GraphNodeDragResult(
        nodeID: "file:a",
        nodePosition: GraphPoint(x: 0, y: 0),
        movedBeyondThreshold: false
    )
    let drag = GraphNodeDragResult(
        nodeID: "file:a",
        nodePosition: GraphPoint(x: 10, y: 10),
        movedBeyondThreshold: true
    )

    #expect(GraphGestureDecision.completion(for: tap) == .tap(nodeID: "file:a"))
    #expect(GraphGestureDecision.completion(for: drag) == .drag(drag))
}

@Test
func graphDragPerformanceBenchmarkTimesPreRendererPathFor60kNodes() {
    let result = GraphDragPerformanceBenchmark.run()
    let usesStrictBudget = ProcessInfo.processInfo.environment["GRANITE_STRICT_GRAPH_DRAG_BENCHMARK"] == "1"

    #expect(result.nodeCount == 60_000)
    #expect(result.sampleCount == GraphDragPerformanceBenchmark.defaultSampleCount)
    #expect(result.finishedDragResult?.movedBeyondThreshold == true)
    if usesStrictBudget {
        #expect(result.p95FrameDurationMilliseconds <= GraphDragPerformanceBenchmark.strictP95BudgetMilliseconds)
        #expect(result.p99FrameDurationMilliseconds <= GraphDragPerformanceBenchmark.strictP99BudgetMilliseconds)
        #expect(result.mainThreadStallMilliseconds <= GraphDragPerformanceBenchmark.strictMainThreadStallBudgetMilliseconds)
    } else {
        #expect(result.p99FrameDurationMilliseconds <= 250)
    }
}

@Test
func graphHitTestDropBenchmarkUpdates60kIndexWithinBudget() {
    let result = GraphHitTestDropBenchmark.run()
    let usesStrictBudget = ProcessInfo.processInfo.environment["GRANITE_STRICT_GRAPH_HIT_TEST_DROP_BENCHMARK"] == "1"

    #expect(result.nodeCount == 60_000)
    #expect(result.hitTestReady)
    if usesStrictBudget {
        #expect(result.durationMilliseconds <= GraphHitTestDropBenchmark.strictHardFailMilliseconds)
    } else {
        #expect(result.durationMilliseconds <= 250)
    }
}

@Test
func graphSearchMatcherHighlightsWithoutChangingMembership() {
    let layout = interactionLayout()

    let matches = GraphSearchMatcher.matchingNodeIDs(in: layout, query: "alpha")
    let noMatches = GraphSearchMatcher.matchingNodeIDs(in: layout, query: "missing")

    #expect(matches == ["file:a"])
    #expect(noMatches.isEmpty)
    #expect(layout.nodes.count == 3)
}

@Test
func graphNodeOpenResolverOnlyOpensResolvedFileNodes() {
    let resolved = interactionNode(
        index: 0,
        id: "file:a",
        label: "Alpha",
        fileID: "alpha.md",
        relativePath: "Folder/Alpha.md",
        kind: .resolved
    )
    let unresolved = interactionNode(index: 1, id: "unresolved:ghost", label: "Ghost", fileID: nil, kind: .unresolved)

    #expect(GraphNodeOpenResolver.file(for: resolved) == FileTreeItem(relativePath: "Folder/Alpha.md"))
    #expect(GraphNodeOpenResolver.file(for: unresolved) == nil)
}

@Test
func graphAccessibilitySummaryOmitsHiddenDebugIdentifiers() {
    let layout = interactionLayout()
    let input = GraphRendererInput(
        layout: layout,
        viewport: GraphViewport(zoomScale: 1.6),
        searchMatchedNodeIDs: ["file:a"]
    )
    let summary = GraphAccessibilitySummaryBuilder.summary(
        input: input,
        selectedNode: layout.nodes[0]
    )

    #expect(summary.contains("3 nodes"))
    #expect(summary.contains("2 edges"))
    #expect(summary.contains("1 search matches"))
    #expect(summary.contains("selected Alpha"))
    #expect(summary.contains("zoom 1.6"))
    #expect(!summary.contains("Alpha.md"))
    #expect(!summary.contains("file:a"))
}

private func interactionLayout() -> GraphRendererSnapshot {
    GraphRendererSnapshot(
        requestID: 1,
        generation: 1,
        nodes: [
            interactionNode(index: 0, id: "file:a", label: "Alpha", fileID: "alpha.md", relativePath: "Alpha.md", kind: .resolved, x: 0, y: 0),
            interactionNode(index: 1, id: "file:b", label: "Beta", fileID: "beta.md", relativePath: "Beta.md", kind: .resolved, x: 80, y: 0),
            interactionNode(index: 2, id: "unresolved:ghost", label: "Ghost", fileID: nil, kind: .unresolved, x: 0, y: 80)
        ],
        edges: [
            GraphLayoutEdge(sourceIndex: 0, targetIndex: 1, kind: .resolved, weight: 1),
            GraphLayoutEdge(sourceIndex: 0, targetIndex: 2, kind: .unresolved, weight: 1)
        ],
        components: [
            GraphLayoutComponent(nodeIndexes: [0, 1, 2], isOrphanRing: false)
        ]
    )
}

private func largeInteractionLayout(nodeCount: Int) -> GraphRendererSnapshot {
    GraphRendererSnapshot(
        requestID: 1,
        generation: 1,
        nodes: (0..<nodeCount).map { index in
            interactionNode(
                index: index,
                id: "file:\(index)",
                label: "Node \(index)",
                fileID: "\(index).md",
                relativePath: "\(index).md",
                kind: .resolved,
                x: Double(index),
                y: 0
            )
        },
        edges: [],
        components: [
            GraphLayoutComponent(
                nodeIndexes: Array(0..<nodeCount),
                isOrphanRing: false
            )
        ]
    )
}

private func interactionNode(
    index: Int,
    id: String,
    label: String,
    fileID: String?,
    relativePath: String? = nil,
    kind: WholeVaultGraphNodeKind,
    x: Double = 0,
    y: Double = 0,
    radius: Double = 6
) -> GraphLayoutNode {
    GraphLayoutNode(
        index: index,
        nodeID: id,
        fileID: fileID,
        relativePath: relativePath,
        label: label,
        kind: kind,
        degree: 1,
        position: GraphPoint(x: x, y: y),
        radius: radius
    )
}
