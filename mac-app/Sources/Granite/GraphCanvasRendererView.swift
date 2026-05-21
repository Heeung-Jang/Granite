import Foundation
import NativeMarkdownCore
import SwiftUI

struct GraphCanvasRendererView: View {
    let input: GraphRendererInput
    @Binding var viewport: GraphViewport
    let hitTestIndex: GraphHitTestIndex
    var callbacks: GraphRendererCallbacks
    var onHoverNode: (String?) -> Void
    var onSelectNode: (String?) -> Void
    var onOpenNode: (String) -> Void

    @State private var dragStartPanOffset: GraphPoint?
    @State private var drawReportGate = GraphCanvasDrawReportGate()
    @State private var pathCache = GraphCanvasPathCache()

    private let renderer = GraphRendererContract(rendererKind: .canvas)

    init(
        input: GraphRendererInput,
        viewport: Binding<GraphViewport>,
        callbacks: GraphRendererCallbacks = GraphRendererCallbacks(),
        hitTestIndex: GraphHitTestIndex? = nil,
        onHoverNode: @escaping (String?) -> Void = { _ in },
        onSelectNode: @escaping (String?) -> Void = { _ in },
        onOpenNode: @escaping (String) -> Void = { _ in }
    ) {
        self.input = input
        self._viewport = viewport
        self.callbacks = callbacks
        self.hitTestIndex = hitTestIndex ?? GraphHitTestIndex(layout: input.layout)
        self.onHoverNode = onHoverNode
        self.onSelectNode = onSelectNode
        self.onOpenNode = onOpenNode
    }

