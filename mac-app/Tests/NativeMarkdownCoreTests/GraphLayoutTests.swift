import Foundation
import Testing
@testable import NativeMarkdownCore

@Test
func graphLayoutMapperBuildsRendererReadyIndexes() {
    let layout = GraphLayoutMapper.map(layoutFixtureSnapshot())

    #expect(layout.nodes.map(\.index) == [0, 1, 2, 3, 4])
    #expect(layout.edges.map(\.sourceIndex) == [0, 2])
    #expect(layout.edges.map(\.targetIndex) == [1, 3])
    #expect(layout.edges.allSatisfy { $0.sourceIndex != $0.targetIndex })
}

@Test
func graphLayoutSeedPositionsAreDeterministic() {
    let first = GraphLayoutMapper.map(layoutFixtureSnapshot())
    let second = GraphLayoutMapper.map(layoutFixtureSnapshot())

    #expect(first.nodes.map(\.position) == second.nodes.map(\.position))
    #expect(first.nodes.map(\.radius) == second.nodes.map(\.radius))
}

@Test
func graphLayoutUsesSmallObsidianLikeNodeRadii() {
    let layout = GraphLayoutMapper.map(radiusFixtureSnapshot())

    #expect(layout.nodes[0].radius == GraphVisualMetrics.defaultNodeRadius)
    #expect(layout.nodes[1].radius < 4.0)
    #expect(layout.nodes[2].radius == GraphVisualMetrics.maximumHubNodeRadius)
    #expect(layout.nodes.allSatisfy { $0.radius < 12.0 })
}

@Test
func graphLayoutComponentsSeparateClustersAndOrphans() {
    let layout = GraphLayoutMapper.map(layoutFixtureSnapshot())

    #expect(layout.components.map(\.nodeIndexes) == [[0, 1], [2, 3], [4]])
    #expect(layout.components.map(\.isOrphanRing) == [false, false, true])
    #expect(abs(centerX(layout, indexes: [0, 1]) - centerX(layout, indexes: [2, 3])) > 300)
    #expect(abs(layout.nodes[4].position.x) > 600 || abs(layout.nodes[4].position.y) > 600)
}

@Test
func graphLayoutBoundsIncludeNodeRadii() {
    let bounds = GraphLayoutBounds.enclosing([
        layoutTestNode(index: 0, id: "file:a", x: -10, y: 0, radius: 2),
        layoutTestNode(index: 1, id: "file:b", x: 20, y: 6, radius: 4)
    ])

    #expect(bounds == GraphLayoutBounds(minX: -12, minY: -2, maxX: 24, maxY: 10))
    #expect(bounds?.width == 36)
    #expect(bounds?.height == 12)
    #expect(bounds?.center == GraphPoint(x: 6, y: 4))
    #expect(GraphLayoutBounds.enclosing([]) == nil)
}

@Test
func graphViewportFitsLayoutBoundsWithPadding() {
    let bounds = GraphLayoutBounds(minX: -100, minY: -50, maxX: 100, maxY: 50)
    let viewport = GraphViewport.fit(
        layoutBounds: bounds,
        canvasSize: GraphSize(width: 500, height: 300),
        padding: 50,
        maximumZoomScale: 10
    )

    #expect(viewport.zoomScale == 2)
    #expect(viewport.panOffset == GraphPoint(x: 0, y: 0))
    #expect(viewport.screenPoint(for: GraphPoint(x: -100, y: -50)) == GraphPoint(x: -200, y: -100))
    #expect(viewport.screenPoint(for: GraphPoint(x: 100, y: 50)) == GraphPoint(x: 200, y: 100))
}

@Test
func graphViewportFitHandlesEmptyAndSingleNodeBounds() {
    let emptyFit = GraphViewport.fit(
        layoutBounds: nil,
        canvasSize: GraphSize(width: 500, height: 300)
    )
    let singleNodeFit = GraphViewport.fit(
        layoutBounds: GraphLayoutBounds(minX: 8, minY: 8, maxX: 12, maxY: 12),
        canvasSize: GraphSize(width: 500, height: 300)
    )

    #expect(emptyFit == GraphViewport())
    #expect(singleNodeFit.zoomScale == GraphVisualMetrics.maximumFitZoomScale)
    #expect(singleNodeFit.screenPoint(for: GraphPoint(x: 10, y: 10)) == GraphPoint(x: 0, y: 0))
}

