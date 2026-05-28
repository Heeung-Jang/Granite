import Foundation

public enum GraphFallbackPolicy {
    public static let unresolvedFallbackBannerText = "Showing unresolved links because no resolved note links were found"

    public static func shouldRequestUnresolvedFallback(
        settings: GraphSemanticSettings,
        payload: WholeVaultGraphPayload
    ) -> Bool {
        !settings.includeUnresolved
            && !settings.includeOrphans
            && payload.state == .complete
            && payload.snapshot.nodes.isEmpty
            && payload.snapshot.edges.isEmpty
    }

    public static func unresolvedFallbackRequest(
        from request: WholeVaultGraphRequest,
        requestID: UInt64
    ) -> WholeVaultGraphRequest {
        WholeVaultGraphRequest(
            requestID: requestID,
            generation: request.generation,
            includeUnresolved: true,
            includeOrphans: false,
            maxNodes: request.maxNodes,
            maxEdges: request.maxEdges,
            byteCapBytes: request.byteCapBytes
        )
    }
}
