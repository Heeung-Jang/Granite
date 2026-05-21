import Darwin
import Foundation

public struct WholeVaultGraphDecodeBenchmarkResult: Equatable {
    public let nodeCount: Int
    public let edgeCount: Int
    public let encodedPayloadBytes: Int
    public let decodeDurationMilliseconds: Double
    public let memoryDeltaBytes: Int?
}

public enum WholeVaultGraphDecodeBenchmark {
    static let defaultByteCapBytes = 128 * 1024 * 1024

    public static func syntheticPayload(nodeCount: Int = 64_000, edgeCount: Int = 128_000) throws -> Data {
        let nodes = (0..<nodeCount).map { index in
            BenchmarkNode(
                nodeId: "file:\(String(format: "%016x", index))",
                fileId: "file-\(index)",
                label: "node-\(index)",
                kind: "Resolved",
                degree: 0,
                tags: []
            )
        }
        let edges = (0..<edgeCount).map { index in
            BenchmarkEdge(
                sourceNodeId: nodes[index % nodeCount].nodeId,
                targetNodeId: nodes[(index + 1) % nodeCount].nodeId,
                kind: "Resolved",
                weight: 1
            )
        }
        let envelope = BenchmarkEnvelope(
            payloadVersion: 1,
            snapshot: BenchmarkSnapshot(
                requestId: 1,
                generation: 1,
                partialReasons: [],
                nodeCountTotal: nodeCount,
                edgeCountTotal: edgeCount,
                nodes: nodes,
                edges: edges
            )
        )
        return try JSONEncoder().encode(envelope)
    }

    public static func run(payload: Data) throws -> WholeVaultGraphDecodeBenchmarkResult {
        try run(payload: payload, byteCapBytes: defaultByteCapBytes)
    }

    static func run(payload: Data, byteCapBytes: Int) throws -> WholeVaultGraphDecodeBenchmarkResult {
        guard payload.count <= byteCapBytes else {
            throw BenchmarkDecodeError.invalidPayload
        }

        let memoryBefore = residentMemoryBytes()
        let start = DispatchTime.now().uptimeNanoseconds
        let envelope = try JSONDecoder().decode(BenchmarkEnvelope.self, from: payload)
        var nodeIds = Set<String>()
        var hasValidNodes = true
        for node in envelope.snapshot.nodes {
            hasValidNodes = hasValidNodes
                && nodeIds.insert(node.nodeId).inserted
                && BenchmarkNodeKind(rawValue: node.kind) != nil
        }
        let hasValidPartialReasons = envelope.snapshot.partialReasons.allSatisfy { reason in
            BenchmarkPartialReason(rawValue: reason) != nil
        }
        let hasMaxNodesReason = envelope.snapshot.partialReasons.contains(
            BenchmarkPartialReason.maxNodes.rawValue
        )
        let hasMaxEdgesReason = envelope.snapshot.partialReasons.contains(
            BenchmarkPartialReason.maxEdges.rawValue
        )
        let hasValidNodeCount = envelope.snapshot.nodeCountTotal == envelope.snapshot.nodes.count
            || (hasMaxNodesReason && envelope.snapshot.nodeCountTotal >= envelope.snapshot.nodes.count)
        let hasValidEdgeCount = envelope.snapshot.edgeCountTotal == envelope.snapshot.edges.count
            || (hasMaxEdgesReason && envelope.snapshot.edgeCountTotal >= envelope.snapshot.edges.count)
        let validEdgeCount = envelope.snapshot.edges.reduce(into: 0) { count, edge in
            if nodeIds.contains(edge.sourceNodeId),
               nodeIds.contains(edge.targetNodeId),
               BenchmarkEdgeKind(rawValue: edge.kind) != nil,
               edge.weight > 0 {
                count += 1
            }
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        let memoryAfter = residentMemoryBytes()
        let memoryDelta = memoryBefore.flatMap { before in
            memoryAfter.map { max(0, $0 - before) }
        }

        guard envelope.payloadVersion == 1,
              hasValidNodes,
              hasValidPartialReasons,
              hasValidNodeCount,
              hasValidEdgeCount,
              validEdgeCount == envelope.snapshot.edges.count
        else {
            throw BenchmarkDecodeError.invalidPayload
        }

        return WholeVaultGraphDecodeBenchmarkResult(
            nodeCount: envelope.snapshot.nodes.count,
            edgeCount: envelope.snapshot.edges.count,
            encodedPayloadBytes: payload.count,
            decodeDurationMilliseconds: Double(elapsed) / 1_000_000,
            memoryDeltaBytes: memoryDelta
        )
    }

    private static func residentMemoryBytes() -> Int? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<natural_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return nil
        }
        return Int(info.resident_size)
    }
}

private enum BenchmarkDecodeError: Error {
    case invalidPayload
}

private enum BenchmarkNodeKind: String {
    case resolved = "Resolved"
    case unresolved = "Unresolved"
}

private enum BenchmarkEdgeKind: String {
    case resolved = "Resolved"
    case unresolved = "Unresolved"
}

private enum BenchmarkPartialReason: String {
    case maxNodes = "MaxNodes"
    case maxEdges = "MaxEdges"
    case maxLabelBytes = "MaxLabelBytes"
    case maxTagsPerNode = "MaxTagsPerNode"
    case maxGroups = "MaxGroups"
    case maxRuleLength = "MaxRuleLength"
}

private struct BenchmarkEnvelope: Codable {
    let payloadVersion: Int
    let snapshot: BenchmarkSnapshot
}

private struct BenchmarkSnapshot: Codable {
    let requestId: UInt64
    let generation: UInt64
    let partialReasons: [String]
    let nodeCountTotal: Int
    let edgeCountTotal: Int
    let nodes: [BenchmarkNode]
    let edges: [BenchmarkEdge]

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case generation
        case partialReasons = "partial_reasons"
        case nodeCountTotal = "node_count_total"
        case edgeCountTotal = "edge_count_total"
        case nodes
        case edges
    }
}

private struct BenchmarkNode: Codable {
    let nodeId: String
    let fileId: String?
    let label: String
    let kind: String
    let degree: Int
    let tags: [String]

    enum CodingKeys: String, CodingKey {
        case nodeId = "node_id"
        case fileId = "file_id"
        case label
        case kind
        case degree
        case tags
    }
}

private struct BenchmarkEdge: Codable {
    let sourceNodeId: String
    let targetNodeId: String
    let kind: String
    let weight: Int

    enum CodingKeys: String, CodingKey {
        case sourceNodeId = "source_node_id"
        case targetNodeId = "target_node_id"
        case kind
        case weight
    }
}
