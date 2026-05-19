import AppKit
import NativeMarkdownCore
import SwiftUI

struct SourceNoteView: View {
    @EnvironmentObject private var appState: AppState
    let vaultURL: URL
    let file: FileTreeItem

    @State private var state: SourceNoteViewState = .loading
    @State private var text = ""
    @State private var pendingExternalLink: PendingExternalLink?
    @State private var interactionNotice: EditorInteractionNotice?

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
                MarkdownEditorView(
                    text: $text,
                    isEditable: false,
                    interactionHandler: handleEditorInteraction
                )
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
        .alert("Open External Link?", isPresented: externalLinkAlertBinding) {
            Button("Open") {
                if let url = pendingExternalLink?.url {
                    NSWorkspace.shared.open(url)
                }
                pendingExternalLink = nil
            }
            Button("Cancel", role: .cancel) {
                pendingExternalLink = nil
            }
        } message: {
            Text(pendingExternalLink?.url.absoluteString ?? "")
        }
        .alert(interactionNotice?.title ?? "", isPresented: interactionNoticeAlertBinding) {
            Button("OK") {
                interactionNotice = nil
            }
        } message: {
            Text(interactionNotice?.message ?? "")
        }
    }

    private func load() async {
        state = .loading
        let timer = AppTelemetryTimer()
        do {
            let document = try await Task.detached(priority: .userInitiated) {
                try FileSystemNoteDocumentLoader().loadNote(at: vaultURL, file: file)
            }.value

            if Task.isCancelled {
                return
            }

            text = document.contents
            state = .loaded
            AppTelemetry.noteLoadCompleted(
                file,
                success: true,
                durationMilliseconds: timer.elapsedMilliseconds()
            )
        } catch {
            if Task.isCancelled {
                return
            }
            text = ""
            state = .failed(displayMessage(for: error))
            AppTelemetry.noteLoadCompleted(
                file,
                success: false,
                durationMilliseconds: timer.elapsedMilliseconds()
            )
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

    private var externalLinkAlertBinding: Binding<Bool> {
        Binding {
            pendingExternalLink != nil
        } set: { isPresented in
            if !isPresented {
                pendingExternalLink = nil
            }
        }
    }

    private var interactionNoticeAlertBinding: Binding<Bool> {
        Binding {
            interactionNotice != nil
        } set: { isPresented in
            if !isPresented {
                interactionNotice = nil
            }
        }
    }

    private func handleEditorInteraction(_ interaction: MarkdownEditorInteraction) {
        switch interaction {
        case .wikiLink(let link):
            Task {
                await resolveAndOpen(link)
            }
        case .externalLink(let link):
            guard link.isUserConfirmableExternalURL, let url = link.url else {
                interactionNotice = EditorInteractionNotice(
                    title: "Unsupported Link",
                    message: link.rawTarget
                )
                return
            }
            pendingExternalLink = PendingExternalLink(url: url)
        case .tag(let tag):
            appState.requestSearch(query: "#\(tag)", mode: .body)
        }
    }

    @MainActor
    private func resolveAndOpen(_ link: EditorWikiLink) async {
        do {
            let state = try await Task.detached(priority: .userInitiated) {
                try FileSystemEditorWikiLinkResolver().resolve(link, at: vaultURL)
            }.value

            switch state {
            case .resolved(let file):
                appState.openFile(file)
            case .missing:
                interactionNotice = EditorInteractionNotice(
                    title: "Missing Link",
                    message: link.target
                )
            case .duplicate(let files):
                interactionNotice = EditorInteractionNotice(
                    title: "Duplicate Link",
                    message: files.map(\.relativePath).joined(separator: "\n")
                )
            case .missingHeading(let file, let heading):
                interactionNotice = EditorInteractionNotice(
                    title: "Missing Heading",
                    message: "\(file.relativePath)#\(heading)"
                )
            }
        } catch {
            interactionNotice = EditorInteractionNotice(
                title: "Link Resolution Failed",
                message: error.localizedDescription
            )
        }
    }
}

private enum SourceNoteViewState {
    case loading
    case loaded
    case failed(String)
}

private struct PendingExternalLink: Identifiable {
    let url: URL

    var id: String {
        url.absoluteString
    }
}

private struct EditorInteractionNotice: Identifiable {
    let title: String
    let message: String

    var id: String {
        "\(title)-\(message)"
    }
}
