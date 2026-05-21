import AppKit
@preconcurrency import Metal
@preconcurrency import MetalKit
import NativeMarkdownCore
import SwiftUI

struct GraphRendererSurfaceView: View {
    let input: GraphRendererInput
    @Binding var viewport: GraphViewport
    var callbacks: GraphRendererCallbacks
    let hitTestIndex: GraphHitTestIndex
    var onHoverNode: (String?) -> Void
    var onSelectNode: (String?) -> Void
    var onOpenNode: (String) -> Void

    init(
        input: GraphRendererInput,
        viewport: Binding<GraphViewport>,
        callbacks: GraphRendererCallbacks = GraphRendererCallbacks(),
        hitTestIndex: GraphHitTestIndex,
        onHoverNode: @escaping (String?) -> Void = { _ in },
        onSelectNode: @escaping (String?) -> Void = { _ in },
        onOpenNode: @escaping (String) -> Void = { _ in }
    ) {
        self.input = input
        self._viewport = viewport
        self.callbacks = callbacks
        self.hitTestIndex = hitTestIndex
        self.onHoverNode = onHoverNode
        self.onSelectNode = onSelectNode
        self.onOpenNode = onOpenNode
    }

    var body: some View {
        if GraphMetalRendererAvailability.isAvailable {
            GraphMetalRendererView(
                input: input,
                viewport: $viewport,
                callbacks: callbacks,
                hitTestIndex: hitTestIndex,
                onHoverNode: onHoverNode,
                onSelectNode: onSelectNode,
                onOpenNode: onOpenNode
            )
        } else {
            GraphCanvasRendererView(
                input: input,
                viewport: $viewport,
                callbacks: callbacks,
                hitTestIndex: hitTestIndex,
                onHoverNode: onHoverNode,
                onSelectNode: onSelectNode,
                onOpenNode: onOpenNode
            )
        }
    }
}

@MainActor
enum GraphMetalRendererAvailability {
    static let device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()

    static var isAvailable: Bool {
        device != nil
    }
}

struct GraphMetalRendererView: View {
    let input: GraphRendererInput
    @Binding var viewport: GraphViewport
    var callbacks: GraphRendererCallbacks
    let hitTestIndex: GraphHitTestIndex
    var onHoverNode: (String?) -> Void
    var onSelectNode: (String?) -> Void
    var onOpenNode: (String) -> Void

    @State private var dragStartPanOffset: GraphPoint?
    @State private var drawReportGate = GraphMetalDrawReportGate()
    @State private var metalInitializationFailed = false

    init(
        input: GraphRendererInput,
        viewport: Binding<GraphViewport>,
        callbacks: GraphRendererCallbacks = GraphRendererCallbacks(),
        hitTestIndex: GraphHitTestIndex,
        onHoverNode: @escaping (String?) -> Void = { _ in },
        onSelectNode: @escaping (String?) -> Void = { _ in },
        onOpenNode: @escaping (String) -> Void = { _ in }
    ) {
        self.input = input
        self._viewport = viewport
        self.callbacks = callbacks
        self.hitTestIndex = hitTestIndex
        self.onHoverNode = onHoverNode
        self.onSelectNode = onSelectNode
        self.onOpenNode = onOpenNode
    }

    @ViewBuilder
    var body: some View {
        if metalInitializationFailed {
            GraphCanvasRendererView(
                input: input,
                viewport: $viewport,
                callbacks: callbacks,
                hitTestIndex: hitTestIndex,
                onHoverNode: onHoverNode,
                onSelectNode: onSelectNode,
                onOpenNode: onOpenNode
            )
        } else {
            metalBody
        }
    }

    @ViewBuilder
    private var metalBody: some View {
        switch validationState(for: currentInput) {
        case .ready(let renderInput):
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    GraphMetalRepresentable(
                        input: renderInput,
                        callbacks: callbacks,
                        drawReportGate: drawReportGate,
                        onInitializationFailed: {
                            metalInitializationFailed = true
                        }
                    )

                    GraphMetalLabelsOverlay(input: renderInput)
                        .allowsHitTesting(false)
                }
                .background(ObsidianUI.editorBackground)
                .gesture(panGesture)
                .simultaneousGesture(tapGesture(input: renderInput, size: proxy.size))
                .onContinuousHover { phase in
                    updateHover(phase: phase, input: renderInput, size: proxy.size)
                }
                .focusable()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilitySummary(for: renderInput))
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

