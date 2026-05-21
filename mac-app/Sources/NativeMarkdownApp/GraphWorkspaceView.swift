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
    @State private var searchText = ""
    @State private var showsSettings = false
    @State private var viewport = GraphViewport()
    @FocusState private var graphSurfaceFocused: Bool

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
            switch validatedRendererInput {
            case .ready(let input):
                VStack(spacing: 0) {
                    GraphCanvasRendererView(
                        input: input,
                        viewport: $viewport,
                        callbacks: GraphRendererCallbacks(
                            didCompleteFirstDraw: { metrics in
                                AppTelemetry.graphDrawCompleted(metrics)
                            }
                        ),
                        hitTestIndex: GraphCanvasRendererSmokeFixture.hitTestIndex,
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

    private var validatedRendererInput: RendererInputState {
        let input = GraphCanvasRendererSmokeFixture.input(
            viewport: viewport,
            presentation: settings.presentation,
            searchText: searchText,
            hoveredNodeID: interaction.hoveredNodeID,
            selectedNodeID: interaction.selectedNodeID
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

    private enum RendererInputState {
        case ready(GraphRendererInput)
        case failed(GraphRendererValidationError)
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
