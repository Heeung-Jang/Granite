import Foundation
import Testing
@testable import NativeMarkdownCore

@Test
func wholeVaultGraphDecodeBenchmarkDecodesSynthetic64kPayload() throws {
    let payload = try WholeVaultGraphDecodeBenchmark.syntheticPayload(
        nodeCount: 64_000,
        edgeCount: 128_000
    )
    let result = try WholeVaultGraphDecodeBenchmark.run(payload: payload)

    #expect(result.nodeCount == 64_000)
    #expect(result.edgeCount == 128_000)
    #expect(result.encodedPayloadBytes == payload.count)
    #expect(result.decodeDurationMilliseconds >= 0)
    #expect(result.decodeDurationMilliseconds <= 1_500)
    if let memoryDeltaBytes = result.memoryDeltaBytes {
        #expect(memoryDeltaBytes <= 200 * 1024 * 1024)
    }
}

@Test
func wholeVaultGraphDecodeBenchmarkPayloadIsRedacted() throws {
    let payload = try WholeVaultGraphDecodeBenchmark.syntheticPayload(nodeCount: 10, edgeCount: 20)
    let json = String(decoding: payload, as: UTF8.self)

    #expect(!json.contains("SecretProject"))
    #expect(!json.contains("/Users/"))
    #expect(!json.contains("client@example.com"))
}

@Test
func wholeVaultGraphDecodeBenchmarkAcceptsPartialVisibleSnapshot() throws {
    let payload = Data("""
    {"payloadVersion":1,"snapshot":{"request_id":1,"generation":1,"partial_reasons":["MaxNodes","MaxEdges"],"node_count_total":3,"edge_count_total":2,"nodes":[{"node_id":"file:1","file_id":"a","label":"a","kind":"Resolved","degree":1,"tags":[]},{"node_id":"file:2","file_id":"b","label":"b","kind":"Resolved","degree":1,"tags":[]}],"edges":[{"source_node_id":"file:1","target_node_id":"file:2","kind":"Resolved","weight":1}]}}
    """.utf8)

    let result = try WholeVaultGraphDecodeBenchmark.run(payload: payload)

    #expect(result.nodeCount == 2)
    #expect(result.edgeCount == 1)
}

@Test
func wholeVaultGraphDecodeBenchmarkRejectsTruncatedCompleteSnapshot() throws {
    let payload = Data("""
    {"payloadVersion":1,"snapshot":{"request_id":1,"generation":1,"partial_reasons":[],"node_count_total":2,"edge_count_total":0,"nodes":[{"node_id":"file:1","file_id":"a","label":"a","kind":"Resolved","degree":0,"tags":[]}],"edges":[]}}
    """.utf8)

    #expect(throws: Error.self) {
        _ = try WholeVaultGraphDecodeBenchmark.run(payload: payload)
    }
}

@Test
func wholeVaultGraphDecodeBenchmarkRejectsInflatedCountsForNonCountPartialReason() throws {
    let payload = Data("""
    {"payloadVersion":1,"snapshot":{"request_id":1,"generation":1,"partial_reasons":["MaxLabelBytes"],"node_count_total":2,"edge_count_total":0,"nodes":[{"node_id":"file:1","file_id":"a","label":"a","kind":"Resolved","degree":0,"tags":[]}],"edges":[]}}
    """.utf8)

    #expect(throws: Error.self) {
        _ = try WholeVaultGraphDecodeBenchmark.run(payload: payload)
    }
}

@Test
func wholeVaultGraphDecodeBenchmarkRejectsPayloadOverByteCapBeforeDecode() throws {
    let payload = Data("{}".utf8)

    #expect(throws: Error.self) {
        _ = try WholeVaultGraphDecodeBenchmark.run(payload: payload, byteCapBytes: payload.count - 1)
    }
}

@Test
func wholeVaultGraphDecodeBenchmarkRejectsDuplicateNodes() throws {
    let payload = Data("""
    {"payloadVersion":1,"snapshot":{"request_id":1,"generation":1,"partial_reasons":[],"node_count_total":2,"edge_count_total":0,"nodes":[{"node_id":"file:1","file_id":"a","label":"a","kind":"Resolved","degree":0,"tags":[]},{"node_id":"file:1","file_id":"b","label":"b","kind":"Resolved","degree":0,"tags":[]}],"edges":[]}}
    """.utf8)

    #expect(throws: Error.self) {
        _ = try WholeVaultGraphDecodeBenchmark.run(payload: payload)
    }
}

@Test
func wholeVaultGraphDecodeBenchmarkRejectsInvalidPartialReason() throws {
    let payload = Data("""
    {"payloadVersion":1,"snapshot":{"request_id":1,"generation":1,"partial_reasons":["BadReason"],"node_count_total":1,"edge_count_total":0,"nodes":[{"node_id":"file:1","file_id":"a","label":"a","kind":"Resolved","degree":0,"tags":[]}],"edges":[]}}
    """.utf8)

    #expect(throws: Error.self) {
        _ = try WholeVaultGraphDecodeBenchmark.run(payload: payload)
    }
}

@Test
func wholeVaultGraphDecodeBenchmarkRejectsInvalidKinds() throws {
    let payload = Data("""
    {"payloadVersion":1,"snapshot":{"request_id":1,"generation":1,"partial_reasons":[],"node_count_total":1,"edge_count_total":1,"nodes":[{"node_id":"file:1","file_id":"a","label":"a","kind":"BadKind","degree":0,"tags":[]}],"edges":[{"source_node_id":"file:1","target_node_id":"file:1","kind":"Resolved","weight":1}]}}
    """.utf8)

    #expect(throws: Error.self) {
        _ = try WholeVaultGraphDecodeBenchmark.run(payload: payload)
    }
}
