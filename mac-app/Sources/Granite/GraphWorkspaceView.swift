import Foundation
import NativeMarkdownCore
import SwiftUI

struct GraphWorkspaceView: View {
    @EnvironmentObject private var appState: AppState

    let vaultSelection: VaultSelectionState

    @State private var workspaceModel = GraphWorkspaceModel()
    @State private var settings = GraphSettings()
    @State private var interaction = GraphInteractionState()
    @State private var loadedLayout: GraphRendererSnapshot?
    @State private var loadedHitTestIndex: GraphHitTestIndex?
    @State private var graphBannerText: String?
    @State private var pendingFirstRender: PendingGraphFirstRender?
    @State private var forceRefinementTask: Task<Void, Never>?
    @State private var nextGraphRequestID: UInt64 = 1
    @State private var showsSearch = false
    @State private var showsSettings = false
    @State private var viewport = GraphViewport()
    @State private var viewportFitState = GraphViewportFitState()
    @State private var graphCanvasSize: GraphSize?
    @FocusState private var graphSurfaceFocused: Bool

    private let graphClient = EngineGraphClient()
    private let enablesParityControls = true
    private let graphViewTitle = "그래프 뷰"

    var body: some View {
        ZStack(alignment: .topTrailing) {
            graphContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showsSettings {
                GraphSettingsPanel(
                    settings: $settings,
                    parityControlsEnabled: enablesParityControls
                )
                .frame(width: 280)
                .padding(.top, 52)
                .padding(.trailing, 52)
            }
        }
        .background(ObsidianUI.editorBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(graphViewTitle)
        .focusedSceneValue(\.graphCommandActions, graphCommandActions)
        .task(id: graphLoadKey) {
            await loadGraphIfNeeded()
        }
        .onDisappear {
            cancelPendingFirstRender()
            cancelForceRefinement()
        }
    }

    private var graphCommandActions: GraphCommandActions {
        GraphCommandActions(
            resetView: resetViewportToFit,
            zoomIn: { zoom(by: 1.15) },
            zoomOut: { zoom(by: 0.85) },
            clearSelection: clearGraphSelection,
            openSelectedNode: openSelectedGraphNodeFromCommand,
            toggleControls: { showsSettings.toggle() },
            canOpenSelectedNode: interaction.selectedNodeID != nil
        )
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

                        GeometryReader { proxy in
                            ZStack(alignment: .top) {
                                GraphRendererSurfaceView(
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
                                    interactionCallbacks: graphInteractionCallbacks(input: input),
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
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .focused($graphSurfaceFocused)
                                .onAppear {
                                    graphSurfaceFocused = true
                                    workspaceModel.applyStableGraph(GraphStableGraphSummary(
                                        generation: input.layout.generation,
                                        nodeCount: input.layout.nodes.count,
                                        edgeCount: input.layout.edges.count
                                    ))
                                    updateGraphCanvasSize(proxy.size, layout: input.layout)
                                }
                                .onChange(of: proxy.size) { _, newSize in
                                    updateGraphCanvasSize(newSize, layout: input.layout)
                                }
                                .onChange(of: input.layout.requestID) { _, _ in
                                    updateGraphCanvasSize(proxy.size, layout: input.layout)
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
                                    clearGraphSelection()
                                }

                                GraphCanvasHeader(
                                    title: graphViewTitle
                                )

                                if showsSearch {
                                    GraphSearchOverlay(
                                        searchQuery: $settings.searchQuery,
                                        close: closeGraphSearch
                                    )
                                    .position(x: min(154, max(130, proxy.size.width / 2)), y: 24)
                                }

                                GraphFloatingControlStack(
                                    searchIsPresented: showsSearch || searchIsActive,
                                    searchAccessibilityLabel: showsSearch ? "Close graph search" : "Search graph",
                                    searchAccessibilityHint: showsSearch
                                        ? "Closes the graph search field"
                                        : (searchIsActive ? "Opens the active graph search field" : "Opens the graph search field"),
                                    searchAccessibilityValue: searchIsActive
                                        ? "Active query"
                                        : (showsSearch ? "Search field open" : "Inactive"),
                                    settingsIsPresented: showsSettings,
                                    toggleSearch: toggleGraphSearch,
                                    zoomOut: { zoom(by: 0.85) },
                                    zoomIn: { zoom(by: 1.15) },
                                    resetView: resetViewportToFit,
                                    toggleSettings: { showsSettings.toggle() }
                                )
                                .position(
                                    x: max(15, proxy.size.width - 29),
                                    y: GraphFloatingControlStack.centerY
                                )
                            }
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
            graphStatusPlaceholder(title: graphViewTitle, detail: "No vault open")
        case .unavailable(let issue):
            graphStatusPlaceholder(title: graphViewTitle, detail: issue.displayTitle)
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
        .accessibilityLabel(graphViewTitle)
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
                query: settings.searchQuery
            ),
            groupColorHexByNodeID: GraphGroupMatcher.groupColorHexByNodeID(
                in: layout,
                rules: settings.groupRules
            ),
            positionOverrides: activePositionOverrides
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
            graphCanvasSize = nil
            viewportFitState.invalidate()
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
            graphCanvasSize = nil
            viewportFitState.invalidate()
            workspaceModel.clear(.missingIndex)
            return
        }

        cancelPendingFirstRender()
        cancelForceRefinement()
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

            viewportFitState.invalidate()
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
        scheduleForceRefinement(requestID: requestID)
    }

    @MainActor
    private func cancelPendingFirstRender() {
        guard let pending = pendingFirstRender else {
            return
        }

        AppTelemetry.endGraphStage(pending.signpost)
        pendingFirstRender = nil
    }

    @MainActor
    private func scheduleForceRefinement(requestID: UInt64) {
        let force = settings.presentation.force
        guard force.isEnabled,
              let layout = loadedLayout,
              layout.requestID == requestID
        else {
            return
        }

        cancelForceRefinement()
        forceRefinementTask = Task {
            let baseRenderIdentity = layout.renderIdentity
            do {
                let refined = try await Task.detached(priority: .utility) {
                    try GraphForceRefinement.refined(
                        layout,
                        settings: force,
                        checkCancellation: Task.checkCancellation
                    )
                }.value
                try Task.checkCancellation()
                let hitTestIndex = try await Task.detached(priority: .utility) {
                    try GraphHitTestIndex(
                        layout: refined,
                        checkCancellation: Task.checkCancellation
                    )
                }.value
                try Task.checkCancellation()
                await MainActor.run {
                    guard loadedLayout?.requestID == requestID,
                          loadedLayout?.renderIdentity == baseRenderIdentity
                    else {
                        return
                    }
                    loadedLayout = refined
                    loadedHitTestIndex = hitTestIndex
                }
            } catch {
                return
            }
        }
    }

    @MainActor
    private func cancelForceRefinement() {
        forceRefinementTask?.cancel()
        forceRefinementTask = nil
    }

    private func updateGraphCanvasSize(_ size: CGSize, layout: GraphRendererSnapshot) {
        let canvasSize = GraphSize(width: Double(size.width), height: Double(size.height))
        guard canvasSize.width.isFinite,
              canvasSize.height.isFinite,
              canvasSize.width > 0,
              canvasSize.height > 0
        else {
            return
        }

        if graphCanvasSize != canvasSize {
            graphCanvasSize = canvasSize
        }
        if let fitViewport = viewportFitState.initialFitViewport(
            layout: layout,
            canvasSize: canvasSize
        ) {
            viewport = fitViewport
        }
    }

    private func resetViewportToFit() {
        guard let loadedLayout,
              let graphCanvasSize
        else {
            viewport.reset()
            return
        }

        viewport = viewportFitState.resetViewport(
            layout: loadedLayout,
            canvasSize: graphCanvasSize
        )
    }

    private func zoom(by multiplier: Double) {
        viewport.zoomScale *= multiplier
    }

    private func toggleGraphSearch() {
        if showsSearch {
            closeGraphSearch()
        } else {
            showsSearch = true
        }
    }

    private func closeGraphSearch() {
        showsSearch = false
        Task { @MainActor in
            await Task.yield()
            graphSurfaceFocused = true
        }
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

    private func openSelectedGraphNodeFromCommand() {
        guard let loadedLayout,
              let selectedNodeID = interaction.selectedNodeID,
              case .ready(let input) = validatedRendererInput(layout: loadedLayout)
        else {
            return
        }
        openNode(selectedNodeID, in: input)
    }

    private func graphInteractionCallbacks(input: GraphRendererInput) -> GraphRendererInteractionCallbacks {
        GraphRendererInteractionCallbacks(
            beginNodeDrag: { start in
                cancelForceRefinement()
                interaction.beginDrag(
                    nodeID: start.nodeID,
                    nodePosition: start.nodePosition,
                    pointerGraphPoint: start.pointerGraphPoint,
                    graphMovementThreshold: start.graphMovementThreshold
                )
                interaction.select(start.nodeID)
            },
            updateNodeDrag: { pointerGraphPoint in
                interaction.updateDrag(to: pointerGraphPoint)
            },
            endNodeDrag: {
                guard let result = interaction.finishDrag() else {
                    return
                }
                switch GraphGestureDecision.completion(for: result) {
                case .tap(let nodeID):
                    interaction.select(nodeID)
                    openNode(nodeID, in: input)
                case .drag(let result):
                    commitDraggedNode(result)
                    break
                }
            }
        )
    }

    private var activePositionOverrides: GraphNodePositionOverrides {
        var overrides = GraphNodePositionOverrides()
        if let dragState = interaction.dragState {
            overrides.set(dragState.currentNodePosition, for: dragState.nodeID)
        }
        return overrides
    }

    private func commitDraggedNode(_ result: GraphNodeDragResult) {
        guard result.movedBeyondThreshold,
              let hitTestIndex = loadedHitTestIndex
        else {
            return
        }

        let movedHitTestIndex = hitTestIndex.movingNode(
            nodeID: result.nodeID,
            to: result.nodePosition
        )
        guard movedHitTestIndex != hitTestIndex else {
            return
        }
        loadedLayout = movedHitTestIndex.layout
        loadedHitTestIndex = movedHitTestIndex
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

    private func clearGraphSelection() {
        interaction.hover(nil)
        interaction.clearSelection()
    }

    private var searchIsActive: Bool {
        !settings.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            return graphViewTitle
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
            graphCanvasSize = nil
            viewportFitState.invalidate()
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

private struct GraphCanvasHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(height: 32)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct GraphSearchOverlay: View {
    @Binding var searchQuery: String
    let close: () -> Void

    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            TextField("Search", text: $searchQuery)
                .textFieldStyle(.plain)
                .focused($searchFieldFocused)
                .accessibilityLabel("Graph search")

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear graph search")
                .accessibilityLabel("Clear graph search")
                .accessibilityHint("Removes the current graph search query")
            }

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close graph search")
            .accessibilityLabel("Close graph search")
            .accessibilityHint("Closes the search field and returns focus to the graph")
        }
        .padding(.horizontal, 8)
        .frame(width: 280, height: 32)
        .background(ObsidianUI.sidebarBackground.opacity(0.94))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(ObsidianUI.border)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onAppear {
            searchFieldFocused = true
        }
        .onExitCommand(perform: close)
    }
}

private struct GraphFloatingControlStack: View {
    static let centerY: CGFloat = 139

    let searchIsPresented: Bool
    let searchAccessibilityLabel: String
    let searchAccessibilityHint: String
    let searchAccessibilityValue: String
    let settingsIsPresented: Bool
    let toggleSearch: () -> Void
    let zoomOut: () -> Void
    let zoomIn: () -> Void
    let resetView: () -> Void
    let toggleSettings: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            ObsidianIconButton(
                systemName: "magnifyingglass",
                accessibilityLabel: searchAccessibilityLabel,
                isSelected: searchIsPresented,
                action: toggleSearch
            )
            .accessibilityHint(searchAccessibilityHint)
            .accessibilityValue(searchAccessibilityValue)

            ObsidianIconButton(
                systemName: "minus.magnifyingglass",
                accessibilityLabel: "Zoom out graph",
                action: zoomOut
            )
            .accessibilityHint("Decreases graph zoom")

            ObsidianIconButton(
                systemName: "plus.magnifyingglass",
                accessibilityLabel: "Zoom in graph",
                action: zoomIn
            )
            .accessibilityHint("Increases graph zoom")

            ObsidianIconButton(
                systemName: "arrow.counterclockwise",
                accessibilityLabel: "Reset graph view",
                action: resetView
            )
            .accessibilityHint("Fits the graph back into the canvas")

            ObsidianIconButton(
                systemName: "slider.horizontal.3",
                accessibilityLabel: "Graph settings",
                isSelected: settingsIsPresented,
                action: toggleSettings
            )
            .accessibilityHint("Opens graph display and filter settings")
        }
        .fixedSize()
    }
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

