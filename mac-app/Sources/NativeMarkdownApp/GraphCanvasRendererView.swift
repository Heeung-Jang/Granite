import Foundation
import NativeMarkdownCore
import SwiftUI

struct GraphCanvasRendererView: View {
    let input: GraphRendererInput
    @Binding var viewport: GraphViewport
    var callbacks = GraphRendererCallbacks()

    @State private var dragStartPanOffset: GraphPoint?
    @State private var drawReportGate = GraphCanvasDrawReportGate()

    private let renderer = GraphRendererContract(rendererKind: .canvas)

    @ViewBuilder
    var body: some View {
        let renderInput = currentInput

        switch validationState(for: renderInput) {
        case .ready:
            Canvas { context, size in
                let timer = AppTelemetryTimer()

                drawEdges(input: renderInput, context: &context, size: size)
                drawNodes(input: renderInput, context: &context, size: size)
                drawLabels(input: renderInput, context: &context, size: size)

                let metrics = renderer.metrics(
                    for: renderInput,
                    drawDurationMilliseconds: timer.elapsedMilliseconds()
                )
                drawReportGate.reportIfNeeded(
                    identity: drawIdentity(for: renderInput),
                    metrics: metrics,
                    callbacks: callbacks
                )
            }
            .background(ObsidianUI.editorBackground)
            .gesture(panGesture)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary(for: renderInput))
        case .failed(let error):
            Color.clear
                .onAppear {
                    callbacks.didFail(error)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Graph renderer failed")
        }
    }

    private var currentInput: GraphRendererInput {
        var renderInput = input
        renderInput.viewport = viewport
        return renderInput
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStartPanOffset == nil {
                    dragStartPanOffset = viewport.panOffset
                }
                guard let start = dragStartPanOffset else {
                    return
                }
                viewport.panOffset = GraphPoint(
                    x: start.x + Double(value.translation.width),
                    y: start.y + Double(value.translation.height)
                )
            }
            .onEnded { _ in
                dragStartPanOffset = nil
            }
    }

    private func drawEdges(
        input: GraphRendererInput,
        context: inout GraphicsContext,
        size: CGSize
    ) {
        for edge in input.layout.edges {
            guard input.layout.nodes.indices.contains(edge.sourceIndex),
                  input.layout.nodes.indices.contains(edge.targetIndex)
            else {
                continue
            }

            let source = canvasPoint(
                for: input.layout.nodes[edge.sourceIndex].position,
                input: input,
                size: size
            )
            let target = canvasPoint(
                for: input.layout.nodes[edge.targetIndex].position,
                input: input,
                size: size
            )
            var path = Path()
            path.move(to: source)
            path.addLine(to: target)

            context.stroke(
                path,
                with: .color(edgeColor(edge)),
                lineWidth: CGFloat(max(0.5, Double(edge.weight).squareRoot() * input.presentation.linkThickness))
            )
        }
    }

    private func drawNodes(
        input: GraphRendererInput,
        context: inout GraphicsContext,
        size: CGSize
    ) {
        for node in input.layout.nodes {
            let point = canvasPoint(for: node.position, input: input, size: size)
            let radius = CGFloat(max(
                2.0,
                node.radius * input.presentation.nodeSize * input.viewport.zoomScale
            ))
            let rect = CGRect(
                x: point.x - radius,
                y: point.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            let path = Path(ellipseIn: rect)

            context.fill(path, with: .color(nodeColor(node, input: input)))
        }
    }

    private func drawLabels(
        input: GraphRendererInput,
        context: inout GraphicsContext,
        size: CGSize
    ) {
        for node in input.layout.nodes where input.labelIsVisible(for: node) {
            let point = canvasPoint(for: node.position, input: input, size: size)
            let text = Text(node.label)
                .font(.caption)
                .foregroundStyle(Color.primary)

            context.draw(
                text,
                at: CGPoint(x: point.x + CGFloat(node.radius + 6), y: point.y),
                anchor: .leading
            )
        }
    }

    private func canvasPoint(
        for graphPoint: GraphPoint,
        input: GraphRendererInput,
        size: CGSize
    ) -> CGPoint {
        let point = input.viewport.screenPoint(for: graphPoint)
        return CGPoint(
            x: size.width / 2 + CGFloat(point.x),
            y: size.height / 2 + CGFloat(point.y)
        )
    }

    private func nodeColor(_ node: GraphLayoutNode, input: GraphRendererInput) -> Color {
        if input.selectedNodeID == node.nodeID {
            return .accentColor
        }
        if input.searchMatchedNodeIDs.contains(node.nodeID) {
            return .green
        }

        switch node.kind {
        case .resolved:
            return Color.primary.opacity(0.7)
        case .unresolved:
            return Color.secondary.opacity(0.45)
        }
    }

    private func edgeColor(_ edge: GraphLayoutEdge) -> Color {
        switch edge.kind {
        case .resolved:
            return Color.secondary.opacity(0.22)
        case .unresolved:
            return Color.secondary.opacity(0.12)
        }
    }

    private func accessibilitySummary(for input: GraphRendererInput) -> String {
        "Graph canvas, \(input.layout.nodes.count) nodes, \(input.layout.edges.count) edges, zoom \(String(format: "%.1f", input.viewport.zoomScale))"
    }

    private func drawIdentity(for input: GraphRendererInput) -> String {
        [
            input.layout.requestID,
            input.layout.generation,
            UInt64(input.layout.nodes.count),
            UInt64(input.layout.edges.count)
        ]
        .map(String.init)
        .joined(separator: ":")
    }

    private func validationState(for input: GraphRendererInput) -> ValidationState {
        do {
            try renderer.validate(input)
            return .ready
        } catch let error as GraphRendererValidationError {
            return .failed(error)
        } catch {
            return .failed(.edgeEndpointOutOfBounds)
        }
    }

    private enum ValidationState {
        case ready
        case failed(GraphRendererValidationError)
    }
}

