import Foundation
import Testing
@testable import NativeMarkdownCore

@Test
func graphFallbackPolicyRequestsUnresolvedFallbackForEmptyCompleteResolvedGraph() {
    let payload = graphPayload(state: .complete, nodes: [], edges: [])

    #expect(GraphFallbackPolicy.shouldRequestUnresolvedFallback(
        settings: GraphSemanticSettings(),
        payload: payload
    ))
}

@Test
func graphFallbackPolicyDoesNotFallbackForPartialOrVisibleGraphs() {
    #expect(!GraphFallbackPolicy.shouldRequestUnresolvedFallback(
        settings: GraphSemanticSettings(),
        payload: graphPayload(state: .partial, nodes: [], edges: [])
    ))
    #expect(!GraphFallbackPolicy.shouldRequestUnresolvedFallback(
        settings: GraphSemanticSettings(),
        payload: graphPayload(state: .complete, nodes: [graphNode()], edges: [])
    ))
    #expect(!GraphFallbackPolicy.shouldRequestUnresolvedFallback(
        settings: GraphSemanticSettings(),
        payload: graphPayload(state: .complete, nodes: [], edges: [graphEdge()])
    ))
}

@Test
func graphFallbackPolicyDoesNotFallbackWhenUserEnabledUnresolvedOrOrphans() {
    let payload = graphPayload(state: .complete, nodes: [], edges: [])

    #expect(!GraphFallbackPolicy.shouldRequestUnresolvedFallback(
        settings: GraphSemanticSettings(includeUnresolved: true),
        payload: payload
    ))
    #expect(!GraphFallbackPolicy.shouldRequestUnresolvedFallback(
        settings: GraphSemanticSettings(includeOrphans: true),
        payload: payload
    ))
}

@Test
func graphFallbackPolicyBuildsOneShotUnresolvedRequestWithoutOrphans() {
    let original = WholeVaultGraphRequest(
        requestID: 10,
        generation: 7,
        includeUnresolved: false,
        includeOrphans: false,
        maxNodes: 123,
        maxEdges: 456,
        byteCapBytes: 789
    )

    let fallback = GraphFallbackPolicy.unresolvedFallbackRequest(
        from: original,
        requestID: 11
    )

    #expect(fallback.requestID == 11)
    #expect(fallback.generation == 7)
    #expect(fallback.includeUnresolved)
    #expect(!fallback.includeOrphans)
    #expect(fallback.maxNodes == 123)
    #expect(fallback.maxEdges == 456)
    #expect(fallback.byteCapBytes == 789)
}

private func graphPayload(
    state: WholeVaultGraphState,
    nodes: [WholeVaultGraphNode],
    edges: [WholeVaultGraphEdge]
) -> WholeVaultGraphPayload {
    WholeVaultGraphPayload(
        payloadVersion: WholeVaultGraphRequest.payloadVersion,
        requestID: 1,
        generation: 1,
        state: state,
        metrics: WholeVaultGraphMetrics(
            snapshotDurationMilliseconds: 1,
            encodedPayloadBytes: 1
        ),
        snapshot: WholeVaultGraphSnapshot(
            requestID: 1,
            generation: 1,
            partialReasons: state == .partial ? [.maxNodes] : [],
            nodeCountTotal: nodes.count,
            edgeCountTotal: edges.count,
            nodes: nodes,
            edges: edges
        )
    )
}

private func graphNode() -> WholeVaultGraphNode {
    WholeVaultGraphNode(
        nodeID: "file:home",
        fileID: "home",
        relativePath: "Home.md",
        label: "Home",
        kind: .resolved,
        degree: 1
    )
}

private func graphEdge() -> WholeVaultGraphEdge {
    WholeVaultGraphEdge(
        sourceNodeID: "file:home",
        targetNodeID: "file:target",
        kind: .resolved,
        weight: 1
    )
}
