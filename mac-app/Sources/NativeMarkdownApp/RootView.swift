import NativeMarkdownCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationSplitView {
            VaultPickerView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            WorkspacePlaceholderView(vaultSelection: appState.vaultSelection)
        }
    }
}

struct WorkspacePlaceholderView: View {
    let vaultSelection: VaultSelectionState
    @State private var editorText = "# Native Markdown\n\n"

    var body: some View {
        VStack(spacing: 16) {
            switch vaultSelection {
            case .noVault:
                Text("No Vault Open")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            case .selected(let url):
                Text(url.lastPathComponent)
                    .font(.title2)
                MarkdownEditorView(text: $editorText)
                    .frame(minHeight: 320)
            case .unavailable(let issue):
                Text(issue.displayTitle)
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
