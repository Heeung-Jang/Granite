import Foundation

public struct GraphPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct GraphRendererSnapshot: Equatable, Sendable {
    public let requestID: UInt64
    public let generation: UInt64
    public let nodes: [GraphLayoutNode]
    public let edges: [GraphLayoutEdge]
    public let components: [GraphLayoutComponent]
    public let renderIdentity: UInt64

    public init(
        requestID: UInt64,
        generation: UInt64,
        nodes: [GraphLayoutNode],
        edges: [GraphLayoutEdge],
        components: [GraphLayoutComponent],
        renderIdentity: UInt64? = nil
    ) {
        self.requestID = requestID
        self.generation = generation
        self.nodes = nodes
        self.edges = edges
        self.components = components
        self.renderIdentity = renderIdentity ?? Self.makeRenderIdentity(
            requestID: requestID,
            generation: generation,
            nodes: nodes,
            edges: edges
        )
    }

    private static func makeRenderIdentity(
        requestID: UInt64,
        generation: UInt64,
        nodes: [GraphLayoutNode],
        edges: [GraphLayoutEdge]
    ) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325

        func mix(_ value: UInt64) {
            hash ^= value
            hash &*= 0x100000001b3
        }

        mix(requestID)
        mix(generation)
        mix(UInt64(nodes.count))
        mix(UInt64(edges.count))

        for node in nodes {
            mix(UInt64(bitPattern: Int64(node.index)))
            mix(stableHash(node.nodeID))
            mix(UInt64(bitPattern: Int64(node.degree)))
            mix(node.position.x.bitPattern)
            mix(node.position.y.bitPattern)
            mix(node.radius.bitPattern)
            mix(stableHash(node.kind.rawValue))
        }

        for edge in edges {
            mix(UInt64(bitPattern: Int64(edge.sourceIndex)))
            mix(UInt64(bitPattern: Int64(edge.targetIndex)))
            mix(UInt64(bitPattern: Int64(edge.weight)))
            mix(stableHash(edge.kind.rawValue))
        }

        return hash
    }

    private static func stableHash(_ value: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }
}

public struct GraphLayoutNode: Equatable, Sendable {
    public let index: Int
    public let nodeID: String
    public let fileID: String?
    public let relativePath: String?
    public let label: String
    public let kind: WholeVaultGraphNodeKind
    public let degree: Int
    public let tags: [String]
    public let position: GraphPoint
    public let radius: Double

    public init(
        index: Int,
        nodeID: String,
        fileID: String? = nil,
        relativePath: String? = nil,
        label: String,
        kind: WholeVaultGraphNodeKind,
        degree: Int,
        tags: [String] = [],
        position: GraphPoint,
        radius: Double
    ) {
        self.index = index
        self.nodeID = nodeID
        self.fileID = fileID
        self.relativePath = relativePath
        self.label = label
        self.kind = kind
        self.degree = degree
        self.tags = tags
        self.position = position
        self.radius = radius
    }
}

public struct GraphLayoutEdge: Equatable, Sendable {
    public let sourceIndex: Int
    public let targetIndex: Int
    public let kind: WholeVaultGraphEdgeKind
    public let weight: Int

    public init(
        sourceIndex: Int,
        targetIndex: Int,
        kind: WholeVaultGraphEdgeKind,
        weight: Int
    ) {
        self.sourceIndex = sourceIndex
        self.targetIndex = targetIndex
        self.kind = kind
        self.weight = weight
    }
}

public struct GraphLayoutComponent: Equatable, Sendable {
    public let nodeIndexes: [Int]
    public let isOrphanRing: Bool

    public init(nodeIndexes: [Int], isOrphanRing: Bool) {
        self.nodeIndexes = nodeIndexes
        self.isOrphanRing = isOrphanRing
    }
}

public struct GraphLayoutBounds: Equatable, Sendable {
    public let minX: Double
    public let minY: Double
    public let maxX: Double
    public let maxY: Double

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
    public var center: GraphPoint {
        GraphPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
    }

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    public static func enclosing(_ nodes: [GraphLayoutNode]) -> GraphLayoutBounds? {
        guard let first = nodes.first else {
            return nil
        }

        var minX = first.position.x - first.radius
        var minY = first.position.y - first.radius
        var maxX = first.position.x + first.radius
        var maxY = first.position.y + first.radius

        for node in nodes.dropFirst() {
            minX = min(minX, node.position.x - node.radius)
            minY = min(minY, node.position.y - node.radius)
            maxX = max(maxX, node.position.x + node.radius)
            maxY = max(maxY, node.position.y + node.radius)
        }

        return GraphLayoutBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }
}

