import NativeMarkdownCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                VaultPickerView()
                    .frame(minHeight: 180, idealHeight: 240, maxHeight: 300)

                Divider()

                SearchPanelView()
                    .frame(minHeight: 180, idealHeight: 260, maxHeight: 340)

                Divider()

                FileTreeView()
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        } detail: {
            WorkspacePlaceholderView(
                vaultSelection: appState.vaultSelection,
                selectedFile: appState.selectedFile
            )
        }
    }
}

struct WorkspacePlaceholderView: View {
    let vaultSelection: VaultSelectionState
    let selectedFile: FileTreeItem?
    @State private var editorText = "# Native Markdown\n\n"

    var body: some View {
        VStack(spacing: 16) {
            switch vaultSelection {
            case .noVault:
                Text("No Vault Open")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            case .selected(let url):
                if let selectedFile {
                    SourceNoteView(vaultURL: url, file: selectedFile)
                } else {
                    Text(url.lastPathComponent)
                        .font(.title2)
                    MarkdownEditorView(text: $editorText, isEditable: false)
                        .frame(minHeight: 320)
                }
            case .unavailable(let issue):
                Text(issue.displayTitle)
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
