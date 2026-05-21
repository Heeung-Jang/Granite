import Foundation

public struct WholeVaultGraphRequest: Codable, Equatable, Sendable {
    public static let payloadVersion: UInt32 = 1
    public static let currentGeneration: UInt64 = 0
    public static let defaultByteCapBytes = 128 * 1024 * 1024

    public let payloadVersion: UInt32
    public let requestID: UInt64
    public let generation: UInt64
    public let includeUnresolved: Bool
    public let includeOrphans: Bool
    public let maxNodes: Int
    public let maxEdges: Int
    public let byteCapBytes: Int

    public init(
        requestID: UInt64,
        generation: UInt64 = Self.currentGeneration,
        includeUnresolved: Bool = false,
        includeOrphans: Bool = false,
        maxNodes: Int = 100_000,
        maxEdges: Int = 250_000,
        byteCapBytes: Int = Self.defaultByteCapBytes
    ) {
        payloadVersion = Self.payloadVersion
        self.requestID = requestID
        self.generation = generation
        self.includeUnresolved = includeUnresolved
        self.includeOrphans = includeOrphans
        self.maxNodes = maxNodes
        self.maxEdges = maxEdges
        self.byteCapBytes = byteCapBytes
    }

    public var expectedGeneration: UInt64? {
        generation == Self.currentGeneration ? nil : generation
    }

    enum CodingKeys: String, CodingKey {
        case payloadVersion = "payload_version"
        case requestID = "request_id"
        case generation
        case includeUnresolved = "include_unresolved"
        case includeOrphans = "include_orphans"
        case maxNodes = "max_nodes"
        case maxEdges = "max_edges"
        case byteCapBytes = "byte_cap_bytes"
    }
}

public struct WholeVaultGraphPayload: Codable, Equatable, Sendable {
    public let payloadVersion: UInt32
    public let requestID: UInt64
    public let generation: UInt64
    public let state: WholeVaultGraphState
    public let metrics: WholeVaultGraphMetrics
    public let snapshot: WholeVaultGraphSnapshot

    enum CodingKeys: String, CodingKey {
        case payloadVersion = "payload_version"
        case requestID = "request_id"
        case generation
        case state
        case metrics
        case snapshot
    }
}

public enum WholeVaultGraphState: String, Codable, Equatable, Sendable {
    case complete
    case partial

    public var telemetryState: SearchResultState {
        switch self {
        case .complete:
            return .complete
        case .partial:
            return .partial
        }
    }
}

public struct WholeVaultGraphMetrics: Codable, Equatable, Sendable {
    public let snapshotDurationMilliseconds: Double
    public let encodedPayloadBytes: Int

    enum CodingKeys: String, CodingKey {
        case snapshotDurationMilliseconds = "snapshot_duration_milliseconds"
        case encodedPayloadBytes = "encoded_payload_bytes"
    }
}

public struct WholeVaultGraphSnapshot: Codable, Equatable, Sendable {
    public let requestID: UInt64
    public let generation: UInt64
    public let partialReasons: [WholeVaultGraphPartialReason]
    public let nodeCountTotal: Int
    public let edgeCountTotal: Int
    public let nodes: [WholeVaultGraphNode]
    public let edges: [WholeVaultGraphEdge]

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case generation
        case partialReasons = "partial_reasons"
        case nodeCountTotal = "node_count_total"
        case edgeCountTotal = "edge_count_total"
        case nodes
        case edges
    }
}

public struct WholeVaultGraphNode: Codable, Equatable, Sendable {
    public let nodeID: String
    public let fileID: String?
    public let relativePath: String?
    public let label: String
    public let kind: WholeVaultGraphNodeKind
    public let degree: Int
    public let tags: [String]

    enum CodingKeys: String, CodingKey {
        case nodeID = "node_id"
        case fileID = "file_id"
        case relativePath = "relative_path"
        case label
        case kind
        case degree
        case tags
    }
}

public enum WholeVaultGraphNodeKind: String, Codable, Equatable, Sendable {
    case resolved = "Resolved"
    case unresolved = "Unresolved"
}

public struct WholeVaultGraphEdge: Codable, Equatable, Sendable {
    public let sourceNodeID: String
    public let targetNodeID: String
    public let kind: WholeVaultGraphEdgeKind
    public let weight: Int

    enum CodingKeys: String, CodingKey {
        case sourceNodeID = "source_node_id"
        case targetNodeID = "target_node_id"
        case kind
        case weight
    }
}

public enum WholeVaultGraphEdgeKind: String, Codable, Equatable, Sendable {
    case resolved = "Resolved"
    case unresolved = "Unresolved"
}

public enum WholeVaultGraphPartialReason: String, Codable, Equatable, Sendable {
    case maxNodes = "MaxNodes"
    case maxEdges = "MaxEdges"
    case maxLabelBytes = "MaxLabelBytes"
    case maxTagsPerNode = "MaxTagsPerNode"
    case maxGroups = "MaxGroups"
    case maxRuleLength = "MaxRuleLength"
}

