import Foundation

public struct GraphSize: Equatable, Sendable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct GraphHitTestResult: Equatable, Sendable {
    public let nodeID: String
    public let nodeIndex: Int
    public let distance: Double

    public init(nodeID: String, nodeIndex: Int, distance: Double) {
        self.nodeID = nodeID
        self.nodeIndex = nodeIndex
        self.distance = distance
    }
}

public struct GraphHitTestIndex: Equatable, Sendable {
    public let layout: GraphRendererSnapshot
    public let bucketCellSize: Double
    private let buckets: [GraphGridCell: [Int]]
    private let nodeIndexByID: [String: Int]

    public var bucketCount: Int {
        buckets.count
    }

    public init(layout: GraphRendererSnapshot, bucketCellSize: Double = 96) {
        try! self.init(
            layout: layout,
            bucketCellSize: bucketCellSize,
            checkCancellation: {}
        )
    }

    public init(
        layout: GraphRendererSnapshot,
        bucketCellSize: Double = 96,
        checkCancellation: () throws -> Void
    ) throws {
        self.layout = layout
        self.bucketCellSize = max(24, bucketCellSize)
        var buckets: [GraphGridCell: [Int]] = [:]
        var nodeIndexByID: [String: Int] = [:]
        for (arrayIndex, node) in layout.nodes.enumerated() {
            if arrayIndex.isMultiple(of: 2_048) {
                try checkCancellation()
            }
            nodeIndexByID[node.nodeID] = arrayIndex
            buckets[Self.gridCell(for: node.position, bucketCellSize: self.bucketCellSize), default: []]
                .append(arrayIndex)
        }
        self.buckets = buckets
        self.nodeIndexByID = nodeIndexByID
    }

    private init(
        layout: GraphRendererSnapshot,
        bucketCellSize: Double,
        buckets: [GraphGridCell: [Int]],
        nodeIndexByID: [String: Int]
    ) {
        self.layout = layout
        self.bucketCellSize = bucketCellSize
        self.buckets = buckets
        self.nodeIndexByID = nodeIndexByID
    }

    public func movingNode(nodeID: String, to graphPoint: GraphPoint) -> GraphHitTestIndex {
        guard let nodeIndex = nodeIndexByID[nodeID],
              layout.nodes.indices.contains(nodeIndex)
        else {
            return self
        }

        let oldNode = layout.nodes[nodeIndex]
        guard oldNode.position != graphPoint else {
            return self
        }

        var nodes = layout.nodes
        nodes[nodeIndex] = oldNode.withPosition(graphPoint)
        let movedLayout = GraphRendererSnapshot(
            requestID: layout.requestID,
            generation: layout.generation,
            nodes: nodes,
            edges: layout.edges,
            components: layout.components,
            renderIdentity: Self.movedRenderIdentity(
                base: layout.renderIdentity,
                nodeID: nodeID,
                oldPosition: oldNode.position,
                newPosition: graphPoint
            )
        )

        let oldCell = Self.gridCell(for: oldNode.position, bucketCellSize: bucketCellSize)
        let newCell = Self.gridCell(for: graphPoint, bucketCellSize: bucketCellSize)
        guard oldCell != newCell else {
            return GraphHitTestIndex(
                layout: movedLayout,
                bucketCellSize: bucketCellSize,
                buckets: buckets,
                nodeIndexByID: nodeIndexByID
            )
        }

        var movedBuckets = buckets
        if var oldBucket = movedBuckets[oldCell] {
            oldBucket.removeAll { $0 == nodeIndex }
            if oldBucket.isEmpty {
                movedBuckets.removeValue(forKey: oldCell)
            } else {
                movedBuckets[oldCell] = oldBucket
            }
        }
        movedBuckets[newCell, default: []].append(nodeIndex)
        return GraphHitTestIndex(
            layout: movedLayout,
            bucketCellSize: bucketCellSize,
            buckets: movedBuckets,
            nodeIndexByID: nodeIndexByID
        )
    }