    private func accessibilitySummary(for input: GraphRendererInput) -> String {
        GraphAccessibilitySummaryBuilder.summary(
            input: input,
            selectedNode: input.layout.nodes.first { $0.nodeID == input.selectedNodeID }
        )
    }

    private func validationState(for input: GraphRendererInput) -> ValidationState {
        do {
            try input.validate()
            return .ready(input)
        } catch let error as GraphRendererValidationError {
            return .failed(error)
        } catch {
            return .failed(.edgeEndpointOutOfBounds)
        }
    }

    private enum ValidationState {
        case ready(GraphRendererInput)
        case failed(GraphRendererValidationError)
    }
}

private struct GraphMetalRepresentable: NSViewRepresentable {
    let input: GraphRendererInput
    var callbacks: GraphRendererCallbacks
    let drawReportGate: GraphMetalDrawReportGate
    let onInitializationFailed: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onInitializationFailed: onInitializationFailed)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: GraphMetalRendererAvailability.device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.delegate = context.coordinator
        context.coordinator.attach(view)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.update(
            input: input,
            callbacks: callbacks,
            drawReportGate: drawReportGate
        )
        view.clearColor = GraphMetalColor.clearColor()
        view.setNeedsDisplay(view.bounds)
        view.draw()
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        private let renderer = GraphRendererContract(rendererKind: .metal)
        private let onInitializationFailed: @MainActor () -> Void
        private var metalRenderer: GraphMetalRenderer?
        private var input: GraphRendererInput?
        private var callbacks = GraphRendererCallbacks()
        private var drawReportGate = GraphMetalDrawReportGate()

        init(onInitializationFailed: @escaping @MainActor () -> Void) {
            self.onInitializationFailed = onInitializationFailed
        }

        @MainActor
        func attach(_ view: MTKView) {
            guard let device = view.device else {
                onInitializationFailed()
                return
            }
            do {
                metalRenderer = try GraphMetalRenderer(device: device)
            } catch {
                onInitializationFailed()
            }
        }

        @MainActor
        func update(
            input: GraphRendererInput,
            callbacks: GraphRendererCallbacks,
            drawReportGate: GraphMetalDrawReportGate
        ) {
            self.input = input
            self.callbacks = callbacks
            self.drawReportGate = drawReportGate

            do {
                try renderer.validate(input)
                guard let metalRenderer else {
                    onInitializationFailed()
                    return
                }
                try metalRenderer.updateBuffers(for: input)
            } catch let error as GraphRendererValidationError {
                callbacks.didFail(error)
            } catch {
                callbacks.didFail(.edgeEndpointOutOfBounds)
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        @MainActor
        func draw(in view: MTKView) {
            guard let input,
                  let metalRenderer
            else {
                return
            }
            metalRenderer.draw(
                input: input,
                in: view,
                renderer: renderer,
                callbacks: callbacks,
                drawReportGate: drawReportGate
            )
        }
    }
}

private final class GraphMetalRenderer {
    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let edgePipeline: any MTLRenderPipelineState
    private let nodePipeline: any MTLRenderPipelineState
    private var cachedIdentity: String?
    private var edgeBuffer: (any MTLBuffer)?
    private var nodeBuffer: (any MTLBuffer)?
    private var edgeVertexCount = 0
    private var nodeVertexCount = 0

    init(device: any MTLDevice) throws {
        self.device = device
        guard let commandQueue = device.makeCommandQueue() else {
            throw GraphMetalRendererError.commandQueueUnavailable
        }
        self.commandQueue = commandQueue

        let library = try device.makeLibrary(source: graphMetalShaderSource, options: nil)
        guard let edgeVertex = library.makeFunction(name: "graphEdgeVertex"),
              let edgeFragment = library.makeFunction(name: "graphEdgeFragment"),
              let nodeVertex = library.makeFunction(name: "graphNodeVertex"),
              let nodeFragment = library.makeFunction(name: "graphNodeFragment")
        else {
            throw GraphMetalRendererError.shaderUnavailable
        }

        edgePipeline = try Self.makePipeline(
            device: device,
            vertex: edgeVertex,
            fragment: edgeFragment
        )
        nodePipeline = try Self.makePipeline(
            device: device,
            vertex: nodeVertex,
            fragment: nodeFragment
        )
    }

