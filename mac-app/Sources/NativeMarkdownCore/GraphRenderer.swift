import Foundation

public enum GraphRendererKind: String, Equatable, Sendable {
    case canvas
    case metal
}

public enum GraphRendererValidationError: Error, Equatable, Sendable {
    case edgeEndpointOutOfBounds
}

public protocol GraphRendering: Sendable {
    var rendererKind: GraphRendererKind { get }

    func validate(_ input: GraphRendererInput) throws
    func metrics(
        for input: GraphRendererInput,
        drawDurationMilliseconds: Double
    ) -> GraphRendererMetrics
}

public struct GraphRendererContract: GraphRendering, Equatable, Sendable {
    public let rendererKind: GraphRendererKind

    public init(rendererKind: GraphRendererKind) {
        self.rendererKind = rendererKind
    }

    public func validate(_ input: GraphRendererInput) throws {
        try input.validate()
    }

    public func metrics(
        for input: GraphRendererInput,
        drawDurationMilliseconds: Double
    ) -> GraphRendererMetrics {
        GraphRendererMetrics(
            rendererKind: rendererKind,
            nodeCount: input.layout.nodes.count,
            edgeCount: input.layout.edges.count,
            drawDurationMilliseconds: drawDurationMilliseconds
        )
    }
}

public struct GraphRendererCallbacks: Sendable {
    public let didCompleteFirstDraw: @Sendable (GraphRendererMetrics) -> Void
    public let didFail: @Sendable (GraphRendererValidationError) -> Void

    public init(
        didCompleteFirstDraw: @escaping @Sendable (GraphRendererMetrics) -> Void = { _ in },
        didFail: @escaping @Sendable (GraphRendererValidationError) -> Void = { _ in }
    ) {
        self.didCompleteFirstDraw = didCompleteFirstDraw
        self.didFail = didFail
    }
}

public struct GraphRendererMetrics: Equatable, Sendable {
    public let rendererKind: GraphRendererKind
    public let nodeCount: Int
    public let edgeCount: Int
    public let drawDurationMilliseconds: Double

    public init(
        rendererKind: GraphRendererKind,
        nodeCount: Int,
        edgeCount: Int,
        drawDurationMilliseconds: Double
    ) {
        self.rendererKind = rendererKind
        self.nodeCount = nodeCount
        self.edgeCount = edgeCount
        self.drawDurationMilliseconds = drawDurationMilliseconds
    }
}

public struct GraphRendererInput: Equatable, Sendable {
    public var layout: GraphRendererSnapshot
    public var viewport: GraphViewport
    public var presentation: GraphPresentationSettings
    public var hoveredNodeID: String?
    public var selectedNodeID: String?
    public var searchMatchedNodeIDs: Set<String>

    public init(
        layout: GraphRendererSnapshot,
        viewport: GraphViewport = GraphViewport(),
        presentation: GraphPresentationSettings = GraphPresentationSettings(),
        hoveredNodeID: String? = nil,
        selectedNodeID: String? = nil,
        searchMatchedNodeIDs: Set<String> = []
    ) {
        self.layout = layout
        self.viewport = viewport
        self.presentation = presentation
        self.hoveredNodeID = hoveredNodeID
        self.selectedNodeID = selectedNodeID
        self.searchMatchedNodeIDs = searchMatchedNodeIDs
    }

    public func validate() throws {
        let nodeCount = layout.nodes.count
        for edge in layout.edges {
            guard edge.sourceIndex >= 0,
                  edge.sourceIndex < nodeCount,
                  edge.targetIndex >= 0,
                  edge.targetIndex < nodeCount
            else {
                throw GraphRendererValidationError.edgeEndpointOutOfBounds
            }
        }
    }

    public func labelIsVisible(for node: GraphLayoutNode) -> Bool {
        GraphLabelVisibilityPolicy.isVisible(
            nodeID: node.nodeID,
            settings: presentation,
            context: GraphLabelVisibilityContext(
                hoveredNodeID: hoveredNodeID,
                selectedNodeID: selectedNodeID,
                searchMatchedNodeIDs: searchMatchedNodeIDs,
                zoomScale: viewport.zoomScale
            )
        )
    }
}
