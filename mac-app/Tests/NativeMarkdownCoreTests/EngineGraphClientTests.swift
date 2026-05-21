import Foundation
import Testing
@testable import NativeMarkdownCore

@Test
func engineGraphClientDecodesFixtureSnapshot() async throws {
    let client = EngineGraphClient(transport: FakeGraphTransport { _, _ in
        graphClientEnvelope(requestID: 11)
    })
    let payload = try await client.loadSnapshot(
        metadataURL: URL(fileURLWithPath: "/tmp/metadata.sqlite"),
        request: WholeVaultGraphRequest(requestID: 11, generation: 3)
    )

    #expect(payload.requestID == 11)
    #expect(payload.generation == 3)
    #expect(payload.state == .complete)
}

@Test
func engineGraphClientRejectsStaleOlderCompletion() async throws {
    let client = EngineGraphClient(transport: FakeGraphTransport { _, requestJSON in
        let request = try JSONDecoder().decode(
            WholeVaultGraphRequest.self,
            from: Data(requestJSON.utf8)
        )
        if request.requestID == 1 {
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        return graphClientEnvelope(requestID: request.requestID)
    })

    async let first = client.loadSnapshot(
        metadataURL: URL(fileURLWithPath: "/tmp/metadata.sqlite"),
        request: WholeVaultGraphRequest(requestID: 1, generation: 3)
    )
    try await Task.sleep(nanoseconds: 5_000_000)
    let second = try await client.loadSnapshot(
        metadataURL: URL(fileURLWithPath: "/tmp/metadata.sqlite"),
        request: WholeVaultGraphRequest(requestID: 2, generation: 3)
    )

    #expect(second.requestID == 2)
    do {
        _ = try await first
        Issue.record("older graph response should be rejected")
    } catch EngineGraphClientError.staleResponse(let requestID, let latestRequestID) {
        #expect(requestID == 1)
        #expect(latestRequestID == 2)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test
func engineGraphClientCancelledRequestDoesNotAdvanceFreshness() async throws {
    let client = EngineGraphClient(transport: FakeGraphTransport { _, requestJSON in
        let request = try JSONDecoder().decode(
            WholeVaultGraphRequest.self,
            from: Data(requestJSON.utf8)
        )
        if request.requestID == 1 {
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        return graphClientEnvelope(requestID: request.requestID)
    })

    let first = Task {
        try await client.loadSnapshot(
            metadataURL: URL(fileURLWithPath: "/tmp/metadata.sqlite"),
            request: WholeVaultGraphRequest(requestID: 1, generation: 3)
        )
    }
    try await Task.sleep(nanoseconds: 5_000_000)
    let cancelled = Task {
        try await client.loadSnapshot(
            metadataURL: URL(fileURLWithPath: "/tmp/metadata.sqlite"),
            request: WholeVaultGraphRequest(requestID: 2, generation: 3)
        )
    }
    cancelled.cancel()

    do {
        _ = try await cancelled.value
        Issue.record("cancelled graph request should not complete")
    } catch is CancellationError {
        let payload = try await first.value
        #expect(payload.requestID == 1)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test
func engineGraphClientCancellationStopsBeforeDecode() async throws {
    let client = EngineGraphClient(transport: FakeGraphTransport { _, _ in
        try await Task.sleep(nanoseconds: 100_000_000)
        return graphClientEnvelope(requestID: 3)
    })
    let task = Task {
        try await client.loadSnapshot(
            metadataURL: URL(fileURLWithPath: "/tmp/metadata.sqlite"),
            request: WholeVaultGraphRequest(requestID: 3, generation: 3)
        )
    }

    task.cancel()

    do {
        _ = try await task.value
        Issue.record("cancelled graph request should not complete")
    } catch is CancellationError {
        return
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test
func engineGraphClientErrorDescriptionIsPrivacySafe() {
    let error = EngineGraphClientError.engine(
        EngineGraphErrorPayload(
            code: "graph_index_error",
            message: "/Users/example/SecretProject client@example.com"
        )
    )
    let description = error.description

    #expect(description == "graph engine error: graph_index_error")
    #expect(!description.contains("SecretProject"))
    #expect(!description.contains("client@example.com"))
    #expect(!description.contains("/Users/example"))
}

@Test
func engineGraphClientRejectsUnexpectedGeneration() throws {
    #expect(throws: WholeVaultGraphValidationError.requestMismatch) {
        _ = try EngineGraphClient.decodeEnvelope(
            graphClientEnvelope(requestID: 11, generation: 4),
            expectedRequestID: 11,
            expectedGeneration: 3
        )
    }
}

private struct FakeGraphTransport: EngineGraphTransport {
    let handler: @Sendable (String, String) async throws -> String

    func snapshot(metadataPath: String, requestJSON: String) async throws -> String {
        try await handler(metadataPath, requestJSON)
    }
}

private func graphClientEnvelope(requestID: UInt64, generation: UInt64 = 3) -> String {
    """
    {"ok":true,"value":{"payload_version":1,"request_id":\(requestID),"generation":\(generation),"state":"complete","metrics":{"snapshot_duration_milliseconds":1.25,"encoded_payload_bytes":512},"snapshot":{"request_id":\(requestID),"generation":\(generation),"partial_reasons":[],"node_count_total":2,"edge_count_total":1,"nodes":[{"node_id":"file:1","file_id":"home","label":"Home","kind":"Resolved","degree":1,"tags":[]},{"node_id":"file:2","file_id":"target","label":"Target","kind":"Resolved","degree":1,"tags":[]}],"edges":[{"source_node_id":"file:1","target_node_id":"file:2","kind":"Resolved","weight":1}]}},"error":null}
    """
}