    func updateBuffers(for input: GraphRendererInput) throws {
        let identity = cacheIdentity(for: input)
        guard cachedIdentity != identity else {
            return
        }

        var edgeVertices: [GraphMetalVertex] = []
        edgeVertices.reserveCapacity(input.layout.edges.count * 2)
        for edge in input.layout.edges {
            guard input.layout.nodes.indices.contains(edge.sourceIndex),
                  input.layout.nodes.indices.contains(edge.targetIndex)
            else {
                continue
            }
            let color = edgeColor(edge, input: input)
            edgeVertices.append(GraphMetalVertex(
                position: metalPoint(input.layout.nodes[edge.sourceIndex].position),
                color: color,
                radius: 1
            ))
            edgeVertices.append(GraphMetalVertex(
                position: metalPoint(input.layout.nodes[edge.targetIndex].position),
                color: color,
                radius: 1
            ))
        }

        var nodeVertices: [GraphMetalVertex] = []
        nodeVertices.reserveCapacity(input.layout.nodes.count)
        for node in input.layout.nodes {
            nodeVertices.append(GraphMetalVertex(
                position: metalPoint(node.position),
                color: nodeColor(node, input: input),
                radius: Float(max(2.0, node.radius * input.presentation.nodeSize))
            ))
        }

        edgeBuffer = Self.makeBuffer(device: device, vertices: edgeVertices)
        nodeBuffer = Self.makeBuffer(device: device, vertices: nodeVertices)
        edgeVertexCount = edgeVertices.count
        nodeVertexCount = nodeVertices.count
        cachedIdentity = identity
    }

