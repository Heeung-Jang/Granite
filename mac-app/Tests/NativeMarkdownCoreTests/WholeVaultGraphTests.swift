import Foundation
import Testing
@testable import NativeMarkdownCore

@Test
func wholeVaultGraphModelsDecodeValidFixturePayload() throws {
    let payload = try EngineGraphClient.decodeEnvelope(graphEnvelope())

    #expect(payload.payloadVersion == 1)
    #expect(payload.requestID == 7)
    #expect(payload.generation == 3)
    #expect(payload.state == .complete)
    #expect(payload.snapshot.nodes.count == 2)
    #expect(payload.snapshot.edges.count == 1)
    #expect(payload.snapshot.nodes[0].kind == .resolved)
    #expect(payload.snapshot.nodes[0].fileID == "home")
    #expect(payload.snapshot.nodes[0].relativePath == "Folder/Home.md")
    #expect(payload.snapshot.edges[0].kind == .resolved)
}

@Test
func wholeVaultGraphValidationRejectsMalformedPayloads() throws {
    #expect(throws: Error.self) {
        _ = try EngineGraphClient.decodeEnvelope(graphEnvelope(nodeIDOverride: "file:2"))
    }
    #expect(throws: Error.self) {
        _ = try EngineGraphClient.decodeEnvelope(graphEnvelope(edgeWeight: 0))
    }
    #expect(throws: Error.self) {
        _ = try EngineGraphClient.decodeEnvelope(graphEnvelope(nodeKind: "BadKind"))
    }
    #expect(throws: Error.self) {
        _ = try EngineGraphClient.decodeEnvelope(
            graphEnvelope(state: "partial", partialReasons: ["MaxLabelBytes"], nodeCountTotal: 3)
        )
    }
}

@Test
func wholeVaultGraphValidationRejectsOversizedEnvelopeBeforeDecode() throws {
    let json = graphEnvelope()

    #expect(throws: WholeVaultGraphValidationError.payloadTooLarge) {
        _ = try EngineGraphClient.decodeEnvelope(json, byteCapBytes: json.utf8.count - 1)
    }
}

@Test
func wholeVaultGraphPrivacyStringsDoNotExposeLabelsTagsOrMessages() throws {
    let payload = try EngineGraphClient.decodeEnvelope(
        graphEnvelope(label: "SecretProject", tags: ["client@example.com"])
    )
    let telemetry = WholeVaultGraphTelemetry.fields(for: payload)
        .values
        .joined(separator: " ")
    let cacheKey = WholeVaultGraphCacheKey.make(
        vaultIdentityHash: "vault-hash",
        request: WholeVaultGraphRequest(requestID: 7, generation: 3)
    ).description
    let error = EngineGraphClientError.engine(
        EngineGraphErrorPayload(
            code: "graph_index_error",
            message: "/Users/example/SecretProject client@example.com"
        )
    ).description

    for safeString in [telemetry, cacheKey, error] {
        #expect(!safeString.contains("SecretProject"))
        #expect(!safeString.contains("client@example.com"))
        #expect(!safeString.contains("/Users/example"))
    }
}

private func graphEnvelope(
    state: String = "complete",
    partialReasons: [String] = [],
    nodeCountTotal: Int = 2,
    edgeCountTotal: Int = 1,
    nodeIDOverride: String? = nil,
    nodeKind: String = "Resolved",
    edgeWeight: Int = 1,
    label: String = "Home",
    tags: [String] = []
) -> String {
    let firstNodeID = nodeIDOverride ?? "file:1"
    let partialReasonJSON = partialReasons.map { #""\#($0)""# }.joined(separator: ",")
    let tagJSON = tags.map { #""\#($0)""# }.joined(separator: ",")
    return """
    {"ok":true,"value":{"payload_version":1,"request_id":7,"generation":3,"state":"\(state)","metrics":{"snapshot_duration_milliseconds":1.25,"encoded_payload_bytes":512},"snapshot":{"request_id":7,"generation":3,"partial_reasons":[\(partialReasonJSON)],"node_count_total":\(nodeCountTotal),"edge_count_total":\(edgeCountTotal),"nodes":[{"node_id":"\(firstNodeID)","file_id":"home","relative_path":"Folder/Home.md","label":"\(label)","kind":"\(nodeKind)","degree":1,"tags":[\(tagJSON)]},{"node_id":"file:2","file_id":"target","relative_path":"Folder/Target.md","label":"Target","kind":"Resolved","degree":1,"tags":[]}],"edges":[{"source_node_id":"file:1","target_node_id":"file:2","kind":"Resolved","weight":\(edgeWeight)}]}},"error":null}
    """
}
