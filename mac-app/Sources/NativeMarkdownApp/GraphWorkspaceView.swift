import Foundation
import NativeMarkdownCore
import SwiftUI

struct GraphWorkspaceView: View {
    @EnvironmentObject private var appState: AppState

    let vaultSelection: VaultSelectionState

    @State private var workspaceModel = GraphWorkspaceModel()
    @State private var settings = GraphSettings()
    @State private var interaction = GraphInteractionState(
        selectedNodeID: GraphCanvasRendererSmokeFixture.defaultSelectedNodeID
    )
    @State private var loadedLayout: GraphRendererSnapshot?
    @State private var loadedHitTestIndex: GraphHitTestIndex?
    @State private var graphBannerText: String?
    @State private var pendingFirstRender: PendingGraphFirstRender?
    @State private var nextGraphRequestID: UInt64 = 1
    @State private var searchText = ""
    @State private var showsSettings = false
    @State private var viewport = GraphViewport()
    @FocusState private var graphSurfaceFocused: Bool

    private let graphClient = EngineGraphClient()
    private let enablesParityControls = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                toolbar

                Divider()

                graphContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showsSettings {
                Divider()

                GraphSettingsPanel(
                    settings: $settings,
                    parityControlsEnabled: enablesParityControls
                )
                .frame(width: 280)
            }
        }
        .background(ObsidianUI.editorBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Graph view")
        .task(id: graphLoadKey) {
            await loadGraphIfNeeded()
        }
        .onDisappear {
            cancelPendingFirstRender()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            TextField("Search", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .accessibilityLabel("Graph search")

            Spacer()

            ObsidianIconButton(
                systemName: "minus.magnifyingglass",
                accessibilityLabel: "Zoom out graph"
            ) {
                zoom(by: 0.85)
            }

            ObsidianIconButton(
                systemName: "plus.magnifyingglass",
                accessibilityLabel: "Zoom in graph"
            ) {
                zoom(by: 1.15)
            }

            ObsidianIconButton(
                systemName: "arrow.counterclockwise",
                accessibilityLabel: "Reset graph view"
            ) {
                viewport.reset()
            }

            ObsidianIconButton(
                systemName: "slider.horizontal.3",
                accessibilityLabel: "Graph settings",
                isSelected: showsSettings
            ) {
                showsSettings.toggle()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: ObsidianUI.noteToolbarHeight)
        .background(ObsidianUI.editorBackground)
    }

    @ViewBuilder
    private var graphContent: some View {
        switch vaultSelection {
        case .selected:
            if let loadedLayout, let loadedHitTestIndex {
                switch validatedRendererInput(layout: loadedLayout) {
                case .ready(let input):
                    VStack(spacing: 0) {
                        if let graphBannerText {
                            GraphStateBanner(text: graphBannerText)

                            Divider()
                        }

                        GraphCanvasRendererView(
                            input: input,
                            viewport: $viewport,
                            callbacks: GraphRendererCallbacks(
                                didCompleteFirstDraw: { metrics in
                                    Task { @MainActor in
                                        handleFirstDraw(
                                            metrics,
                                            requestID: input.layout.requestID
                                        )
                                    }
                                }
                            ),
                            hitTestIndex: loadedHitTestIndex,
                            onHoverNode: { nodeID in
                                interaction.hover(nodeID)
                            },
                            onSelectNode: { nodeID in
                                interaction.select(nodeID)
                            },
                            onOpenNode: { nodeID in
                                openNode(nodeID, in: input)
                            }
                        )
                        .focused($graphSurfaceFocused)
                        .onAppear {
                            graphSurfaceFocused = true
                            workspaceModel.applyStableGraph(GraphStableGraphSummary(
                                generation: input.layout.generation,
                                nodeCount: input.layout.nodes.count,
                                edgeCount: input.layout.edges.count
                            ))
                        }
                        .onMoveCommand { direction in
                            panGraph(direction)
                        }
                        .onKeyPress(.return) {
                            openSelectedNode(in: input)
                        }
                        .onKeyPress("+") {
                            zoom(by: 1.15)
                            return .handled
                        }
                        .onKeyPress("-") {
                            zoom(by: 0.85)
                            return .handled
                        }
                        .onExitCommand {
                            interaction.hover(nil)
                            interaction.clearSelection()
                        }

                        if showsKeyboardResults(for: input) {
                            Divider()

                            GraphKeyboardResultsList(
                                nodes: keyboardResultNodes(for: input),
                                searchIsActive: searchIsActive,
                                selectedNodeID: interaction.selectedNodeID,
                                selectNode: { nodeID in
                                    interaction.select(nodeID)
                                },
                                openNode: { nodeID in
                                    openNode(nodeID, in: input)
                                }
                            )
                        }
                    }
                case .failed(let error):
                    rendererFailureView(error)
                        .onAppear {
                            workspaceModel.fail(.rendererFailed)
                        }
                }
            } else {
                graphStatusPlaceholder(
                    title: graphStatusTitle,
                    detail: graphStatusDetail
                )
            }
        case .noVault:
            graphStatusPlaceholder(title: "Graph view", detail: "No vault open")
        case .unavailable(let issue):
            graphStatusPlaceholder(title: "Graph view", detail: issue.displayTitle)
        }
    }

    private func rendererFailureView(_ error: GraphRendererValidationError) -> some View {
        graphStatusPlaceholder(
            title: "Graph renderer failed",
            detail: rendererFailureText(error)
        )
    }

    private func graphStatusPlaceholder(title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3)
                .foregroundStyle(.primary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Graph view")
    }

    private func validatedRendererInput(layout: GraphRendererSnapshot) -> RendererInputState {
        let input = GraphRendererInput(
            layout: layout,
            viewport: viewport,
            presentation: settings.presentation,
            hoveredNodeID: interaction.hoveredNodeID,
            selectedNodeID: interaction.selectedNodeID,
            searchMatchedNodeIDs: GraphSearchMatcher.matchingNodeIDs(
                in: layout,
                query: searchText
            )
        )

        do {
            try input.validate()
            return .ready(input)
        } catch let error as GraphRendererValidationError {
            return .failed(error)
        } catch {
            return .failed(.edgeEndpointOutOfBounds)
        }
    }

    @MainActor
    private func loadGraphIfNeeded() async {
        guard case .selected = vaultSelection else {
            cancelPendingFirstRender()
            loadedLayout = nil
            loadedHitTestIndex = nil
            graphBannerText = nil
            workspaceModel.clear(.noVault)
            return
        }

        guard let metadataURL = appState.indexLocation?.metadataFile,
              FileManager.default.fileExists(atPath: metadataURL.path)
        else {
            cancelPendingFirstRender()
            loadedLayout = nil
            loadedHitTestIndex = nil
            graphBannerText = nil
            workspaceModel.clear(.missingIndex)
            return
        }

        cancelPendingFirstRender()
        let requestID = nextGraphRequestID
        nextGraphRequestID += 1
        let totalTimer = AppTelemetryTimer()
        let loadTimer = AppTelemetryTimer()
        let request = WholeVaultGraphRequest(
            requestID: requestID,
            includeUnresolved: settings.semantic.includeUnresolved,
            includeOrphans: settings.semantic.includeOrphans
        )
        let totalSignpost = AppTelemetry.beginGraphStage(.totalFirstRender)
        var shouldEndTotalSignpost = true
        defer {
            if shouldEndTotalSignpost {
                AppTelemetry.endGraphStage(totalSignpost)
            }
        }

        workspaceModel.beginRecompute()
        if loadedLayout != nil {
            graphBannerText = "Refreshing graph"
        }

        do {
            let payload = try await graphClient.loadSnapshot(
                metadataURL: metadataURL,
                request: request
            )
            let clientDuration = loadTimer.elapsedMilliseconds()
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
                durationMilliseconds: max(
                    0,
                    clientDuration - payload.metrics.snapshotDurationMilliseconds
                )
            )

            let preparedGraph = try await prepareGraphLayout(from: payload.snapshot)
            let layout = preparedGraph.layout
            AppTelemetry.graphStageCompleted(
                stage: .layout,
                state: payload.state.telemetryState,
                nodeCount: layout.nodes.count,
                edgeCount: layout.edges.count,
                durationMilliseconds: preparedGraph.layoutDurationMilliseconds
            )
            try Task.checkCancellation()

            loadedLayout = layout
            loadedHitTestIndex = preparedGraph.hitTestIndex
            let stableGraph = GraphStableGraphSummary(
                generation: layout.generation,
                nodeCount: layout.nodes.count,
                edgeCount: layout.edges.count
            )
            if let selectedNodeID = interaction.selectedNodeID,
               !layout.nodes.contains(where: { $0.nodeID == selectedNodeID }) {
                interaction.select(nil)
            }
            workspaceModel.applyStableGraph(stableGraph)
            if payload.state == .partial {
                workspaceModel.markPartial()
                graphBannerText = partialBannerText(for: payload)
            } else {
                graphBannerText = nil
            }
            pendingFirstRender = PendingGraphFirstRender(
                requestID: layout.requestID,
                timer: totalTimer,
                signpost: totalSignpost,
                state: payload.state.telemetryState,
                nodeCount: layout.nodes.count,
                edgeCount: layout.edges.count
            )
            shouldEndTotalSignpost = false
        } catch is CancellationError {
            workspaceModel.fail(.cancelled)
            if loadedLayout != nil {
                graphBannerText = "Graph refresh cancelled; showing previous graph"
            }
        } catch let error as EngineGraphClientError {
            handleGraphLoadFailure(error)
        } catch is WholeVaultGraphValidationError {
            workspaceModel.fail(.decodeFailed)
            if loadedLayout != nil {
                graphBannerText = "Graph refresh failed; showing previous graph"
            }
        } catch {
            workspaceModel.fail(.snapshotFailed)
            if loadedLayout != nil {
                graphBannerText = "Graph refresh failed; showing previous graph"
            }
        }
    }

    private func prepareGraphLayout(
        from snapshot: WholeVaultGraphSnapshot
    ) async throws -> PreparedGraphLayout {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let layoutTimer = AppTelemetryTimer()
            let layoutSignpost = AppTelemetry.beginGraphStage(.layout)
            let layout: GraphRendererSnapshot
            let hitTestIndex: GraphHitTestIndex
            do {
                layout = try GraphLayoutMapper.map(
                    snapshot,
                    checkCancellation: Task.checkCancellation
                )
                hitTestIndex = try GraphHitTestIndex(
                    layout: layout,
                    checkCancellation: Task.checkCancellation
                )
                AppTelemetry.endGraphStage(layoutSignpost)
            } catch {
                AppTelemetry.endGraphStage(layoutSignpost)
                throw error
            }
            try Task.checkCancellation()
            return PreparedGraphLayout(
                layout: layout,
                hitTestIndex: hitTestIndex,
                layoutDurationMilliseconds: layoutTimer.elapsedMilliseconds()
            )
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    @MainActor
    private func handleFirstDraw(_ metrics: GraphRendererMetrics, requestID: UInt64) {
        let state = pendingFirstRender?.state ?? currentTelemetryState
        AppTelemetry.graphDrawCompleted(metrics)
        AppTelemetry.graphStageCompleted(
            stage: .draw,
            state: state,
            nodeCount: metrics.nodeCount,
            edgeCount: metrics.edgeCount,
            durationMilliseconds: metrics.drawDurationMilliseconds
        )

        guard let pending = pendingFirstRender else {
            return
        }
        guard pending.requestID == requestID else {
            return
        }

        AppTelemetry.graphStageCompleted(
            stage: .totalFirstRender,
            state: pending.state,
            nodeCount: pending.nodeCount,
            edgeCount: pending.edgeCount,
            durationMilliseconds: pending.timer.elapsedMilliseconds()
        )
        AppTelemetry.endGraphStage(pending.signpost)
        pendingFirstRender = nil
    }

    @MainActor
    private func cancelPendingFirstRender() {
        guard let pending = pendingFirstRender else {
            return
        }

        AppTelemetry.endGraphStage(pending.signpost)
        pendingFirstRender = nil
    }

    private func zoom(by multiplier: Double) {
        viewport.zoomScale *= multiplier
    }

    private func panGraph(_ direction: MoveCommandDirection) {
        guard graphSurfaceFocused else {
            return
        }

        let amount = 40.0
        switch direction {
        case .up:
            viewport.panOffset.y += amount
        case .down:
            viewport.panOffset.y -= amount
        case .left:
            viewport.panOffset.x += amount
        case .right:
            viewport.panOffset.x -= amount
        default:
            break
        }
    }

    private func openSelectedNode(in input: GraphRendererInput) -> KeyPress.Result {
        guard graphSurfaceFocused,
              let selectedNodeID = interaction.selectedNodeID
        else {
            return .ignored
        }
        openNode(selectedNodeID, in: input)
        return .handled
    }

    private func openNode(_ nodeID: String, in input: GraphRendererInput) {
        guard let node = input.layout.nodes.first(where: { $0.nodeID == nodeID }) else {
            return
        }

        interaction.select(nodeID)
        guard let file = GraphNodeOpenResolver.file(for: node) else {
            return
        }

        _ = appState.openFile(file)
    }

    private var searchIsActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func showsKeyboardResults(for input: GraphRendererInput) -> Bool {
        searchIsActive || input.selectedNodeID != nil
    }

    private func keyboardResultNodes(for input: GraphRendererInput) -> [GraphLayoutNode] {
        if searchIsActive {
            return input.layout.nodes
                .filter { input.searchMatchedNodeIDs.contains($0.nodeID) }
                .prefix(8)
                .map { $0 }
        }

        guard let selectedNodeID = input.selectedNodeID,
              let selectedNode = input.layout.nodes.first(where: { $0.nodeID == selectedNodeID })
        else {
            return []
        }
        return [selectedNode]
    }

    private func rendererFailureText(_ error: GraphRendererValidationError) -> String {
        switch error {
        case .edgeEndpointOutOfBounds:
            return "Graph edge endpoints are invalid"
        }
    }

    private var graphLoadKey: String {
        switch vaultSelection {
        case .selected:
            let metadataPath = appState.indexLocation?.metadataFile.path ?? "missing-index"
            return [
                metadataPath,
                settings.semantic.includeUnresolved.description,
                settings.semantic.includeOrphans.description
            ].joined(separator: "|")
        case .noVault:
            return "no-vault"
        case .unavailable(let issue):
            return "unavailable|\(issue.displayTitle)"
        }
    }

    private var graphStatusTitle: String {
        switch workspaceModel.state {
        case .building:
            return "Loading graph"
        case .missingIndex:
            return "Graph index unavailable"
        case .snapshotFailed, .decodeFailed, .layoutFailed:
            return "Graph load failed"
        case .cancelled:
            return "Graph load cancelled"
        default:
            return "Graph view"
        }
    }

    private var graphStatusDetail: String {
        switch workspaceModel.state {
        case .building:
            return "Loading indexed graph data"
        case .missingIndex:
            return "Graph index is not ready"
        case .snapshotFailed:
            return "Snapshot could not be loaded"
        case .decodeFailed:
            return "Snapshot response could not be decoded"
        case .layoutFailed:
            return "Graph layout could not be prepared"
        case .cancelled:
            return "Graph request was cancelled"
        default:
            return "Graph data not loaded"
        }
    }

    private func handleGraphLoadFailure(_ error: EngineGraphClientError) {
        switch error {
        case .invalidResponse:
            workspaceModel.fail(.decodeFailed)
        case .engine(let payload) where payload.code == "missing_index":
            workspaceModel.clear(.missingIndex)
            loadedLayout = nil
            loadedHitTestIndex = nil
            graphBannerText = nil
            return
        default:
            workspaceModel.fail(.snapshotFailed)
        }

        if loadedLayout != nil {
            graphBannerText = "Graph refresh failed; showing previous graph"
        }
    }

    private func partialBannerText(for payload: WholeVaultGraphPayload) -> String {
        let reasons = payload.snapshot.partialReasons
            .map(\.rawValue)
            .sorted()
            .joined(separator: ", ")
        return reasons.isEmpty ? "Partial graph" : "Partial graph: \(reasons)"
    }

    private var currentTelemetryState: SearchResultState {
        workspaceModel.state == .partial ? .partial : .complete
    }

    private enum RendererInputState {
        case ready(GraphRendererInput)
        case failed(GraphRendererValidationError)
    }
}

private struct PreparedGraphLayout: Sendable {
    let layout: GraphRendererSnapshot
    let hitTestIndex: GraphHitTestIndex
    let layoutDurationMilliseconds: Double
}

private struct PendingGraphFirstRender {
    let requestID: UInt64
    let timer: AppTelemetryTimer
    let signpost: GraphStageSignpostInterval
    let state: SearchResultState
    let nodeCount: Int
    let edgeCount: Int
}

private struct GraphKeyboardResultsList: View {
    let nodes: [GraphLayoutNode]
    let searchIsActive: Bool
    let selectedNodeID: String?
    let selectNode: (String) -> Void
    let openNode: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(searchIsActive ? "Graph results" : "Selected node")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if nodes.isEmpty {
                Text("No graph matches")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(nodes, id: \.nodeID) { node in
                    Button {
                        selectNode(node.nodeID)
                        openNode(node.nodeID)
                    } label: {
                        Text(node.label)
                            .lineLimit(1)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .accessibilityLabel(resultAccessibilityLabel(for: node))
                }
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(ObsidianUI.sidebarBackground.opacity(0.65))
    }

    private func resultAccessibilityLabel(for node: GraphLayoutNode) -> String {
        selectedNodeID == node.nodeID ? "Selected graph node \(node.label)" : "Graph node \(node.label)"
    }
}

private struct GraphStateBanner: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(ObsidianUI.sidebarBackground.opacity(0.65))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

private struct GraphSettingsPanel: View {
    @Binding var settings: GraphSettings
    let parityControlsEnabled: Bool

    private var includeUnresolved: Binding<Bool> {
        Binding {
            settings.semantic.includeUnresolved
        } set: { newValue in
            guard parityControlsEnabled else {
                return
            }
            settings.semantic.includeUnresolved = newValue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Graph settings")
                .font(.headline)

            Toggle("Unresolved links", isOn: includeUnresolved)
                .disabled(!parityControlsEnabled)

            Toggle("Orphans", isOn: $settings.semantic.includeOrphans)
                .disabled(!parityControlsEnabled)

            Picker("Labels", selection: $settings.presentation.labelVisibility) {
                Text("Automatic").tag(GraphLabelVisibility.automatic)
                Text("Always").tag(GraphLabelVisibility.always)
                Text("Hidden").tag(GraphLabelVisibility.hidden)
            }
            .pickerStyle(.menu)

            Toggle("Arrows", isOn: $settings.presentation.showArrows)

            Spacer()
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(ObsidianUI.sidebarBackground)
    }
}