public enum GraphLayoutMapper {
    public static func map(_ snapshot: WholeVaultGraphSnapshot) -> GraphRendererSnapshot {
        try! map(snapshot, checkCancellation: {})
    }

    public static func map(
        _ snapshot: WholeVaultGraphSnapshot,
        checkCancellation: () throws -> Void
    ) throws -> GraphRendererSnapshot {
        var nodeIndexByID: [String: Int] = [:]
        nodeIndexByID.reserveCapacity(snapshot.nodes.count)
        for (index, node) in snapshot.nodes.enumerated() {
            if index.isMultiple(of: 2_048) {
                try checkCancellation()
            }
            nodeIndexByID[node.nodeID] = index
        }

        var edges: [GraphLayoutEdge] = []
        edges.reserveCapacity(snapshot.edges.count)
        for (index, edge) in snapshot.edges.enumerated() {
            if index.isMultiple(of: 2_048) {
                try checkCancellation()
            }
            guard let sourceIndex = nodeIndexByID[edge.sourceNodeID],
                  let targetIndex = nodeIndexByID[edge.targetNodeID]
            else {
                continue
            }
            edges.append(GraphLayoutEdge(
                sourceIndex: sourceIndex,
                targetIndex: targetIndex,
                kind: edge.kind,
                weight: edge.weight
            ))
        }
        let components = try connectedComponents(
            nodeCount: snapshot.nodes.count,
            edges: edges,
            checkCancellation: checkCancellation
        )
        let componentIndexByNode = try componentIndexesByNode(
            components,
            checkCancellation: checkCancellation
        )
        let componentOffsets = componentOffsets(for: components)
        var nodes: [GraphLayoutNode] = []
        nodes.reserveCapacity(snapshot.nodes.count)
        for (index, node) in snapshot.nodes.enumerated() {
            if index.isMultiple(of: 2_048) {
                try checkCancellation()
            }
            let componentIndex = componentIndexByNode[index] ?? 0
            let offset = componentOffsets[componentIndex]
            let seed = seedPosition(nodeID: node.nodeID, degree: node.degree)
            nodes.append(GraphLayoutNode(
                index: index,
                nodeID: node.nodeID,
                fileID: node.fileID,
                relativePath: node.relativePath,
                label: node.label,
                kind: node.kind,
                degree: node.degree,
                tags: node.tags,
                position: GraphPoint(
                    x: seed.x + offset.x,
                    y: seed.y + offset.y
                ),
                radius: radius(forDegree: node.degree)
            ))
        }
        return GraphRendererSnapshot(
            requestID: snapshot.requestID,
            generation: snapshot.generation,
            nodes: nodes,
            edges: edges,
            components: components
        )
    }

    private static func seedPosition(nodeID: String, degree: Int) -> GraphPoint {
        let hash = stableHash(nodeID)
        let angle = Double(hash % 10_000) / 10_000.0 * 2.0 * Double.pi
        let radius = 80.0 + Double(max(0, 24 - min(degree, 24))) * 8.0
        return GraphPoint(x: cos(angle) * radius, y: sin(angle) * radius)
    }

    private static func radius(forDegree degree: Int) -> Double {
        GraphVisualMetrics.nodeRadius(forDegree: degree)
    }

    private static func componentIndexesByNode(
        _ components: [GraphLayoutComponent],
        checkCancellation: () throws -> Void
    ) throws -> [Int: Int] {
        var indexes: [Int: Int] = [:]
        for (componentIndex, component) in components.enumerated() {
            for (offset, nodeIndex) in component.nodeIndexes.enumerated() {
                if offset.isMultiple(of: 2_048) {
                    try checkCancellation()
                }
                indexes[nodeIndex] = componentIndex
            }
        }
        return indexes
    }

