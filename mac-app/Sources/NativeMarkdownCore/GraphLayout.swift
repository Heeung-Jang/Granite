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

    public func contains(_ point: GraphPoint) -> Bool {
        point.x >= minX
            && point.x <= maxX
            && point.y >= minY
            && point.y <= maxY
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
            let componentNodeCount = components[componentIndex].nodeIndexes.count
            let offset = componentOffsets[componentIndex]
            let seed = seedPosition(
                nodeID: node.nodeID,
                degree: node.degree,
                componentNodeCount: componentNodeCount
            )
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

    private static func seedPosition(
        nodeID: String,
        degree: Int,
        componentNodeCount: Int
    ) -> GraphPoint {
        let hash = stableHash(nodeID)
        let angle = Double(hash % 10_000) / 10_000.0 * 2.0 * Double.pi
        if componentNodeCount >= 128 {
            let radialHash = stableHash("\(nodeID)#radius")
            let radialUnit = Double(radialHash % 10_000) / 10_000.0
            let radius = 72.0 + radialUnit.squareRoot() * connectedComponentCloudRadius(
                nodeCount: componentNodeCount
            )
            return GraphPoint(x: cos(angle) * radius, y: sin(angle) * radius)
        }

        let radius = 80.0 + Double(max(0, 24 - min(degree, 24))) * 8.0
        return GraphPoint(x: cos(angle) * radius, y: sin(angle) * radius)
    }

    private static func connectedComponentCloudRadius(nodeCount: Int) -> Double {
        Double(max(0, nodeCount)).squareRoot() * 6.0
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
            offsets[componentIndex] = orphanCloudOffset(ordinal: ordinal)
        }

        for (ordinal, componentIndex) in nonOrphanIndexes.enumerated() {
            let column = ordinal % columns
            let row = ordinal / columns
            offsets[componentIndex] = GraphPoint(x: Double(column) * 900.0, y: Double(row) * 620.0)
        }

        return offsets
    }

    private static func orphanCloudOffset(ordinal: Int) -> GraphPoint {
        let goldenAngle = Double.pi * (3.0 - 5.0.squareRoot())
        let angle = Double(ordinal) * goldenAngle
        let radius = 900.0
            + Double(ordinal + 1).squareRoot() * 44.0
            + Double((ordinal * 37) % 29)
        return GraphPoint(x: cos(angle) * radius, y: sin(angle) * radius)
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

    public static func centeredScreenPoint(
        forLocalPoint localPoint: GraphPoint,
        canvasSize: GraphSize
    ) -> GraphPoint? {
        guard localPoint.x.isFinite,
              localPoint.y.isFinite,
              canvasSize.width.isFinite,
              canvasSize.height.isFinite,
              canvasSize.width > 0,
              canvasSize.height > 0
        else {
            return nil
        }
        return GraphPoint(
            x: localPoint.x - canvasSize.width / 2,
            y: localPoint.y - canvasSize.height / 2
        )
    }

    public mutating func zoom(by multiplier: Double, around centeredAnchor: GraphPoint) {
        self = zoomed(by: multiplier, around: centeredAnchor)
    }

    public func zoomed(by multiplier: Double, around centeredAnchor: GraphPoint) -> GraphViewport {
        guard multiplier.isFinite,
              multiplier > 0,
              centeredAnchor.x.isFinite,
              centeredAnchor.y.isFinite
        else {
            return self
        }
        let graphAnchor = graphPoint(for: centeredAnchor)
        let newZoomScale = Self.sanitizedZoomScale(zoomScale * multiplier)
        return GraphViewport(
            panOffset: GraphPoint(
                x: centeredAnchor.x - graphAnchor.x * newZoomScale,
                y: centeredAnchor.y - graphAnchor.y * newZoomScale
            ),
            zoomScale: newZoomScale
        )
    }

    public func visibleGraphBounds(
        canvasSize: GraphSize,
        padding: Double = 0
    ) -> GraphLayoutBounds? {
        guard canvasSize.width.isFinite,
              canvasSize.height.isFinite,
              canvasSize.width > 0,
              canvasSize.height > 0,
              padding.isFinite
        else {
            return nil
        }
        let safePadding = max(0, padding)
        let topLeft = graphPoint(for: GraphPoint(
            x: -canvasSize.width / 2 - safePadding,
            y: -canvasSize.height / 2 - safePadding
        ))
        let bottomRight = graphPoint(for: GraphPoint(
            x: canvasSize.width / 2 + safePadding,
            y: canvasSize.height / 2 + safePadding
        ))
        return GraphLayoutBounds(
            minX: min(topLeft.x, bottomRight.x),
            minY: min(topLeft.y, bottomRight.y),
            maxX: max(topLeft.x, bottomRight.x),
            maxY: max(topLeft.y, bottomRight.y)
        )
    }

    private static func sanitizedZoomScale(_ value: Double) -> Double {
        guard value.isFinite else {
            return 1
        }
        return min(
            GraphVisualMetrics.maximumZoomScale,
            max(GraphVisualMetrics.minimumZoomScale, value)
        )
    }
}

public struct GraphViewportFitState: Equatable, Sendable {
    static let minimumUsableCanvasSide = 32.0

    private var fittedRequestID: UInt64?
    private(set) var cachedLayoutIdentity: UInt64?
    private var cachedLayoutBounds: GraphLayoutBounds?

    public init(
        fittedRequestID: UInt64? = nil,
        cachedLayoutIdentity: UInt64? = nil,
        cachedLayoutBounds: GraphLayoutBounds? = nil
    ) {
        self.fittedRequestID = fittedRequestID
        self.cachedLayoutIdentity = cachedLayoutIdentity
        self.cachedLayoutBounds = cachedLayoutBounds
    }

    public mutating func invalidate() {
        fittedRequestID = nil
        cachedLayoutIdentity = nil
        cachedLayoutBounds = nil
    }

    public mutating func initialFitViewport(
        layout: GraphRendererSnapshot,
        canvasSize: GraphSize
    ) -> GraphViewport? {
        guard fittedRequestID != layout.requestID,
              Self.hasUsableCanvas(canvasSize)
        else {
            return nil
        }

        fittedRequestID = layout.requestID
        return fitViewport(layout: layout, canvasSize: canvasSize)
    }

    public mutating func resetViewport(
        layout: GraphRendererSnapshot,
        canvasSize: GraphSize
    ) -> GraphViewport {
        fittedRequestID = layout.requestID
        return fitViewport(layout: layout, canvasSize: canvasSize)
    }

    private mutating func fitViewport(
        layout: GraphRendererSnapshot,
        canvasSize: GraphSize
    ) -> GraphViewport {
        GraphViewport.fit(
            layoutBounds: layoutBounds(for: layout),
            canvasSize: canvasSize
        )
    }

    private mutating func layoutBounds(for layout: GraphRendererSnapshot) -> GraphLayoutBounds? {
        guard cachedLayoutIdentity != layout.renderIdentity else {
            return cachedLayoutBounds
        }

        let bounds = GraphLayoutBounds.enclosing(layout.nodes)
        cachedLayoutIdentity = layout.renderIdentity
        cachedLayoutBounds = bounds
        return bounds
    }

    private static func hasUsableCanvas(_ canvasSize: GraphSize) -> Bool {
        canvasSize.width.isFinite
            && canvasSize.height.isFinite
            && canvasSize.width >= minimumUsableCanvasSide
            && canvasSize.height >= minimumUsableCanvasSide
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
        layoutAlgorithmVersion: String = "layout-v2"
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
