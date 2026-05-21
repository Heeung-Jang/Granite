import NativeMarkdownCore
import SwiftUI

struct GraphWorkspaceView: View {
    let vaultSelection: VaultSelectionState

    @State private var workspaceModel = GraphWorkspaceModel()
    @State private var settings = GraphSettings()
    @State private var searchText = ""
    @State private var showsSettings = false
    @State private var viewport = GraphViewport()
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
                GraphCanvasRendererView(
                    input: input,
                    viewport: $viewport,
                    callbacks: GraphRendererCallbacks(
                        didCompleteFirstDraw: { metrics in
                            AppTelemetry.graphDrawCompleted(metrics)
                        }
                    )
                )
                .onAppear {
                    workspaceModel.applyStableGraph(GraphStableGraphSummary(
                        generation: input.layout.generation,
                        nodeCount: input.layout.nodes.count,
                        edgeCount: input.layout.edges.count
                    ))
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
            searchText: searchText
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