    private static func componentOffsets(
        for components: [GraphLayoutComponent]
    ) -> [GraphPoint] {
        let orphanIndexes = components.indices.filter { components[$0].isOrphanRing }
        let nonOrphanIndexes = components.indices.filter { !components[$0].isOrphanRing }
        let columns = max(1, Int(Double(nonOrphanIndexes.count).squareRoot().rounded(.up)))
        var offsets = Array(repeating: GraphPoint(x: 0, y: 0), count: components.count)

        for (ordinal, componentIndex) in orphanIndexes.enumerated() {
            let angle = Double(ordinal) / Double(max(1, orphanIndexes.count)) * 2.0 * Double.pi
            offsets[componentIndex] = GraphPoint(x: cos(angle) * 900.0, y: sin(angle) * 900.0)
        }

        for (ordinal, componentIndex) in nonOrphanIndexes.enumerated() {
            let column = ordinal % columns
            let row = ordinal / columns
            offsets[componentIndex] = GraphPoint(x: Double(column) * 900.0, y: Double(row) * 620.0)
        }

        return offsets
    }

    private static func connectedComponents(
        nodeCount: Int,
        edges: [GraphLayoutEdge],
        checkCancellation: () throws -> Void
    ) throws -> [GraphLayoutComponent] {
        var adjacency = Array(repeating: Set<Int>(), count: nodeCount)
        for (index, edge) in edges.enumerated() {
            if index.isMultiple(of: 2_048) {
                try checkCancellation()
            }
            adjacency[edge.sourceIndex].insert(edge.targetIndex)
            adjacency[edge.targetIndex].insert(edge.sourceIndex)
        }

        var visited = Set<Int>()
        var components: [GraphLayoutComponent] = []
        for index in 0..<nodeCount where !visited.contains(index) {
            if index.isMultiple(of: 2_048) {
                try checkCancellation()
            }
            var stack = [index]
            var component: [Int] = []
            visited.insert(index)
            var visitedInComponent = 0
            while let current = stack.popLast() {
                if visitedInComponent.isMultiple(of: 2_048) {
                    try checkCancellation()
                }
                visitedInComponent += 1
                component.append(current)
                for neighbor in adjacency[current] where !visited.contains(neighbor) {
                    visited.insert(neighbor)
                    stack.append(neighbor)
                }
            }
            component.sort()
            components.append(GraphLayoutComponent(
                nodeIndexes: component,
                isOrphanRing: component.count == 1 && adjacency[component[0]].isEmpty
            ))
        }
        return components.sorted { lhs, rhs in
            (lhs.nodeIndexes.first ?? 0) < (rhs.nodeIndexes.first ?? 0)
        }
    }

    private static func stableHash(_ value: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }
}

public struct GraphViewport: Equatable, Sendable {
    public var panOffset: GraphPoint
    public var zoomScale: Double {
        didSet {
            zoomScale = Self.sanitizedZoomScale(zoomScale)
        }
    }

    public init(
        panOffset: GraphPoint = GraphPoint(x: 0, y: 0),
        zoomScale: Double = 1
    ) {
        self.panOffset = panOffset
        self.zoomScale = Self.sanitizedZoomScale(zoomScale)
    }

    public mutating func reset() {
        panOffset = GraphPoint(x: 0, y: 0)
        zoomScale = 1
    }

    public static func fit(
        layoutBounds: GraphLayoutBounds?,
        canvasSize: GraphSize,
        padding: Double = GraphVisualMetrics.fitPadding,
        maximumZoomScale: Double = GraphVisualMetrics.maximumFitZoomScale
    ) -> GraphViewport {
        guard let layoutBounds,
              canvasSize.width.isFinite,
              canvasSize.height.isFinite,
              canvasSize.width > 0,
              canvasSize.height > 0
        else {
            return GraphViewport()
        }

        let availableWidth = max(1, canvasSize.width - padding * 2)
        let availableHeight = max(1, canvasSize.height - padding * 2)
        let fitWidth = max(1, layoutBounds.width)
        let fitHeight = max(1, layoutBounds.height)
        let zoomScale = max(GraphVisualMetrics.minimumZoomScale, min(
            maximumZoomScale,
            availableWidth / fitWidth,
            availableHeight / fitHeight
        ))
        let center = layoutBounds.center
        return GraphViewport(
            panOffset: GraphPoint(
                x: -center.x * zoomScale,
                y: -center.y * zoomScale
            ),
            zoomScale: zoomScale
        )
    }