    @MainActor
    func draw(
        input: GraphRendererInput,
        in view: MTKView,
        renderer: GraphRendererContract,
        callbacks: GraphRendererCallbacks,
        drawReportGate: GraphMetalDrawReportGate
    ) {
        guard view.bounds.width > 0,
              view.bounds.height > 0,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else {
            return
        }

        let timer = AppTelemetryTimer()
        let drawSignpost = AppTelemetry.beginGraphStage(.draw)
        var uniforms = GraphMetalUniforms(
            viewportSize: SIMD2<Float>(
                Float(view.bounds.width),
                Float(view.bounds.height)
            ),
            panOffset: SIMD2<Float>(
                Float(input.viewport.panOffset.x),
                Float(input.viewport.panOffset.y)
            ),
            zoomScale: Float(input.viewport.zoomScale),
            pointScale: Float(view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
        )

        if let edgeBuffer, edgeVertexCount > 0 {
            encoder.setRenderPipelineState(edgePipeline)
            encoder.setVertexBuffer(edgeBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(
                &uniforms,
                length: MemoryLayout<GraphMetalUniforms>.stride,
                index: 1
            )
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: edgeVertexCount)
        }

        if let nodeBuffer, nodeVertexCount > 0 {
            encoder.setRenderPipelineState(nodePipeline)
            encoder.setVertexBuffer(nodeBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(
                &uniforms,
                length: MemoryLayout<GraphMetalUniforms>.stride,
                index: 1
            )
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: nodeVertexCount)
        }

        encoder.endEncoding()
        AppTelemetry.endGraphStage(drawSignpost)

        let identity = drawIdentity(for: input)
        commandBuffer.present(drawable)
        let completion = GraphMetalDrawCompletion(
            renderer: renderer,
            input: input,
            timer: timer,
            identity: identity,
            callbacks: callbacks,
            drawReportGate: drawReportGate
        )
        commandBuffer.addCompletedHandler(completion.handle)
        commandBuffer.commit()
    }

    private static func makePipeline(
        device: any MTLDevice,
        vertex: any MTLFunction,
        fragment: any MTLFunction
    ) throws -> any MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static func makeBuffer(
        device: any MTLDevice,
        vertices: [GraphMetalVertex]
    ) -> (any MTLBuffer)? {
        guard !vertices.isEmpty else {
            return nil
        }
        return vertices.withUnsafeBytes { bytes in
            device.makeBuffer(
                bytes: bytes.baseAddress!,
                length: bytes.count,
                options: [.storageModeShared]
            )
        }
    }

    private func cacheIdentity(for input: GraphRendererInput) -> String {
        var searchHasher = Hasher()
        for nodeID in input.searchMatchedNodeIDs.sorted() {
            searchHasher.combine(nodeID)
        }
        return [
            String(input.layout.requestID),
            String(input.layout.generation),
            String(input.layout.renderIdentity),
            String(input.layout.nodes.count),
            String(input.layout.edges.count),
            String(input.presentation.nodeSize.bitPattern),
            String(input.presentation.linkThickness.bitPattern),
            String(searchHasher.finalize()),
            input.hoveredNodeID ?? "",
            input.selectedNodeID ?? ""
        ]
        .joined(separator: ":")
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

    private func metalPoint(_ point: GraphPoint) -> SIMD2<Float> {
        SIMD2<Float>(Float(point.x), Float(point.y))
    }

    private func nodeColor(_ node: GraphLayoutNode, input: GraphRendererInput) -> SIMD4<Float> {
        if input.selectedNodeID == node.nodeID {
            return GraphMetalColor.selectedNode
        }
        if input.hoveredNodeID == node.nodeID {
            return GraphMetalColor.hoveredNode
        }
        if input.searchMatchedNodeIDs.contains(node.nodeID) {
            return GraphMetalColor.searchNode
        }

        switch node.kind {
        case .resolved:
            return GraphMetalColor.resolvedNode
        case .unresolved:
            return GraphMetalColor.unresolvedNode
        }
    }

    private func edgeColor(_ edge: GraphLayoutEdge, input: GraphRendererInput) -> SIMD4<Float> {
        if edgeIsActive(edge, input: input) {
            return GraphMetalColor.activeEdge
        }

        switch edge.kind {
        case .resolved:
            return GraphMetalColor.resolvedEdge
        case .unresolved:
            return GraphMetalColor.unresolvedEdge
        }
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

private final class GraphMetalDrawCompletion: @unchecked Sendable {
    private let renderer: GraphRendererContract
    private let input: GraphRendererInput
    private let timer: AppTelemetryTimer
    private let identity: String
    private let callbacks: GraphRendererCallbacks
    private let drawReportGate: GraphMetalDrawReportGate

    init(
        renderer: GraphRendererContract,
        input: GraphRendererInput,
        timer: AppTelemetryTimer,
        identity: String,
        callbacks: GraphRendererCallbacks,
        drawReportGate: GraphMetalDrawReportGate
    ) {
        self.renderer = renderer
        self.input = input
        self.timer = timer
        self.identity = identity
        self.callbacks = callbacks
        self.drawReportGate = drawReportGate
    }

    func handle(_ commandBuffer: any MTLCommandBuffer) {
        let metrics = renderer.metrics(
            for: input,
            drawDurationMilliseconds: timer.elapsedMilliseconds()
        )
        DispatchQueue.main.async {
            self.callbacks.didCompleteDraw(metrics)
            self.drawReportGate.reportIfNeeded(
                identity: self.identity,
                metrics: metrics,
                callbacks: self.callbacks
            )
        }
    }
}

private struct GraphMetalLabelsOverlay: View {
    let input: GraphRendererInput

    var body: some View {
        if hasVisibleLabels {
            Canvas { context, size in
                for node in input.layout.nodes where input.labelIsVisible(for: node) {
                    let point = canvasPoint(for: node.position, size: size)
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
        }
    }

    private var hasVisibleLabels: Bool {
        switch input.presentation.labelVisibility {
        case .always:
            return true
        case .hidden:
            return input.hoveredNodeID != nil || input.selectedNodeID != nil
        case .automatic:
            return input.hoveredNodeID != nil
                || input.selectedNodeID != nil
                || !input.searchMatchedNodeIDs.isEmpty
                || input.viewport.zoomScale >= 1.6
        }
    }

    private func canvasPoint(for graphPoint: GraphPoint, size: CGSize) -> CGPoint {
        let point = input.viewport.screenPoint(for: graphPoint)
        return CGPoint(
            x: size.width / 2 + CGFloat(point.x),
            y: size.height / 2 + CGFloat(point.y)
        )
    }
}

private struct GraphMetalVertex {
    var position: SIMD2<Float>
    var color: SIMD4<Float>
    var radius: Float
}

private struct GraphMetalUniforms {
    var viewportSize: SIMD2<Float>
    var panOffset: SIMD2<Float>
    var zoomScale: Float
    var pointScale: Float
}

private enum GraphMetalColor {
    static let resolvedNode = SIMD4<Float>(0.18, 0.18, 0.18, 0.72)
    static let unresolvedNode = SIMD4<Float>(0.42, 0.42, 0.42, 0.45)
    static let searchNode = SIMD4<Float>(0.07, 0.72, 0.28, 1.0)
    static let hoveredNode = SIMD4<Float>(0.0, 0.48, 1.0, 0.85)
    static let selectedNode = SIMD4<Float>(0.0, 0.48, 1.0, 1.0)
    static let resolvedEdge = SIMD4<Float>(0.25, 0.25, 0.25, 0.22)
    static let unresolvedEdge = SIMD4<Float>(0.25, 0.25, 0.25, 0.12)
    static let activeEdge = SIMD4<Float>(0.0, 0.48, 1.0, 0.55)

    static func clearColor() -> MTLClearColor {
        let color = NSColor.textBackgroundColor.usingColorSpace(.deviceRGB)
            ?? NSColor.white
        return MTLClearColor(
            red: Double(color.redComponent),
            green: Double(color.greenComponent),
            blue: Double(color.blueComponent),
            alpha: Double(color.alphaComponent)
        )
    }
}

private enum GraphMetalRendererError: Error {
    case commandQueueUnavailable
    case shaderUnavailable
}

private final class GraphMetalDrawReportGate: @unchecked Sendable {
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

private let graphMetalShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct GraphMetalVertex {
    float2 position;
    float4 color;
    float radius;
};

struct GraphMetalUniforms {
    float2 viewportSize;
    float2 panOffset;
    float zoomScale;
    float pointScale;
};

struct GraphMetalRasterOut {
    float4 position [[position]];
    float4 color;
    float pointSize [[point_size]];
};

static float4 graphClipPosition(float2 graphPosition, constant GraphMetalUniforms& uniforms) {
    float2 screenPosition = graphPosition * uniforms.zoomScale
        + uniforms.panOffset
        + uniforms.viewportSize * 0.5;
    float2 clipPosition = float2(
        (screenPosition.x / uniforms.viewportSize.x) * 2.0 - 1.0,
        1.0 - (screenPosition.y / uniforms.viewportSize.y) * 2.0
    );
    return float4(clipPosition, 0.0, 1.0);
}

vertex GraphMetalRasterOut graphEdgeVertex(
    uint vertexID [[vertex_id]],
    constant GraphMetalVertex* vertices [[buffer(0)]],
    constant GraphMetalUniforms& uniforms [[buffer(1)]]
) {
    GraphMetalVertex item = vertices[vertexID];
    GraphMetalRasterOut out;
    out.position = graphClipPosition(item.position, uniforms);
    out.color = item.color;
    out.pointSize = 1.0;
    return out;
}

fragment float4 graphEdgeFragment(GraphMetalRasterOut in [[stage_in]]) {
    return in.color;
}

vertex GraphMetalRasterOut graphNodeVertex(
    uint vertexID [[vertex_id]],
    constant GraphMetalVertex* vertices [[buffer(0)]],
    constant GraphMetalUniforms& uniforms [[buffer(1)]]
) {
    GraphMetalVertex item = vertices[vertexID];
    GraphMetalRasterOut out;
    out.position = graphClipPosition(item.position, uniforms);
    out.color = item.color;
    out.pointSize = max(2.0, item.radius * uniforms.zoomScale * 2.0 * uniforms.pointScale);
    return out;
}

fragment float4 graphNodeFragment(
    GraphMetalRasterOut in [[stage_in]],
    float2 pointCoordinate [[point_coord]]
) {
    float2 centered = pointCoordinate * 2.0 - 1.0;
    if (dot(centered, centered) > 1.0) {
        discard_fragment();
    }
    return in.color;
}
"""