public enum WholeVaultGraphValidationError: Error, Equatable, Sendable {
    case payloadTooLarge
    case unsupportedPayloadVersion(UInt32)
    case requestMismatch
    case stateMismatch
    case countMismatch
    case duplicateNodeID
    case danglingEdgeEndpoint
    case invalidEdgeWeight
}

public enum WholeVaultGraphPayloadValidator {
    public static func decodeValidated(
        _ data: Data,
        expectedRequestID: UInt64? = nil,
        expectedGeneration: UInt64? = nil,
        byteCapBytes: Int = WholeVaultGraphRequest.defaultByteCapBytes
    ) throws -> WholeVaultGraphPayload {
        guard data.count <= byteCapBytes else {
            throw WholeVaultGraphValidationError.payloadTooLarge
        }

        let payload = try JSONDecoder().decode(WholeVaultGraphPayload.self, from: data)
        try validate(
            payload,
            expectedRequestID: expectedRequestID,
            expectedGeneration: expectedGeneration
        )
        return payload
    }

    public static func validate(
        _ payload: WholeVaultGraphPayload,
        expectedRequestID: UInt64? = nil,
        expectedGeneration: UInt64? = nil
    ) throws {
        guard payload.payloadVersion == WholeVaultGraphRequest.payloadVersion else {
            throw WholeVaultGraphValidationError.unsupportedPayloadVersion(payload.payloadVersion)
        }
        if let expectedRequestID, payload.requestID != expectedRequestID {
            throw WholeVaultGraphValidationError.requestMismatch
        }
        if let expectedGeneration, payload.generation != expectedGeneration {
            throw WholeVaultGraphValidationError.requestMismatch
        }
        guard payload.requestID == payload.snapshot.requestID,
              payload.generation == payload.snapshot.generation
        else {
            throw WholeVaultGraphValidationError.requestMismatch
        }

        switch payload.state {
        case .complete where !payload.snapshot.partialReasons.isEmpty:
            throw WholeVaultGraphValidationError.stateMismatch
        case .partial where payload.snapshot.partialReasons.isEmpty:
            throw WholeVaultGraphValidationError.stateMismatch
        default:
            break
        }

        let hasMaxNodes = payload.snapshot.partialReasons.contains(.maxNodes)
        let hasMaxEdges = payload.snapshot.partialReasons.contains(.maxEdges)
        let nodeCountIsValid = payload.snapshot.nodeCountTotal == payload.snapshot.nodes.count
            || (hasMaxNodes && payload.snapshot.nodeCountTotal >= payload.snapshot.nodes.count)
        let edgeCountIsValid = payload.snapshot.edgeCountTotal == payload.snapshot.edges.count
            || (hasMaxEdges && payload.snapshot.edgeCountTotal >= payload.snapshot.edges.count)
        guard nodeCountIsValid, edgeCountIsValid else {
            throw WholeVaultGraphValidationError.countMismatch
        }

        var nodeIDs = Set<String>()
        for node in payload.snapshot.nodes {
            guard nodeIDs.insert(node.nodeID).inserted else {
                throw WholeVaultGraphValidationError.duplicateNodeID
            }
        }

        for edge in payload.snapshot.edges {
            guard edge.weight > 0 else {
                throw WholeVaultGraphValidationError.invalidEdgeWeight
            }
            guard nodeIDs.contains(edge.sourceNodeID), nodeIDs.contains(edge.targetNodeID) else {
                throw WholeVaultGraphValidationError.danglingEdgeEndpoint
            }
        }
    }
}

public struct WholeVaultGraphCacheKey: Equatable, Sendable, CustomStringConvertible {
    public let value: String

    public var description: String { value }

    public static func make(
        vaultIdentityHash: String,
        request: WholeVaultGraphRequest
    ) -> Self {
        let semanticBits = [
            request.includeUnresolved ? "unresolved" : "resolved",
            request.includeOrphans ? "orphans" : "linked",
            "nodes:\(request.maxNodes)",
            "edges:\(request.maxEdges)"
        ].joined(separator: "|")
        return Self(value: "\(vaultIdentityHash):\(request.generation):\(stableHash(semanticBits))")
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}

public enum WholeVaultGraphTelemetry {
    public static func fields(for payload: WholeVaultGraphPayload) -> [String: String] {
        [
            "requestID": String(payload.requestID),
            "generation": String(payload.generation),
            "state": payload.state.rawValue,
            "nodeCount": String(payload.snapshot.nodeCountTotal),
            "edgeCount": String(payload.snapshot.edgeCountTotal),
            "visibleNodeCount": String(payload.snapshot.nodes.count),
            "visibleEdgeCount": String(payload.snapshot.edges.count)
        ]
    }
}