    public func screenPoint(for graphPoint: GraphPoint) -> GraphPoint {
        GraphPoint(
            x: graphPoint.x * zoomScale + panOffset.x,
            y: graphPoint.y * zoomScale + panOffset.y
        )
    }

    public func graphPoint(for screenPoint: GraphPoint) -> GraphPoint {
        GraphPoint(
            x: (screenPoint.x - panOffset.x) / zoomScale,
            y: (screenPoint.y - panOffset.y) / zoomScale
        )
    }

    private static func sanitizedZoomScale(_ value: Double) -> Double {
        guard value.isFinite else {
            return 1
        }
        return max(GraphVisualMetrics.minimumZoomScale, value)
    }
}

public struct GraphLabelVisibilityContext: Equatable, Sendable {
    public var hoveredNodeID: String?
    public var selectedNodeID: String?
    public var searchMatchedNodeIDs: Set<String>
    public var zoomScale: Double

    public init(
        hoveredNodeID: String? = nil,
        selectedNodeID: String? = nil,
        searchMatchedNodeIDs: Set<String> = [],
        zoomScale: Double = 1
    ) {
        self.hoveredNodeID = hoveredNodeID
        self.selectedNodeID = selectedNodeID
        self.searchMatchedNodeIDs = searchMatchedNodeIDs
        self.zoomScale = zoomScale
    }
}

public enum GraphLabelVisibilityPolicy {
    public static func isVisible(
        nodeID: String,
        settings: GraphPresentationSettings,
        context: GraphLabelVisibilityContext
    ) -> Bool {
        switch settings.labelVisibility {
        case .always:
            return true
        case .hidden:
            return context.hoveredNodeID == nodeID || context.selectedNodeID == nodeID
        case .automatic:
            return context.hoveredNodeID == nodeID
                || context.selectedNodeID == nodeID
                || context.searchMatchedNodeIDs.contains(nodeID)
                || context.zoomScale >= 1.6
        }
    }
}

public struct GraphLayoutRequestGate: Equatable, Sendable {
    private var activeRequestID: UInt64?
    private var activeGeneration: UInt64?
    private var cancelledRequestIDs: Set<UInt64> = []

    public init() {}

    public mutating func start(requestID: UInt64, generation: UInt64) {
        activeRequestID = requestID
        activeGeneration = generation
        cancelledRequestIDs.remove(requestID)
    }

    public mutating func cancel(requestID: UInt64) {
        cancelledRequestIDs.insert(requestID)
    }

    public func accepts(_ snapshot: GraphRendererSnapshot) -> Bool {
        snapshot.requestID == activeRequestID
            && snapshot.generation == activeGeneration
            && !cancelledRequestIDs.contains(snapshot.requestID)
    }
}

public struct GraphLayoutCacheKey: Equatable, Sendable, CustomStringConvertible {
    public let value: String

    public var description: String { value }

    public static func make(
        vaultIdentityHash: String,
        generation: UInt64,
        settings: GraphSettings,
        layoutAlgorithmVersion: String = "layout-v1"
    ) -> Self {
        let payload = [
            "vault:\(vaultIdentityHash)",
            "generation:\(generation)",
            "algorithm:\(stableHash(layoutAlgorithmVersion))",
            "settings:\(GraphSettingsPrivacyKey.make(settings: settings).value)"
        ].joined(separator: "|")
        return Self(value: "graph-layout-\(stableHash(payload))")
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

public protocol GraphLayoutCacheWriting {
    mutating func writeLayout(_ layout: GraphRendererSnapshot, key: GraphLayoutCacheKey)
}

public struct GraphLayoutCacheController: Equatable, Sendable {
    public let isEnabled: Bool

    public init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }

    public func writeIfEnabled<Writer: GraphLayoutCacheWriting>(
        _ layout: GraphRendererSnapshot,
        key: GraphLayoutCacheKey,
        writer: inout Writer
    ) {
        guard isEnabled else {
            return
        }
        writer.writeLayout(layout, key: key)
    }
}