    public func nearestNode(
        at screenPoint: GraphPoint,
        viewport: GraphViewport,
        canvasSize: GraphSize,
        maxDistance: Double = GraphVisualMetrics.defaultHitRadius,
        positionOverrides: GraphNodePositionOverrides = GraphNodePositionOverrides()
    ) -> GraphHitTestResult? {
        var best: GraphHitTestResult?
        let centeredPoint = GraphPoint(
            x: screenPoint.x - canvasSize.width / 2,
            y: screenPoint.y - canvasSize.height / 2
        )
        let graphPoint = viewport.graphPoint(for: centeredPoint)
        let queryRadius = maxDistance / viewport.zoomScale + 24
        let candidates = candidateNodeIndexes(
            around: graphPoint,
            radius: queryRadius
        )

        var visitedIndexes: Set<Int> = []
        for nodeIndex in candidates {
            guard layout.nodes.indices.contains(nodeIndex) else {
                continue
            }
            visitedIndexes.insert(nodeIndex)
            let node = layout.nodes[nodeIndex]
            best = nearestResult(
                currentBest: best,
                node: node,
                nodeIndex: nodeIndex,
                position: positionOverrides.position(for: node),
                screenPoint: screenPoint,
                viewport: viewport,
                canvasSize: canvasSize,
                maxDistance: maxDistance
            )
        }

        for nodeID in positionOverrides.positionsByNodeID.keys {
            guard let nodeIndex = nodeIndexByID[nodeID],
                  !visitedIndexes.contains(nodeIndex),
                  layout.nodes.indices.contains(nodeIndex)
            else {
                continue
            }
            let node = layout.nodes[nodeIndex]
            best = nearestResult(
                currentBest: best,
                node: node,
                nodeIndex: nodeIndex,
                position: positionOverrides.position(for: node),
                screenPoint: screenPoint,
                viewport: viewport,
                canvasSize: canvasSize,
                maxDistance: maxDistance
            )
        }

        return best
    }

    private func nearestResult(
        currentBest: GraphHitTestResult?,
        node: GraphLayoutNode,
        nodeIndex: Int,
        position: GraphPoint,
        screenPoint: GraphPoint,
        viewport: GraphViewport,
        canvasSize: GraphSize,
        maxDistance: Double
    ) -> GraphHitTestResult? {
        let nodePoint = nodeScreenPoint(for: position, viewport: viewport, canvasSize: canvasSize)
        let distance = hypot(screenPoint.x - nodePoint.x, screenPoint.y - nodePoint.y)
        let hitRadius = GraphVisualMetrics.hitRadius(
            forNodeRadius: node.radius,
            zoomScale: viewport.zoomScale,
            minimumHitRadius: maxDistance
        )
        guard distance <= hitRadius else {
            return currentBest
        }
        if currentBest == nil || distance < (currentBest?.distance ?? .greatestFiniteMagnitude) {
            return GraphHitTestResult(
                nodeID: node.nodeID,
                nodeIndex: nodeIndex,
                distance: distance
            )
        }
        return currentBest
    }

    private func candidateNodeIndexes(around point: GraphPoint, radius: Double) -> [Int] {
        let minCell = Self.gridCell(
            for: GraphPoint(x: point.x - radius, y: point.y - radius),
            bucketCellSize: bucketCellSize
        )
        let maxCell = Self.gridCell(
            for: GraphPoint(x: point.x + radius, y: point.y + radius),
            bucketCellSize: bucketCellSize
        )

        var indexes: [Int] = []
        for x in minCell.x...maxCell.x {
            for y in minCell.y...maxCell.y {
                indexes.append(contentsOf: buckets[GraphGridCell(x: x, y: y)] ?? [])
            }
        }
        return indexes
    }

    private func nodeScreenPoint(
        for position: GraphPoint,
        viewport: GraphViewport,
        canvasSize: GraphSize
    ) -> GraphPoint {
        let point = viewport.screenPoint(for: position)
        return GraphPoint(
            x: canvasSize.width / 2 + point.x,
            y: canvasSize.height / 2 + point.y
        )
    }

    private static func gridCell(for point: GraphPoint, bucketCellSize: Double) -> GraphGridCell {
        GraphGridCell(
            x: Int(floor(point.x / bucketCellSize)),
            y: Int(floor(point.y / bucketCellSize))
        )
    }

    private static func movedRenderIdentity(
        base: UInt64,
        nodeID: String,
        oldPosition: GraphPoint,
        newPosition: GraphPoint
    ) -> UInt64 {
        var hash = base

        func mix(_ value: UInt64) {
            hash ^= value
            hash &*= 0x100000001b3
        }

        for byte in nodeID.utf8 {
            mix(UInt64(byte))
        }
        mix(oldPosition.x.bitPattern)
        mix(oldPosition.y.bitPattern)
        mix(newPosition.x.bitPattern)
        mix(newPosition.y.bitPattern)
        return hash
    }
}

private struct GraphGridCell: Hashable, Sendable {
    let x: Int
    let y: Int
}

public struct GraphInteractionState: Equatable, Sendable {
    public private(set) var hoveredNodeID: String?
    public private(set) var selectedNodeID: String?
    public private(set) var dragState: GraphNodeDragState?

    public init(
        hoveredNodeID: String? = nil,
        selectedNodeID: String? = nil,
        dragState: GraphNodeDragState? = nil
    ) {
        self.hoveredNodeID = hoveredNodeID
        self.selectedNodeID = selectedNodeID
        self.dragState = dragState
    }