    @ViewBuilder
    var body: some View {
        let renderInput = currentInput
        let renderPaths = pathCache.paths(for: renderInput)

        switch validationState(for: renderInput) {
        case .ready:
            GeometryReader { proxy in
                Canvas { context, size in
                    let timer = AppTelemetryTimer()
                    let drawSignpost = AppTelemetry.beginGraphStage(.draw)
                    var graphContext = context
                    graphContext.translateBy(
                        x: size.width / 2 + CGFloat(renderInput.viewport.panOffset.x),
                        y: size.height / 2 + CGFloat(renderInput.viewport.panOffset.y)
                    )
                    graphContext.scaleBy(
                        x: CGFloat(renderInput.viewport.zoomScale),
                        y: CGFloat(renderInput.viewport.zoomScale)
                    )

                    drawEdges(input: renderInput, paths: renderPaths, context: &graphContext)
                    drawNodes(paths: renderPaths, context: &graphContext)
                    drawLabels(input: renderInput, context: &context, size: size)
                    AppTelemetry.endGraphStage(drawSignpost)

                    let metrics = renderer.metrics(
                        for: renderInput,
                        drawDurationMilliseconds: timer.elapsedMilliseconds()
                    )
                    callbacks.didCompleteDraw(metrics)
                    drawReportGate.reportIfNeeded(
                        identity: drawIdentity(for: renderInput),
                        metrics: metrics,
                        callbacks: callbacks
                    )
                }
                .background(ObsidianUI.editorBackground)
                .gesture(panGesture)
                .simultaneousGesture(tapGesture(input: renderInput, size: proxy.size))
                .onContinuousHover { phase in
                    updateHover(phase: phase, input: renderInput, size: proxy.size)
                }
                .focusable()
                .focusEffectDisabled()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilitySummary(for: renderInput))
                .accessibilityHint("Use arrow keys to pan, plus or minus to zoom, Return to open the selected node, and Escape to clear selection.")
            }
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

    private func tapGesture(input: GraphRendererInput, size: CGSize) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                let nodeID = hitNodeID(at: value.location, input: input, size: size)
                onSelectNode(nodeID)
                if let nodeID {
                    onOpenNode(nodeID)
                }
            }
    }

    private func updateHover(
        phase: HoverPhase,
        input: GraphRendererInput,
        size: CGSize
    ) {
        switch phase {
        case .active(let location):
            onHoverNode(hitNodeID(at: location, input: input, size: size))
        case .ended:
            onHoverNode(nil)
        }
    }

    private func drawEdges(
        input: GraphRendererInput,
        paths: GraphCanvasRenderPaths,
        context: inout GraphicsContext
    ) {
        context.stroke(
            paths.resolvedEdges,
            with: .color(Color.secondary.opacity(GraphVisualMetrics.resolvedEdgeAlpha)),
            lineWidth: GraphVisualMetrics.linkThickness(
                base: input.presentation.linkThickness,
                isActive: false
            )
        )
        context.stroke(
            paths.unresolvedEdges,
            with: .color(Color.secondary.opacity(GraphVisualMetrics.unresolvedEdgeAlpha)),
            lineWidth: GraphVisualMetrics.linkThickness(
                base: input.presentation.linkThickness,
                isActive: false
            )
        )
        context.stroke(
            paths.activeEdges,
            with: .color(Color.green.opacity(GraphVisualMetrics.activeEdgeAlpha)),
            lineWidth: GraphVisualMetrics.linkThickness(
                base: input.presentation.linkThickness,
                isActive: true
            )
        )
        context.stroke(
            paths.arrowHeads,
            with: .color(Color.secondary.opacity(GraphVisualMetrics.resolvedEdgeAlpha)),
            lineWidth: GraphVisualMetrics.linkThickness(
                base: input.presentation.linkThickness,
                isActive: false
            )
        )
    }

    private func drawNodes(
        paths: GraphCanvasRenderPaths,
        context: inout GraphicsContext
    ) {
        context.fill(paths.unresolvedNodes, with: .color(Color.secondary.opacity(GraphVisualMetrics.unresolvedNodeAlpha)))
        context.fill(paths.resolvedNodes, with: .color(Color.primary.opacity(GraphVisualMetrics.resolvedNodeAlpha)))
        for (colorHex, path) in paths.groupNodes {
            context.fill(path, with: .color(Color(graphHex: colorHex)))
        }
        context.fill(paths.searchNodes, with: .color(.green))
        context.fill(paths.hoveredNodes, with: .color(Color.green.opacity(GraphVisualMetrics.activeNodeAlpha)))
        context.fill(paths.selectedNodes, with: .color(Color.green))
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

    private func edgeIsActive(_ edge: GraphLayoutEdge, input: GraphRendererInput) -> Bool {
        guard let activeNodeID = input.hoveredNodeID ?? input.selectedNodeID,
              input.layout.nodes.indices.contains(edge.sourceIndex),
              input.layout.nodes.indices.contains(edge.targetIndex)
        else {
            return false
        }
        return input.layout.nodes[edge.sourceIndex].nodeID == activeNodeID
            || input.layout.nodes[edge.targetIndex].nodeID == activeNodeID
    }

    private func accessibilitySummary(for input: GraphRendererInput) -> String {
        GraphAccessibilitySummaryBuilder.summary(
            input: input,
            selectedNode: input.layout.nodes.first { $0.nodeID == input.selectedNodeID }
        )
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

    private func hitNodeID(
        at location: CGPoint,
        input: GraphRendererInput,
        size: CGSize
    ) -> String? {
        hitTestIndex.nearestNode(
            at: GraphPoint(x: Double(location.x), y: Double(location.y)),
            viewport: input.viewport,
            canvasSize: GraphSize(width: Double(size.width), height: Double(size.height))
        )?.nodeID
    }
}

private extension Color {
    init(graphHex: String) {
        let normalized = GraphColorHex.normalized(graphHex) ?? GraphColorHex.defaultHex
        let hex = String(normalized.dropFirst())
        let value = Int(hex, radix: 16) ?? 0x808080
        self.init(
            red: Double((value >> 16) & 0xff) / 255.0,
            green: Double((value >> 8) & 0xff) / 255.0,
            blue: Double(value & 0xff) / 255.0
        )
    }
}

private struct GraphCanvasRenderPaths {
    var resolvedEdges = Path()
    var unresolvedEdges = Path()
    var activeEdges = Path()
    var arrowHeads = Path()
    var resolvedNodes = Path()
    var unresolvedNodes = Path()
    var groupNodes: [String: Path] = [:]
    var searchNodes = Path()
    var hoveredNodes = Path()
    var selectedNodes = Path()
}

private final class GraphCanvasPathCache {
    private var cachedIdentity: String?
    private var cachedPaths: GraphCanvasRenderPaths?

    func paths(for input: GraphRendererInput) -> GraphCanvasRenderPaths {
        let identity = cacheIdentity(for: input)
        if cachedIdentity == identity, let cachedPaths {
            return cachedPaths
        }
        let paths = buildPaths(for: input)
        cachedIdentity = identity
        cachedPaths = paths
        return paths
    }

    private func buildPaths(for input: GraphRendererInput) -> GraphCanvasRenderPaths {
        var paths = GraphCanvasRenderPaths()

        for edge in input.layout.edges {
            guard input.layout.nodes.indices.contains(edge.sourceIndex),
                  input.layout.nodes.indices.contains(edge.targetIndex)
            else {
                continue
            }

            let source = graphPoint(input.layout.nodes[edge.sourceIndex].position)
            let target = graphPoint(input.layout.nodes[edge.targetIndex].position)
            if edgeIsActive(edge, input: input) {
                appendEdge(from: source, to: target, path: &paths.activeEdges)
            } else {
                switch edge.kind {
                case .resolved:
                    appendEdge(from: source, to: target, path: &paths.resolvedEdges)
                case .unresolved:
                    appendEdge(from: source, to: target, path: &paths.unresolvedEdges)
                }
            }
            if input.presentation.showArrows {
                appendArrowHead(from: source, to: target, path: &paths.arrowHeads)
            }
        }

        for node in input.layout.nodes {
            let radius = CGFloat(GraphVisualMetrics.drawRadius(
                forNodeRadius: node.radius,
                nodeSize: input.presentation.nodeSize
            ))
            let rect = CGRect(
                x: CGFloat(node.position.x) - radius,
                y: CGFloat(node.position.y) - radius,
                width: radius * 2,
                height: radius * 2
            )

            if input.selectedNodeID == node.nodeID {
                paths.selectedNodes.addEllipse(in: rect)
            } else if input.hoveredNodeID == node.nodeID {
                paths.hoveredNodes.addEllipse(in: rect)
            } else if input.searchMatchedNodeIDs.contains(node.nodeID) {
                paths.searchNodes.addEllipse(in: rect)
            } else if let colorHex = input.groupColorHexByNodeID[node.nodeID] {
                var groupPath = paths.groupNodes[colorHex] ?? Path()
                groupPath.addEllipse(in: rect)
                paths.groupNodes[colorHex] = groupPath
            } else {
                switch node.kind {
                case .resolved:
                    paths.resolvedNodes.addEllipse(in: rect)
                case .unresolved:
                    paths.unresolvedNodes.addEllipse(in: rect)
                }
            }
        }

        return paths
    }

    private func cacheIdentity(for input: GraphRendererInput) -> String {
        var searchHasher = Hasher()
        for nodeID in input.searchMatchedNodeIDs.sorted() {
            searchHasher.combine(nodeID)
        }
        let parts = [
            String(input.layout.requestID),
            String(input.layout.generation),
            String(input.layout.renderIdentity),
            String(input.layout.nodes.count),
            String(input.layout.edges.count),
            String(input.presentation.nodeSize.bitPattern),
            String(input.presentation.linkThickness.bitPattern),
            input.presentation.showArrows.description,
            groupColorIdentity(input.groupColorHexByNodeID),
            String(searchHasher.finalize()),
            input.hoveredNodeID ?? "",
            input.selectedNodeID ?? ""
        ]
        return parts.joined(separator: ":")
    }

    private func graphPoint(_ point: GraphPoint) -> CGPoint {
        CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))
    }

    private func appendEdge(from source: CGPoint, to target: CGPoint, path: inout Path) {
        path.move(to: source)
        path.addLine(to: target)
    }

    private func appendArrowHead(from source: CGPoint, to target: CGPoint, path: inout Path) {
        let dx = target.x - source.x
        let dy = target.y - source.y
        let length = max(0.001, sqrt(dx * dx + dy * dy))
        let unitX = dx / length
        let unitY = dy / length
        let normalX = -unitY
        let normalY = unitX
        let size: CGFloat = 10
        let spread: CGFloat = 5
        let base = CGPoint(x: target.x - unitX * size, y: target.y - unitY * size)
        let left = CGPoint(x: base.x + normalX * spread, y: base.y + normalY * spread)
        let right = CGPoint(x: base.x - normalX * spread, y: base.y - normalY * spread)

        path.move(to: target)
        path.addLine(to: left)
        path.move(to: target)
        path.addLine(to: right)
    }

    private func groupColorIdentity(_ colors: [String: String]) -> String {
        colors
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: ",")
    }

    private func edgeIsActive(_ edge: GraphLayoutEdge, input: GraphRendererInput) -> Bool {
        guard let activeNodeID = input.hoveredNodeID ?? input.selectedNodeID,
              input.layout.nodes.indices.contains(edge.sourceIndex),
              input.layout.nodes.indices.contains(edge.targetIndex)
        else {
            return false
        }
        return input.layout.nodes[edge.sourceIndex].nodeID == activeNodeID
            || input.layout.nodes[edge.targetIndex].nodeID == activeNodeID
    }
}

