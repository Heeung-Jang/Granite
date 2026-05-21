import Darwin
import Foundation
import NativeMarkdownCore

struct GraphPayloadBenchmarkResult: Codable {
    let nodeCount: Int
    let edgeCount: Int
    let encodedPayloadBytes: Int
    let decodeDurationMilliseconds: Double
    let decodeMemoryDeltaBytes: Int?
    let layoutDurationMilliseconds: Double
    let layoutMemoryDeltaBytes: Int?
    let hitTestIndexDurationMilliseconds: Double
    let firstDrawDurationMilliseconds: Double
    let panZoomP95DurationMilliseconds: Double
    let panZoomP99DurationMilliseconds: Double
    let mainThreadStallMilliseconds: Double
    let totalFirstRenderDurationMilliseconds: Double
    let totalMemoryDeltaBytes: Int?
}

enum GraphPayloadBenchmarkProbe {
    static func run(payloadURL: URL) throws -> GraphPayloadBenchmarkResult {
        let payloadData = try Data(contentsOf: payloadURL)
        let totalMemoryBefore = residentMemoryBytes()
        let totalTimer = AppTelemetryTimer()
        let decodeMemoryBefore = residentMemoryBytes()
        let decodeTimer = AppTelemetryTimer()
        let payload = try EngineGraphClient.decodeEnvelope(payloadData)
        let decodeDuration = decodeTimer.elapsedMilliseconds()
        let decodeMemoryDelta = memoryDelta(from: decodeMemoryBefore)

        let layoutMemoryBefore = residentMemoryBytes()
        let layoutTimer = AppTelemetryTimer()
        let layout = try GraphLayoutMapper.map(
            payload.snapshot,
            checkCancellation: Task.checkCancellation
        )
        let layoutDuration = layoutTimer.elapsedMilliseconds()
        let layoutMemoryDelta = memoryDelta(from: layoutMemoryBefore)

        let hitTestTimer = AppTelemetryTimer()
        _ = try GraphHitTestIndex(
            layout: layout,
            checkCancellation: Task.checkCancellation
        )
        let hitTestDuration = hitTestTimer.elapsedMilliseconds()

        let input = GraphRendererInput(layout: layout)
        let firstDrawDuration = measureCanvasCPUProxy(input: input)
        let panZoomDurations = panZoomSamples(for: layout)
        let totalDuration = totalTimer.elapsedMilliseconds()

        return GraphPayloadBenchmarkResult(
            nodeCount: layout.nodes.count,
            edgeCount: layout.edges.count,
            encodedPayloadBytes: payloadData.count,
            decodeDurationMilliseconds: decodeDuration,
            decodeMemoryDeltaBytes: decodeMemoryDelta,
            layoutDurationMilliseconds: layoutDuration,
            layoutMemoryDeltaBytes: layoutMemoryDelta,
            hitTestIndexDurationMilliseconds: hitTestDuration,
            firstDrawDurationMilliseconds: firstDrawDuration,
            panZoomP95DurationMilliseconds: percentile(0.95, values: panZoomDurations),
            panZoomP99DurationMilliseconds: percentile(0.99, values: panZoomDurations),
            mainThreadStallMilliseconds: max(firstDrawDuration, panZoomDurations.max() ?? 0),
            totalFirstRenderDurationMilliseconds: totalDuration,
            totalMemoryDeltaBytes: memoryDelta(from: totalMemoryBefore)
        )
    }

    static func encodedResult(payloadURL: URL) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let result = try run(payloadURL: payloadURL)
        let data = try encoder.encode(result)
        guard let json = String(data: data, encoding: .utf8) else {
            throw GraphPayloadBenchmarkError.invalidPayload
        }
        return json
    }

    private static func panZoomSamples(for layout: GraphRendererSnapshot) -> [Double] {
        (0..<30).map { index in
            let zoom = 0.7 + Double(index % 10) * 0.12
            let pan = Double(index) * 11.0
            return measureCanvasCPUProxy(input: GraphRendererInput(
                layout: layout,
                viewport: GraphViewport(
                    panOffset: GraphPoint(x: pan, y: -pan / 2),
                    zoomScale: zoom
                )
            ))
        }
    }

    private static func measureCanvasCPUProxy(input: GraphRendererInput) -> Double {
        let timer = AppTelemetryTimer()
        var checksum = 0.0

        for edge in input.layout.edges {
            let source = input.layout.nodes[edge.sourceIndex]
            let target = input.layout.nodes[edge.targetIndex]
            let sourcePoint = input.viewport.screenPoint(for: source.position)
            let targetPoint = input.viewport.screenPoint(for: target.position)
            checksum += abs(sourcePoint.x - targetPoint.x)
            checksum += abs(sourcePoint.y - targetPoint.y)
            checksum += Double(edge.weight)
        }

        for node in input.layout.nodes {
            let point = input.viewport.screenPoint(for: node.position)
            checksum += point.x * 0.000_001
            checksum += point.y * 0.000_001
            checksum += node.radius
            if GraphLabelVisibilityPolicy.isVisible(
                nodeID: node.nodeID,
                settings: input.presentation,
                context: GraphLabelVisibilityContext(
                    hoveredNodeID: input.hoveredNodeID,
                    selectedNodeID: input.selectedNodeID,
                    searchMatchedNodeIDs: input.searchMatchedNodeIDs,
                    zoomScale: input.viewport.zoomScale
                )
            ) {
                checksum += Double(node.label.utf8.count)
            }
        }

        if checksum == -.greatestFiniteMagnitude {
            fputs("", stderr)
        }
        return timer.elapsedMilliseconds()
    }

    private static func percentile(_ percentile: Double, values: [Double]) -> Double {
        guard !values.isEmpty else {
            return 0
        }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * percentile).rounded(.up))
        return sorted[min(max(index, 0), sorted.count - 1)]
    }

    private static func memoryDelta(from before: Int?) -> Int? {
        before.flatMap { start in
            residentMemoryBytes().map { max(0, $0 - start) }
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

private enum GraphPayloadBenchmarkError: Error {
    case invalidPayload
}
