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
        for (arrayIndex, node) in layout.nodes.enumerated() {
            if arrayIndex.isMultiple(of: 2_048) {
                try checkCancellation()
            }
            buckets[Self.gridCell(for: node.position, bucketCellSize: self.bucketCellSize), default: []]
                .append(arrayIndex)
        }
        self.buckets = buckets
    }

    public func nearestNode(
        at screenPoint: GraphPoint,
        viewport: GraphViewport,
        canvasSize: GraphSize,
        maxDistance: Double = GraphVisualMetrics.defaultHitRadius
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

        for nodeIndex in candidates {
            guard layout.nodes.indices.contains(nodeIndex) else {
                continue
            }
            let node = layout.nodes[nodeIndex]
            let nodePoint = nodeScreenPoint(for: node, viewport: viewport, canvasSize: canvasSize)
            let distance = hypot(screenPoint.x - nodePoint.x, screenPoint.y - nodePoint.y)
            let hitRadius = GraphVisualMetrics.hitRadius(
                forNodeRadius: node.radius,
                zoomScale: viewport.zoomScale,
                minimumHitRadius: maxDistance
            )
            guard distance <= hitRadius else {
                continue
            }
            if best == nil || distance < (best?.distance ?? .greatestFiniteMagnitude) {
                best = GraphHitTestResult(
                    nodeID: node.nodeID,
                    nodeIndex: node.index,
                    distance: distance
                )
            }
        }

        return best
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
        for node: GraphLayoutNode,
        viewport: GraphViewport,
        canvasSize: GraphSize
    ) -> GraphPoint {
        let point = viewport.screenPoint(for: node.position)
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
}

private struct GraphGridCell: Hashable, Sendable {
    let x: Int
    let y: Int
}

public struct GraphInteractionState: Equatable, Sendable {
    public private(set) var hoveredNodeID: String?
    public private(set) var selectedNodeID: String?

    public init(
        hoveredNodeID: String? = nil,
        selectedNodeID: String? = nil
    ) {
        self.hoveredNodeID = hoveredNodeID
        self.selectedNodeID = selectedNodeID
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
        selectedNode: GraphLayoutNode?
    ) -> String {
        let searchMatchCount = input.searchMatchedNodeIDs.count
        let selectedText = selectedNode.map { ", selected \($0.label)" } ?? ""
        return "Graph canvas, \(input.layout.nodes.count) nodes, \(input.layout.edges.count) edges, \(searchMatchCount) search matches\(selectedText), zoom \(String(format: "%.1f", input.viewport.zoomScale))"
    }
}
