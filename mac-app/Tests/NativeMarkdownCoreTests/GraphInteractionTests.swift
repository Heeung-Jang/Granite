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
func graphHitTestIgnoresDistantNodes() {
    let result = GraphHitTestIndex(layout: interactionLayout()).nearestNode(
        at: GraphPoint(x: 20, y: 20),
        viewport: GraphViewport(),
        canvasSize: GraphSize(width: 400, height: 200)
    )

    #expect(result == nil)
}

@Test
func graphHitTestBuildsSpatialBuckets() {
    let index = GraphHitTestIndex(layout: interactionLayout(), bucketCellSize: 40)

    #expect(index.bucketCount > 1)
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

private func interactionNode(
    index: Int,
    id: String,
    label: String,
    fileID: String?,
    relativePath: String? = nil,
    kind: WholeVaultGraphNodeKind,
    x: Double = 0,
    y: Double = 0
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
        radius: 6
    )
}
