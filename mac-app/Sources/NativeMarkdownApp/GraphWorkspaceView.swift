import NativeMarkdownCore
import SwiftUI

struct GraphWorkspaceView: View {
    let vaultSelection: VaultSelectionState

    @State private var settings = GraphSettings()
    @State private var searchText = ""
    @State private var showsSettings = false
    private let enablesParityControls = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                toolbar

                Divider()

                graphPlaceholder
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

    private var graphPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Graph view")
                .font(.title3)
                .foregroundStyle(.primary)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Graph view")
    }

    private var statusText: String {
        switch vaultSelection {
        case .selected:
            "Graph data not loaded"
        case .noVault:
            "No vault open"
        case .unavailable(let issue):
            issue.displayTitle
        }
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