@Test
func graphLayoutMapperPropagatesCancellation() {
    var checks = 0

    #expect(throws: CancellationError.self) {
        _ = try GraphLayoutMapper.map(largeLayoutFixtureSnapshot(nodeCount: 3_000)) {
            checks += 1
            if checks == 2 {
                throw CancellationError()
            }
        }
    }
}

@Test
func graphViewportRoundTripsCoordinatesAndResets() {
    var viewport = GraphViewport(
        panOffset: GraphPoint(x: 10, y: -20),
        zoomScale: 2
    )
    let graphPoint = GraphPoint(x: 12, y: 8)
    let screenPoint = viewport.screenPoint(for: graphPoint)

    #expect(screenPoint == GraphPoint(x: 34, y: -4))
    #expect(viewport.graphPoint(for: screenPoint) == graphPoint)

    viewport.reset()

    #expect(viewport == GraphViewport())

    viewport.zoomScale = 0
    #expect(viewport.zoomScale == GraphVisualMetrics.minimumZoomScale)
    viewport.zoomScale = .infinity
    #expect(viewport.zoomScale == 1)
}

@Test
func graphViewportFitsLargeLayoutBelowLegacyMinimumZoom() {
    let bounds = GraphLayoutBounds(minX: 0, minY: 0, maxX: 10_000, maxY: 5_000)
    let viewport = GraphViewport.fit(
        layoutBounds: bounds,
        canvasSize: GraphSize(width: 500, height: 300),
        padding: 50
    )

    #expect(viewport.zoomScale == 0.04)
    #expect(viewport.screenPoint(for: bounds.center) == GraphPoint(x: 0, y: 0))
    #expect(viewport.screenPoint(for: GraphPoint(x: bounds.minX, y: bounds.minY)) == GraphPoint(x: -200, y: -100))
    #expect(viewport.screenPoint(for: GraphPoint(x: bounds.maxX, y: bounds.maxY)) == GraphPoint(x: 200, y: 100))
}

@Test
func graphLabelVisibilityUsesFocusSearchAndZoomPolicy() {
    let settings = GraphPresentationSettings()

    #expect(!GraphLabelVisibilityPolicy.isVisible(
        nodeID: "file:1",
        settings: settings,
        context: GraphLabelVisibilityContext(zoomScale: 1)
    ))
    #expect(GraphLabelVisibilityPolicy.isVisible(
        nodeID: "file:1",
        settings: settings,
        context: GraphLabelVisibilityContext(hoveredNodeID: "file:1")
    ))
    #expect(GraphLabelVisibilityPolicy.isVisible(
        nodeID: "file:1",
        settings: settings,
        context: GraphLabelVisibilityContext(searchMatchedNodeIDs: ["file:1"])
    ))
    #expect(GraphLabelVisibilityPolicy.isVisible(
        nodeID: "file:1",
        settings: settings,
        context: GraphLabelVisibilityContext(zoomScale: 1.6)
    ))
}

@Test
func graphLayoutRequestGateRejectsCancelledAndStaleResults() {
    let current = GraphLayoutMapper.map(layoutFixtureSnapshot(requestID: 2, generation: 9))
    let oldRequest = GraphLayoutMapper.map(layoutFixtureSnapshot(requestID: 1, generation: 9))
    let oldGeneration = GraphLayoutMapper.map(layoutFixtureSnapshot(requestID: 2, generation: 8))
    var gate = GraphLayoutRequestGate()

    gate.start(requestID: 2, generation: 9)

    #expect(gate.accepts(current))
    #expect(!gate.accepts(oldRequest))
    #expect(!gate.accepts(oldGeneration))

    gate.cancel(requestID: 2)

    #expect(!gate.accepts(current))
}

@Test
func graphLayoutCacheControllerDoesNotWriteByDefault() {
    let layout = GraphLayoutMapper.map(layoutFixtureSnapshot())
    let key = GraphLayoutCacheKey.make(
        vaultIdentityHash: "vault-hash",
        generation: layout.generation,
        settings: GraphSettings()
    )
    var writer = SpyGraphLayoutCacheWriter()

    GraphLayoutCacheController().writeIfEnabled(layout, key: key, writer: &writer)

    #expect(writer.writeCount == 0)
}