    public mutating func hover(_ nodeID: String?) {
        hoveredNodeID = nodeID
    }

    public mutating func select(_ nodeID: String?) {
        selectedNodeID = nodeID
    }

    public mutating func clearSelection() {
        selectedNodeID = nil
    }

    public mutating func beginDrag(
        nodeID: String,
        nodePosition: GraphPoint,
        pointerGraphPoint: GraphPoint,
        graphMovementThreshold: Double = GraphNodeDragState.defaultGraphMovementThreshold
    ) {
        dragState = GraphNodeDragState(
            nodeID: nodeID,
            startNodePosition: nodePosition,
            startPointerGraphPoint: pointerGraphPoint,
            graphMovementThreshold: graphMovementThreshold
        )
    }

    public mutating func updateDrag(to pointerGraphPoint: GraphPoint) {
        dragState?.update(to: pointerGraphPoint)
    }

    public mutating func finishDrag() -> GraphNodeDragResult? {
        defer {
            dragState = nil
        }
        return dragState?.result()
    }

    public mutating func cancelDrag() {
        dragState = nil
    }
}

public struct GraphNodeDragState: Equatable, Sendable {
    /// Graph-space threshold; callers that start from screen events should divide the screen threshold by zoom.
    public static let defaultGraphMovementThreshold = 3.0

    public let nodeID: String
    public let startNodePosition: GraphPoint
    public let startPointerGraphPoint: GraphPoint
    public private(set) var latestPointerGraphPoint: GraphPoint
    public let graphMovementThreshold: Double
    public private(set) var movedBeyondThreshold: Bool
    public var currentNodePosition: GraphPoint {
        GraphPoint(
            x: startNodePosition.x + latestPointerGraphPoint.x - startPointerGraphPoint.x,
            y: startNodePosition.y + latestPointerGraphPoint.y - startPointerGraphPoint.y
        )
    }

    public init(
        nodeID: String,
        startNodePosition: GraphPoint,
        startPointerGraphPoint: GraphPoint,
        graphMovementThreshold: Double = Self.defaultGraphMovementThreshold
    ) {
        self.nodeID = nodeID
        self.startNodePosition = startNodePosition
        self.startPointerGraphPoint = startPointerGraphPoint
        self.latestPointerGraphPoint = startPointerGraphPoint
        self.graphMovementThreshold = max(0, graphMovementThreshold)
        self.movedBeyondThreshold = false
    }

    public mutating func update(to pointerGraphPoint: GraphPoint) {
        latestPointerGraphPoint = pointerGraphPoint
        if distance(from: startPointerGraphPoint, to: pointerGraphPoint) >= graphMovementThreshold {
            movedBeyondThreshold = true
        }
    }

    public func result() -> GraphNodeDragResult {
        GraphNodeDragResult(
            nodeID: nodeID,
            nodePosition: currentNodePosition,
            movedBeyondThreshold: movedBeyondThreshold
        )
    }

    private func distance(from start: GraphPoint, to end: GraphPoint) -> Double {
        hypot(end.x - start.x, end.y - start.y)
    }
}

public struct GraphNodeDragResult: Equatable, Sendable {
    public let nodeID: String
    public let nodePosition: GraphPoint
    public let movedBeyondThreshold: Bool

    public init(nodeID: String, nodePosition: GraphPoint, movedBeyondThreshold: Bool) {
        self.nodeID = nodeID
        self.nodePosition = nodePosition
        self.movedBeyondThreshold = movedBeyondThreshold
    }
}

public struct GraphNodeDragStart: Equatable, Sendable {
    public let nodeID: String
    public let nodeIndex: Int
    public let nodePosition: GraphPoint
    public let pointerGraphPoint: GraphPoint
    public let graphMovementThreshold: Double

    public init(
        nodeID: String,
        nodeIndex: Int,
        nodePosition: GraphPoint,
        pointerGraphPoint: GraphPoint,
        graphMovementThreshold: Double
    ) {
        self.nodeID = nodeID
        self.nodeIndex = nodeIndex
        self.nodePosition = nodePosition
        self.pointerGraphPoint = pointerGraphPoint
        self.graphMovementThreshold = graphMovementThreshold
    }
}

public enum GraphDragStartDecision: Equatable, Sendable {
    case node(GraphNodeDragStart)
    case canvasPan
}

public enum GraphNodeDragCompletion: Equatable, Sendable {
    case tap(nodeID: String)
    case drag(GraphNodeDragResult)
}

