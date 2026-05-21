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
func graphLayoutComponentsSeparateClustersAndOrphans() {
    let layout = GraphLayoutMapper.map(layoutFixtureSnapshot())

    #expect(layout.components.map(\.nodeIndexes) == [[0, 1], [2, 3], [4]])
    #expect(layout.components.map(\.isOrphanRing) == [false, false, true])
    #expect(abs(centerX(layout, indexes: [0, 1]) - centerX(layout, indexes: [2, 3])) > 300)
    #expect(abs(layout.nodes[4].position.x) > 600 || abs(layout.nodes[4].position.y) > 600)
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
    #expect(viewport.zoomScale == 0.1)
    viewport.zoomScale = .infinity
    #expect(viewport.zoomScale == 1)
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
