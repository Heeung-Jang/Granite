import AppKit
import Darwin
import Foundation
import NativeMarkdownCore
import SwiftUI

struct GraphRendererBenchmarkResult: Codable {
    let rendererKind: String
    let nodeCount: Int
    let edgeCount: Int
    let encodedPayloadBytes: Int
    let decodeDurationMilliseconds: Double
    let layoutDurationMilliseconds: Double
    let hitTestIndexDurationMilliseconds: Double
    let firstFrameDurationMilliseconds: Double
    let firstDrawDurationMilliseconds: Double
    let panZoomP95FrameDurationMilliseconds: Double
    let panZoomP99FrameDurationMilliseconds: Double
    let panZoomP95DrawDurationMilliseconds: Double
    let panZoomP99DrawDurationMilliseconds: Double
    let mainThreadStallMilliseconds: Double
    let totalFirstRenderDurationMilliseconds: Double
    let totalMemoryDeltaBytes: Int?
    let sampleCount: Int
}

enum GraphCanvasBenchmarkProbe {
    @MainActor
    static func run(payloadURL: URL) throws -> GraphRendererBenchmarkResult {
        let setup = try GraphRendererBenchmarkSetup(payloadURL: payloadURL)
        let driver = GraphRendererBenchmarkDriver(
            totalTimer: setup.totalTimer,
            samples: GraphRendererBenchmarkSetup.panZoomSamples()
        )
        let host = GraphCanvasBenchmarkHost(
            layout: setup.layout,
            hitTestIndex: setup.hitTestIndex,
            driver: driver
        )
        return try runWindowBenchmark(
            title: "Graph Canvas Benchmark",
            setup: setup,
            driver: driver,
            host: host,
            rendererKind: .canvas
        )
    }

    @MainActor
    static func encodedResult(payloadURL: URL) throws -> String {
        let result = try run(payloadURL: payloadURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(result)
        guard let json = String(data: data, encoding: .utf8) else {
            throw GraphRendererBenchmarkError.invalidResult
        }
        return json
    }
}

enum GraphMetalBenchmarkProbe {
    @MainActor
    static func run(payloadURL: URL) throws -> GraphRendererBenchmarkResult {
        guard GraphMetalRendererAvailability.isAvailable else {
            throw GraphRendererBenchmarkError.metalUnavailable
        }
        let setup = try GraphRendererBenchmarkSetup(payloadURL: payloadURL)
        let driver = GraphRendererBenchmarkDriver(
            totalTimer: setup.totalTimer,
            samples: GraphRendererBenchmarkSetup.panZoomSamples()
        )
        let host = GraphMetalBenchmarkHost(
            layout: setup.layout,
            hitTestIndex: setup.hitTestIndex,
            driver: driver
        )
        return try runWindowBenchmark(
            title: "Graph Metal Benchmark",
            setup: setup,
            driver: driver,
            host: host,
            rendererKind: .metal
        )
    }

    @MainActor
    static func encodedResult(payloadURL: URL) throws -> String {
        let result = try run(payloadURL: payloadURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(result)
        guard let json = String(data: data, encoding: .utf8) else {
            throw GraphRendererBenchmarkError.invalidResult
        }
        return json
    }
}

private struct GraphRendererBenchmarkSetup {
    let totalTimer: AppTelemetryTimer
    let totalMemoryBefore: Int?
    let payloadData: Data
    let layout: GraphRendererSnapshot
    let hitTestIndex: GraphHitTestIndex
    let decodeDuration: Double
    let layoutDuration: Double
    let hitTestDuration: Double

    init(payloadURL: URL) throws {
        totalTimer = AppTelemetryTimer()
        totalMemoryBefore = Self.residentMemoryBytes()
        payloadData = try Data(contentsOf: payloadURL)

        let decodeTimer = AppTelemetryTimer()
        let payload = try EngineGraphClient.decodeEnvelope(payloadData)
        decodeDuration = decodeTimer.elapsedMilliseconds()

        let layoutTimer = AppTelemetryTimer()
        layout = try GraphLayoutMapper.map(payload.snapshot, checkCancellation: {})
        layoutDuration = layoutTimer.elapsedMilliseconds()

        let hitTestTimer = AppTelemetryTimer()
        hitTestIndex = try GraphHitTestIndex(layout: layout, checkCancellation: {})
        hitTestDuration = hitTestTimer.elapsedMilliseconds()
    }

    func totalMemoryDelta() -> Int? {
        totalMemoryBefore.flatMap { start in
            Self.residentMemoryBytes().map { max(0, $0 - start) }
        }
    }

    static func panZoomSamples() -> [GraphViewport] {
        (0..<30).map { index in
            GraphViewport(
                panOffset: GraphPoint(
                    x: Double(index) * 13.0,
                    y: Double(index) * -7.0
                ),
                zoomScale: 0.72 + Double(index % 10) * 0.11
            )
        }
    }