enum GraphCanvasRendererSmokeFixture {
    static let selectedNodeID = "file:weekly"

    static func input(
        viewport: GraphViewport = GraphViewport(),
        presentation: GraphPresentationSettings = GraphPresentationSettings(),
        searchText: String = ""
    ) -> GraphRendererInput {
        GraphRendererInput(
            layout: layout,
            viewport: viewport,
            presentation: presentation,
            selectedNodeID: selectedNodeID,
            searchMatchedNodeIDs: searchMatchedNodeIDs(for: searchText)
        )
    }

    static func searchMatchedNodeIDs(for searchText: String) -> Set<String> {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return []
        }
        return Set(layout.nodes.compactMap { node in
            node.label.localizedCaseInsensitiveContains(query) ? node.nodeID : nil
        })
    }

    static let layout = GraphRendererSnapshot(
        requestID: 1,
        generation: 1,
        nodes: [
            fixtureNode(index: 0, id: "file:weekly", label: "Weekly Retrospective", degree: 4, x: 0, y: 0, radius: 7),
            fixtureNode(index: 1, id: "file:daily", label: "Daily Notes", degree: 3, x: -110, y: 45, radius: 6),
            fixtureNode(index: 2, id: "file:projects", label: "Projects", degree: 3, x: 120, y: 40, radius: 6),
            fixtureNode(index: 3, id: "file:docs", label: "Docs", degree: 2, x: -40, y: -115, radius: 5),
            fixtureNode(index: 4, id: "file:compound", label: "Compound Engineering", degree: 1, x: 170, y: -80, radius: 4),
            fixtureNode(index: 5, id: "file:archive", label: "Archive", degree: 0, x: -210, y: -120, radius: 4)
        ],
        edges: [
            GraphLayoutEdge(sourceIndex: 0, targetIndex: 1, kind: .resolved, weight: 2),
            GraphLayoutEdge(sourceIndex: 0, targetIndex: 2, kind: .resolved, weight: 2),
            GraphLayoutEdge(sourceIndex: 0, targetIndex: 3, kind: .resolved, weight: 1),
            GraphLayoutEdge(sourceIndex: 2, targetIndex: 4, kind: .resolved, weight: 1)
        ],
        components: [
            GraphLayoutComponent(nodeIndexes: [0, 1, 2, 3, 4], isOrphanRing: false),
            GraphLayoutComponent(nodeIndexes: [5], isOrphanRing: true)
        ]
    )

    private static func fixtureNode(
        index: Int,
        id: String,
        label: String,
        degree: Int,
        x: Double,
        y: Double,
        radius: Double
    ) -> GraphLayoutNode {
        GraphLayoutNode(
            index: index,
            nodeID: id,
            label: label,
            kind: .resolved,
            degree: degree,
            position: GraphPoint(x: x, y: y),
            radius: radius
        )
    }
}

enum GraphCanvasRendererSmokeProbe {
    @MainActor
    static func run() throws -> GraphRendererMetrics {
        var viewport = GraphViewport()
        let input = GraphCanvasRendererSmokeFixture.input(viewport: viewport)
        let renderer = GraphRendererContract(rendererKind: .canvas)

        try renderer.validate(input)
        _ = GraphCanvasRendererView(input: input, viewport: .constant(viewport))
        viewport.reset()

        let metrics = renderer.metrics(for: input, drawDurationMilliseconds: 0)
        guard metrics.nodeCount == 6, metrics.edgeCount == 4 else {
            throw GraphCanvasRendererSmokeError.unexpectedFixtureCounts
        }
        return metrics
    }
}

private enum GraphCanvasRendererSmokeError: Error {
    case unexpectedFixtureCounts
}

private final class GraphCanvasDrawReportGate: @unchecked Sendable {
    private let lock = NSLock()
    private var reportedIdentities: Set<String> = []

    func reportIfNeeded(
        identity: String,
        metrics: GraphRendererMetrics,
        callbacks: GraphRendererCallbacks
    ) {
        lock.lock()
        let shouldReport = reportedIdentities.insert(identity).inserted
        lock.unlock()

        guard shouldReport else {
            return
        }

        DispatchQueue.main.async {
            callbacks.didCompleteFirstDraw(metrics)
        }
    }
}