    @State private var groupQuery = ""
    @State private var groupColorHex = GraphGroupPalette.colors[0].hex

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

            VStack(alignment: .leading, spacing: 6) {
                Text("Node size")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Slider(value: $settings.presentation.nodeSize, in: 0.6...1.8, step: 0.1)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Link thickness")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Slider(
                    value: $settings.presentation.linkThickness,
                    in: GraphVisualMetrics.minimumLinkThickness...1.8,
                    step: 0.05
                )
            }

            if parityControlsEnabled {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Forces", isOn: $settings.presentation.force.isEnabled)

                    VStack(alignment: .leading, spacing: 8) {
                        forceSlider(
                            title: "Center",
                            value: $settings.presentation.force.centerStrength,
                            range: 0...1
                        )
                        forceSlider(
                            title: "Repel",
                            value: $settings.presentation.force.repelStrength,
                            range: 0...1
                        )
                        forceSlider(
                            title: "Link force",
                            value: $settings.presentation.force.linkStrength,
                            range: 0...1
                        )
                        forceSlider(
                            title: "Link distance",
                            value: $settings.presentation.force.linkDistance,
                            range: 40...320
                        )
                    }
                    .disabled(!settings.presentation.force.isEnabled)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Groups")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    TextField("Match", text: $groupQuery)
                        .textFieldStyle(.roundedBorder)

                    Picker("Color", selection: $groupColorHex) {
                        ForEach(GraphGroupPalette.colors) { color in
                            HStack {
                                Circle()
                                    .fill(Color(graphHex: color.hex))
                                    .frame(width: 10, height: 10)
                                Text(color.name)
                            }
                            .tag(color.hex)
                        }
                    }
                    .pickerStyle(.menu)

                    HStack(spacing: 8) {
                        Button {
                            addGroupRule()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .disabled(groupQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("Add group")
                        .accessibilityLabel("Add graph group")

                        Spacer()
                    }

                    ForEach(settings.groupRules) { rule in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color(graphHex: rule.colorHex))
                                .frame(width: 10, height: 10)
                            Text(rule.query)
                                .lineLimit(1)
                                .font(.caption)
                            Spacer()
                            Button {
                                removeGroupRule(rule)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove group")
                            .accessibilityLabel("Remove graph group")
                        }
                    }
                }
            }

            Spacer()
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(ObsidianUI.sidebarBackground)
    }

    private func addGroupRule() {
        let query = groupQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return
        }
        settings.groupRules.append(GraphGroupRule(
            id: UUID().uuidString,
            query: query,
            colorHex: groupColorHex
        ))
        groupQuery = ""
    }

    private func removeGroupRule(_ rule: GraphGroupRule) {
        settings.groupRules.removeAll { $0.id == rule.id }
    }

    private func forceSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Slider(value: value, in: range, step: 0.05)
        }
    }
}

private struct GraphGroupPaletteColor: Identifiable {
    let name: String
    let hex: String

    var id: String { hex }
}

private enum GraphGroupPalette {
    static let colors = [
        GraphGroupPaletteColor(name: "Blue", hex: "#2f81f7"),
        GraphGroupPaletteColor(name: "Green", hex: "#2da44e"),
        GraphGroupPaletteColor(name: "Red", hex: "#cf222e"),
        GraphGroupPaletteColor(name: "Gold", hex: "#bf8700"),
        GraphGroupPaletteColor(name: "Violet", hex: "#8250df")
    ]
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
