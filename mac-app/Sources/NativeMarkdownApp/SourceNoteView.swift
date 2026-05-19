import NativeMarkdownCore
import SwiftUI

struct SourceNoteView: View {
    let vaultURL: URL
    let file: FileTreeItem

    @State private var state: SourceNoteViewState = .loading
    @State private var text = ""

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text(file.displayName)
                    .font(.headline)
                Text(file.relativePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            switch state {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                MarkdownEditorView(text: $text, isEditable: false)
                    .frame(minHeight: 320)
            case .failed(let message):
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .task(id: file.id) {
            await load()
        }
    }

    private func load() async {
        state = .loading
        do {
            let document = try await Task.detached(priority: .userInitiated) {
                try FileSystemNoteDocumentLoader().loadNote(at: vaultURL, file: file)
            }.value

            if Task.isCancelled {
                return
            }

            text = document.contents
            state = .loaded
        } catch {
            if Task.isCancelled {
                return
            }
            text = ""
            state = .failed(displayMessage(for: error))
        }
    }

    private func displayMessage(for error: Error) -> String {
        guard let error = error as? NoteDocumentLoadError else {
            return error.localizedDescription
        }

        switch error {
        case .invalidRelativePath:
            return "Invalid note path."
        case .outsideVault:
            return "Note path is outside the vault."
        case .missing:
            return "Note file is missing."
        case .unreadable:
            return "Note file cannot be read."
        case .unsupportedEncoding:
            return "Note file is not valid UTF-8."
        }
    }
}

private enum SourceNoteViewState {
    case loading
    case loaded
    case failed(String)
}