public enum GraphGestureDecision {
    public static func dragStart(
        screenPoint: GraphPoint,
        viewport: GraphViewport,
        canvasSize: GraphSize,
        hitTestIndex: GraphHitTestIndex,
        screenMovementThreshold: Double = GraphNodeDragState.defaultGraphMovementThreshold,
        positionOverrides: GraphNodePositionOverrides = GraphNodePositionOverrides()
    ) -> GraphDragStartDecision {
        guard let hit = hitTestIndex.nearestNode(
            at: screenPoint,
            viewport: viewport,
            canvasSize: canvasSize,
            positionOverrides: positionOverrides
        ) else {
            return .canvasPan
        }
        guard hitTestIndex.layout.nodes.indices.contains(hit.nodeIndex) else {
            return .canvasPan
        }

        let node = hitTestIndex.layout.nodes[hit.nodeIndex]
        let nodePosition = positionOverrides.position(for: node)
        return .node(GraphNodeDragStart(
            nodeID: hit.nodeID,
            nodeIndex: hit.nodeIndex,
            nodePosition: nodePosition,
            pointerGraphPoint: pointerGraphPoint(
                screenPoint: screenPoint,
                viewport: viewport,
                canvasSize: canvasSize
            ),
            graphMovementThreshold: max(0, screenMovementThreshold) / viewport.zoomScale
        ))
    }

    public static func completion(for result: GraphNodeDragResult) -> GraphNodeDragCompletion {
        result.movedBeyondThreshold ? .drag(result) : .tap(nodeID: result.nodeID)
    }

    public static func pointerGraphPoint(
        screenPoint: GraphPoint,
        viewport: GraphViewport,
        canvasSize: GraphSize
    ) -> GraphPoint {
        let centeredPoint = GraphPoint(
            x: screenPoint.x - canvasSize.width / 2,
            y: screenPoint.y - canvasSize.height / 2
        )
        return viewport.graphPoint(for: centeredPoint)
    }
}

public struct GraphNodePositionOverrides: Equatable, Sendable {
    public private(set) var positionsByNodeID: [String: GraphPoint]

    public init(positionsByNodeID: [String: GraphPoint] = [:]) {
        self.positionsByNodeID = positionsByNodeID
    }

    public var isEmpty: Bool {
        positionsByNodeID.isEmpty
    }

    public var renderIdentity: UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325

        func mix(_ value: UInt64) {
            hash ^= value
            hash &*= 0x100000001b3
        }

        for (nodeID, point) in positionsByNodeID.sorted(by: { $0.key < $1.key }) {
            for byte in nodeID.utf8 {
                mix(UInt64(byte))
            }
            mix(point.x.bitPattern)
            mix(point.y.bitPattern)
        }
        return hash
    }

    public mutating func set(_ graphPoint: GraphPoint, for nodeID: String) {
        positionsByNodeID[nodeID] = graphPoint
    }

    public mutating func remove(nodeID: String) {
        positionsByNodeID.removeValue(forKey: nodeID)
    }

    public func position(for node: GraphLayoutNode) -> GraphPoint {
        positionsByNodeID[node.nodeID] ?? node.position
    }
}

public extension GraphLayoutNode {
    func withPosition(_ position: GraphPoint) -> GraphLayoutNode {
        GraphLayoutNode(
            index: index,
            nodeID: nodeID,
            fileID: fileID,
            relativePath: relativePath,
            label: label,
            kind: kind,
            degree: degree,
            tags: tags,
            position: position,
            radius: radius
        )
    }
}

public enum GraphSearchMatcher {
    public static func matchingNodeIDs(
        in layout: GraphRendererSnapshot,
        query: String
    ) -> Set<String> {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            return []
        }
        return Set(layout.nodes.compactMap { node in
            node.label.localizedCaseInsensitiveContains(normalizedQuery) ? node.nodeID : nil
        })
    }
}

public enum GraphNodeOpenResolver {
    public static func file(for node: GraphLayoutNode) -> FileTreeItem? {
        guard node.kind == .resolved,
              let relativePath = node.relativePath,
              !relativePath.isEmpty
        else {
            return nil
        }
        return FileTreeItem(relativePath: relativePath)
    }
}

public enum GraphAccessibilitySummaryBuilder {
    public static func summary(
        input: GraphRendererInput,
        selectedNode: GraphLayoutNode?,
        hoveredNode: GraphLayoutNode? = nil
    ) -> String {
        let searchMatchCount = input.searchMatchedNodeIDs.count
        let selectedText = selectedNode.map { ", selected \($0.label)" } ?? ""
        let hoveredText = hoveredNode.map { ", hovered \($0.label)" } ?? ""
        return "Graph canvas, \(input.layout.nodes.count) nodes, \(input.layout.edges.count) edges, \(searchMatchCount) search matches\(selectedText)\(hoveredText), zoom \(String(format: "%.1f", input.viewport.zoomScale))"
    }
}