enum GraphCanvasRendererSmokeFixture {
    static let defaultSelectedNodeID = "file:weekly"

    static func input(
        viewport: GraphViewport = GraphViewport(),
        presentation: GraphPresentationSettings = GraphPresentationSettings(),
        searchText: String = "",
        hoveredNodeID: String? = nil,
        selectedNodeID: String? = defaultSelectedNodeID
    ) -> GraphRendererInput {
        GraphRendererInput(
            layout: layout,
            viewport: viewport,
            presentation: presentation,
            hoveredNodeID: hoveredNodeID,
            selectedNodeID: selectedNodeID,
            searchMatchedNodeIDs: searchMatchedNodeIDs(for: searchText)
        )
    }

    static func searchMatchedNodeIDs(for searchText: String) -> Set<String> {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return []
        }
        return GraphSearchMatcher.matchingNodeIDs(in: layout, query: query)
    }

    static let layout = GraphRendererSnapshot(
        requestID: 1,
        generation: 1,
        nodes: [
            fixtureNode(index: 0, id: "file:weekly", fileID: "codex/weeklyretrospective/2026-04-03-weekly-retrospective.md", relativePath: "Codex/WeeklyRetrospective/2026-04-03-Weekly-Retrospective.md", label: "Weekly Retrospective", degree: 4, x: 0, y: 0, radius: 7),
            fixtureNode(index: 1, id: "file:daily", fileID: "codex/daily/daily notes.md", relativePath: "Codex/Daily/Daily Notes.md", label: "Daily Notes", degree: 3, x: -110, y: 45, radius: 6),
            fixtureNode(index: 2, id: "file:projects", fileID: "codex/projects/projects.md", relativePath: "Codex/Projects/Projects.md", label: "Projects", degree: 3, x: 120, y: 40, radius: 6),
            fixtureNode(index: 3, id: "file:docs", fileID: "codex/docs/docs.md", relativePath: "Codex/docs/Docs.md", label: "Docs", degree: 2, x: -40, y: -115, radius: 5),
            fixtureNode(index: 4, id: "file:compound", fileID: "codex/compound engineering.md", relativePath: "Codex/Compound engineering.md", label: "Compound Engineering", degree: 1, x: 170, y: -80, radius: 4),
            fixtureNode(index: 5, id: "file:archive", fileID: "2025 archive/archive.md", relativePath: "2025 archive/Archive.md", label: "Archive", degree: 0, x: -210, y: -120, radius: 4)
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

    static let hitTestIndex = GraphHitTestIndex(layout: layout)

    private static func fixtureNode(
        index: Int,
        id: String,
        fileID: String,
        relativePath: String,
        label: String,
        degree: Int,
        x: Double,
        y: Double,
        radius: Double
    ) -> GraphLayoutNode {
        GraphLayoutNode(
            index: index,
            nodeID: id,
            fileID: fileID,
            relativePath: relativePath,
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
        _ = GraphCanvasRendererView(
            input: input,
            viewport: .constant(viewport),
            hitTestIndex: GraphCanvasRendererSmokeFixture.hitTestIndex
        )
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
