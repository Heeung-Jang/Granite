import Foundation
import NativeMarkdownCore

enum GraphLoadSmokeProbe {
    static func run() throws -> GraphRendererMetrics {
        let totalTimer = AppTelemetryTimer()
        let totalSignpost = AppTelemetry.beginGraphStage(.totalFirstRender)
        defer {
            AppTelemetry.endGraphStage(totalSignpost)
        }
        let decodeTimer = AppTelemetryTimer()
        let decodeSignpost = AppTelemetry.beginGraphStage(.decode)
        let payload: WholeVaultGraphPayload
        do {
            payload = try EngineGraphClient.decodeEnvelope(fixtureEnvelope)
            AppTelemetry.endGraphStage(decodeSignpost)
        } catch {
            AppTelemetry.endGraphStage(decodeSignpost)
            throw error
        }
        let decodeDuration = decodeTimer.elapsedMilliseconds()

        AppTelemetry.graphStageCompleted(
            stage: .snapshot,
            state: payload.state.telemetryState,
            nodeCount: payload.snapshot.nodeCountTotal,
            edgeCount: payload.snapshot.edgeCountTotal,
            durationMilliseconds: payload.metrics.snapshotDurationMilliseconds
        )
        AppTelemetry.graphStageCompleted(
            stage: .decode,
            state: payload.state.telemetryState,
            nodeCount: payload.snapshot.nodes.count,
            edgeCount: payload.snapshot.edges.count,
            durationMilliseconds: decodeDuration
        )

        let layoutTimer = AppTelemetryTimer()
        let layoutSignpost = AppTelemetry.beginGraphStage(.layout)
        let layout = GraphLayoutMapper.map(payload.snapshot)
        AppTelemetry.endGraphStage(layoutSignpost)
        AppTelemetry.graphStageCompleted(
            stage: .layout,
            state: payload.state.telemetryState,
            nodeCount: layout.nodes.count,
            edgeCount: layout.edges.count,
            durationMilliseconds: layoutTimer.elapsedMilliseconds()
        )

        let metrics = GraphRendererMetrics(
            rendererKind: .canvas,
            nodeCount: layout.nodes.count,
            edgeCount: layout.edges.count,
            drawDurationMilliseconds: 0
        )
        let drawSignpost = AppTelemetry.beginGraphStage(.draw)
        AppTelemetry.graphDrawCompleted(metrics)
        AppTelemetry.endGraphStage(drawSignpost)
        AppTelemetry.graphStageCompleted(
            stage: .draw,
            state: payload.state.telemetryState,
            nodeCount: layout.nodes.count,
            edgeCount: layout.edges.count,
            durationMilliseconds: metrics.drawDurationMilliseconds
        )
        AppTelemetry.graphStageCompleted(
            stage: .totalFirstRender,
            state: payload.state.telemetryState,
            nodeCount: layout.nodes.count,
            edgeCount: layout.edges.count,
            durationMilliseconds: totalTimer.elapsedMilliseconds()
        )

        guard metrics.nodeCount == 2, metrics.edgeCount == 1 else {
            throw GraphLoadSmokeError.unexpectedCounts
        }
        return metrics
    }

    private static let fixtureEnvelope = """
    {"ok":true,"value":{"payload_version":1,"request_id":91,"generation":1,"state":"complete","metrics":{"snapshot_duration_milliseconds":1.0,"encoded_payload_bytes":512},"snapshot":{"request_id":91,"generation":1,"partial_reasons":[],"node_count_total":2,"edge_count_total":1,"nodes":[{"node_id":"file:home","file_id":"home.md","relative_path":"Home.md","label":"Home","kind":"Resolved","degree":1,"tags":[]},{"node_id":"file:target","file_id":"target.md","relative_path":"Folder/Target.md","label":"Target","kind":"Resolved","degree":1,"tags":[]}],"edges":[{"source_node_id":"file:home","target_node_id":"file:target","kind":"Resolved","weight":1}]}},"error":null}
    """
}

private enum GraphLoadSmokeError: Error {
    case unexpectedCounts
}
