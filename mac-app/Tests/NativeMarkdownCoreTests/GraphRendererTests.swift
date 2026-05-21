import Testing
@testable import NativeMarkdownCore

@Test
func graphRendererContractValidatesSharedInputAndBuildsMetrics() throws {
    let input = GraphRendererInput(layout: rendererFixtureLayout())
    let renderer = GraphRendererContract(rendererKind: .canvas)

    try renderer.validate(input)
    let metrics = renderer.metrics(for: input, drawDurationMilliseconds: 3.5)

    #expect(metrics == GraphRendererMetrics(
        rendererKind: .canvas,
        nodeCount: 3,
        edgeCount: 2,
        drawDurationMilliseconds: 3.5
    ))
}

@Test
func graphRendererInputAllowsEmptyGraphWithoutEdges() throws {
    let input = GraphRendererInput(layout: GraphRendererSnapshot(
        requestID: 1,
        generation: 1,
        nodes: [],
        edges: [],
        components: []
    ))

    try input.validate()
}

@Test
func graphRendererInputRejectsInvalidEdgeEndpoints() {
    let input = GraphRendererInput(layout: GraphRendererSnapshot(
        requestID: 1,
        generation: 1,
        nodes: [rendererNode(index: 0, id: "file:a", degree: 1)],
        edges: [
            GraphLayoutEdge(sourceIndex: 0, targetIndex: 3, kind: .resolved, weight: 1)
        ],
        components: [
            GraphLayoutComponent(nodeIndexes: [0], isOrphanRing: false)
        ]
    ))

    #expect(throws: GraphRendererValidationError.edgeEndpointOutOfBounds) {
        try input.validate()
    }
}

@Test
func graphRendererInputUsesLabelVisibilityPolicy() {
    let node = rendererNode(index: 0, id: "file:a", degree: 1)
    let layout = GraphRendererSnapshot(
        requestID: 1,
        generation: 1,
        nodes: [node],
        edges: [],
        components: [GraphLayoutComponent(nodeIndexes: [0], isOrphanRing: false)]
    )

    let denseInput = GraphRendererInput(layout: layout)
    let selectedInput = GraphRendererInput(layout: layout, selectedNodeID: "file:a")
    let searchInput = GraphRendererInput(layout: layout, searchMatchedNodeIDs: ["file:a"])
    let zoomedInput = GraphRendererInput(layout: layout, viewport: GraphViewport(zoomScale: 1.6))

    #expect(!denseInput.labelIsVisible(for: node))
    #expect(selectedInput.labelIsVisible(for: node))
    #expect(searchInput.labelIsVisible(for: node))
    #expect(zoomedInput.labelIsVisible(for: node))
}

@Test
func graphRendererFailureStateRetainsPreviousStableGraph() {
    let stable = GraphStableGraphSummary(generation: 2, nodeCount: 3, edgeCount: 2)
    var model = GraphWorkspaceModel()

    model.applyStableGraph(stable)
    model.fail(.rendererFailed)

    #expect(model.state == .rendererFailed)
    #expect(model.shouldDisplayPreviousStableGraph)
    #expect(model.previousStableGraph == stable)
}

private func rendererFixtureLayout() -> GraphRendererSnapshot {
    GraphRendererSnapshot(
        requestID: 1,
        generation: 1,
        nodes: [
            rendererNode(index: 0, id: "file:a", degree: 2),
            rendererNode(index: 1, id: "file:b", degree: 1),
            rendererNode(index: 2, id: "file:c", degree: 1)
        ],
        edges: [
            GraphLayoutEdge(sourceIndex: 0, targetIndex: 1, kind: .resolved, weight: 2),
            GraphLayoutEdge(sourceIndex: 0, targetIndex: 2, kind: .resolved, weight: 1)
        ],
        components: [
            GraphLayoutComponent(nodeIndexes: [0, 1, 2], isOrphanRing: false)
        ]
    )
}

private func rendererNode(index: Int, id: String, degree: Int) -> GraphLayoutNode {
    GraphLayoutNode(
        index: index,
        nodeID: id,
        label: id,
        kind: .resolved,
        degree: degree,
        position: GraphPoint(x: Double(index * 20), y: 0),
        radius: 4
    )
}