    private static func residentMemoryBytes() -> Int? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<natural_t>.stride
        )
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

@MainActor
private func runWindowBenchmark<Content: View>(
    title: String,
    setup: GraphRendererBenchmarkSetup,
    driver: GraphRendererBenchmarkDriver,
    host: Content,
    rendererKind: GraphRendererKind
) throws -> GraphRendererBenchmarkResult {
    let hostingView = NSHostingView(rootView: host)
    hostingView.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
    let window = NSWindow(
        contentRect: hostingView.frame,
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    window.title = title
    window.contentView = hostingView
    window.center()

    driver.startFirstFrame()
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()

    let deadline = Date().addingTimeInterval(20)
    while !driver.isComplete && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    guard let result = driver.result(
        rendererKind: rendererKind,
        nodeCount: setup.layout.nodes.count,
        edgeCount: setup.layout.edges.count,
        encodedPayloadBytes: setup.payloadData.count,
        decodeDuration: setup.decodeDuration,
        layoutDuration: setup.layoutDuration,
        hitTestDuration: setup.hitTestDuration,
        totalMemoryDelta: setup.totalMemoryDelta()
    ) else {
        window.close()
        throw GraphRendererBenchmarkError.timeout
    }
    window.close()
    return result
}

private enum GraphRendererBenchmarkError: Error {
    case invalidResult
    case metalUnavailable
    case timeout
}

@MainActor
private final class GraphRendererBenchmarkDriver {
    private let totalTimer: AppTelemetryTimer
    private let samples: [GraphViewport]
    private var pendingFrameTimer: AppTelemetryTimer?
    private var frameDurations: [Double] = []
    private var drawDurations: [Double] = []
    private var totalFirstRenderDuration: Double?
    private var completed = false

    init(totalTimer: AppTelemetryTimer, samples: [GraphViewport]) {
        self.totalTimer = totalTimer
        self.samples = samples
    }

    var isComplete: Bool {
        completed
    }

    func startFirstFrame() {
        pendingFrameTimer = AppTelemetryTimer()
    }

    func recordDraw(
        _ metrics: GraphRendererMetrics,
        applyViewport: (GraphViewport) -> Void
    ) {
        guard !completed, let pendingFrameTimer else {
            return
        }

        frameDurations.append(pendingFrameTimer.elapsedMilliseconds())
        drawDurations.append(metrics.drawDurationMilliseconds)
        if totalFirstRenderDuration == nil {
            totalFirstRenderDuration = totalTimer.elapsedMilliseconds()
        }

        let nextSampleIndex = drawDurations.count - 1
        guard nextSampleIndex < samples.count else {
            completed = true
            self.pendingFrameTimer = nil
            return
        }

        self.pendingFrameTimer = AppTelemetryTimer()
        applyViewport(samples[nextSampleIndex])
    }

    func result(
        rendererKind: GraphRendererKind,
        nodeCount: Int,
        edgeCount: Int,
        encodedPayloadBytes: Int,
        decodeDuration: Double,
        layoutDuration: Double,
        hitTestDuration: Double,
        totalMemoryDelta: Int?
    ) -> GraphRendererBenchmarkResult? {
        guard completed,
              let firstFrameDuration = frameDurations.first,
              let firstDrawDuration = drawDurations.first,
              let totalFirstRenderDuration
        else {
            return nil
        }
        let interactionFrameDurations = Array(frameDurations.dropFirst())
        let interactionDrawDurations = Array(drawDurations.dropFirst())
        return GraphRendererBenchmarkResult(
            rendererKind: rendererKind.rawValue,
            nodeCount: nodeCount,
            edgeCount: edgeCount,
            encodedPayloadBytes: encodedPayloadBytes,
            decodeDurationMilliseconds: decodeDuration,
            layoutDurationMilliseconds: layoutDuration,
            hitTestIndexDurationMilliseconds: hitTestDuration,
            firstFrameDurationMilliseconds: firstFrameDuration,
            firstDrawDurationMilliseconds: firstDrawDuration,
            panZoomP95FrameDurationMilliseconds: percentile(0.95, values: interactionFrameDurations),
            panZoomP99FrameDurationMilliseconds: percentile(0.99, values: interactionFrameDurations),
            panZoomP95DrawDurationMilliseconds: percentile(0.95, values: interactionDrawDurations),
            panZoomP99DrawDurationMilliseconds: percentile(0.99, values: interactionDrawDurations),
            mainThreadStallMilliseconds: drawDurations.max() ?? 0,
            totalFirstRenderDurationMilliseconds: totalFirstRenderDuration,
            totalMemoryDeltaBytes: totalMemoryDelta,
            sampleCount: interactionFrameDurations.count
        )
    }

    private func percentile(_ percentile: Double, values: [Double]) -> Double {
        guard !values.isEmpty else {
            return 0
        }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * percentile).rounded(.up))
        return sorted[min(max(index, 0), sorted.count - 1)]
    }
}

private struct GraphCanvasBenchmarkHost: View {
    let layout: GraphRendererSnapshot
    let hitTestIndex: GraphHitTestIndex
    let driver: GraphRendererBenchmarkDriver

    @State private var viewport = GraphViewport()

    var body: some View {
        GraphCanvasRendererView(
            input: GraphRendererInput(
                layout: layout,
                presentation: GraphPresentationSettings(labelVisibility: .hidden)
            ),
            viewport: $viewport,
            callbacks: GraphRendererCallbacks(
                didCompleteDraw: { metrics in
                    DispatchQueue.main.async {
                        driver.recordDraw(metrics) { nextViewport in
                            viewport = nextViewport
                        }
                    }
                }
            ),
            hitTestIndex: hitTestIndex
        )
        .frame(width: 1440, height: 900)
    }
}

private struct GraphMetalBenchmarkHost: View {
    let layout: GraphRendererSnapshot
    let hitTestIndex: GraphHitTestIndex
    let driver: GraphRendererBenchmarkDriver

    @State private var viewport = GraphViewport()

    var body: some View {
        GraphMetalRendererView(
            input: GraphRendererInput(
                layout: layout,
                presentation: GraphPresentationSettings(labelVisibility: .hidden)
            ),
            viewport: $viewport,
            callbacks: GraphRendererCallbacks(
                didCompleteDraw: { metrics in
                    MainActor.assumeIsolated {
                        driver.recordDraw(metrics) { nextViewport in
                            viewport = nextViewport
                        }
                    }
                }
            ),
            hitTestIndex: hitTestIndex
        )
        .frame(width: 1440, height: 900)
    }
}