@Test
func graphLayoutCacheKeyIncludesScopeWithoutRawSettingsValues() {
    let settings = GraphSettings(
        searchQuery: "/Users/example/Secret.md",
        groupRules: [
            GraphGroupRule(id: "private-rule", query: "#private/client", colorHex: "#ff00aa")
        ]
    )

    let first = GraphLayoutCacheKey.make(
        vaultIdentityHash: "vault-hash-a",
        generation: 1,
        settings: settings,
        layoutAlgorithmVersion: "layout-v1"
    )
    let second = GraphLayoutCacheKey.make(
        vaultIdentityHash: "vault-hash-a",
        generation: 2,
        settings: settings,
        layoutAlgorithmVersion: "layout-v1"
    )
    let key = first.description

    #expect(first != second)
    #expect(key.hasPrefix("graph-layout-"))
    #expect(!key.contains("Secret"))
    #expect(!key.contains("/Users/example"))
    #expect(!key.contains("#private"))
    #expect(!key.contains("private-rule"))
}

private struct SpyGraphLayoutCacheWriter: GraphLayoutCacheWriting {
    var writeCount = 0

    mutating func writeLayout(_ layout: GraphRendererSnapshot, key: GraphLayoutCacheKey) {
        writeCount += 1
    }
}

private func centerX(_ layout: GraphRendererSnapshot, indexes: [Int]) -> Double {
    let total = indexes.reduce(0.0) { sum, index in
        sum + layout.nodes[index].position.x
    }
    return total / Double(indexes.count)
}

private func layoutTestNode(
    index: Int,
    id: String,
    x: Double,
    y: Double,
    radius: Double
) -> GraphLayoutNode {
    GraphLayoutNode(
        index: index,
        nodeID: id,
        label: id,
        kind: .resolved,
        degree: 1,
        position: GraphPoint(x: x, y: y),
        radius: radius
    )
}

private func layoutFixtureSnapshot(
    requestID: UInt64 = 1,
    generation: UInt64 = 9
) -> WholeVaultGraphSnapshot {
    WholeVaultGraphSnapshot(
        requestID: requestID,
        generation: generation,
        partialReasons: [],
        nodeCountTotal: 5,
        edgeCountTotal: 2,
        nodes: [
            layoutNode("file:1", degree: 1),
            layoutNode("file:2", degree: 1),
            layoutNode("file:3", degree: 1),
            layoutNode("file:4", degree: 1),
            layoutNode("file:5", degree: 0)
        ],
        edges: [
            WholeVaultGraphEdge(
                sourceNodeID: "file:1",
                targetNodeID: "file:2",
                kind: .resolved,
                weight: 1
            ),
            WholeVaultGraphEdge(
                sourceNodeID: "file:3",
                targetNodeID: "file:4",
                kind: .resolved,
                weight: 1
            )
        ]
    )
}

private func largeLayoutFixtureSnapshot(nodeCount: Int) -> WholeVaultGraphSnapshot {
    WholeVaultGraphSnapshot(
        requestID: 1,
        generation: 9,
        partialReasons: [],
        nodeCountTotal: nodeCount,
        edgeCountTotal: 0,
        nodes: (0..<nodeCount).map { index in
            layoutNode("file:\(index)", degree: 0)
        },
        edges: []
    )
}

private func radiusFixtureSnapshot() -> WholeVaultGraphSnapshot {
    WholeVaultGraphSnapshot(
        requestID: 1,
        generation: 9,
        partialReasons: [],
        nodeCountTotal: 3,
        edgeCountTotal: 0,
        nodes: [
            layoutNode("file:zero", degree: 0),
            layoutNode("file:moderate", degree: 4),
            layoutNode("file:hub", degree: 100)
        ],
        edges: []
    )
}

private func layoutNode(_ nodeID: String, degree: Int) -> WholeVaultGraphNode {
    WholeVaultGraphNode(
        nodeID: nodeID,
        fileID: nodeID,
        relativePath: "\(nodeID).md",
        label: nodeID,
        kind: .resolved,
        degree: degree,
        tags: []
    )
}
