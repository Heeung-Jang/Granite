import AppKit
import NativeMarkdownCore
import SwiftUI

struct SourceNoteView: View {
    private static let conflictActionGeneration: UInt64 = 0

    @EnvironmentObject private var appState: AppState
    let vaultURL: URL
    let file: FileTreeItem
    private let noteSaver: any EngineNoteSaving

    @State private var state: SourceNoteViewState = .loading
    @State private var text = ""
    @State private var saveSession: EditorSaveSession?
    @State private var pendingExternalLink: PendingExternalLink?
    @State private var interactionNotice: EditorInteractionNotice?

    init(
        vaultURL: URL,
        file: FileTreeItem,
        noteSaver: any EngineNoteSaving = EngineSaveClient()
    ) {
        self.vaultURL = vaultURL
        self.file = file
        self.noteSaver = noteSaver
    }

    var body: some View {
        VStack(spacing: 12) {
            header

            switch state {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                MarkdownEditorView(
                    text: $text,
                    isEditable: saveSession?.canEdit == true,
                    interactionHandler: handleEditorInteraction
                )
                    .frame(minHeight: 320)
                SaveStatusStrip(
                    session: saveSession,
                    save: saveCurrentNote,
                    reloadAfterConflict: reloadAfterConflict,
                    keepConflictAsNewNote: keepConflictAsNewNote,
                    overwriteAfterConflict: overwriteAfterConflict
                )
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
        .onChange(of: text) { _, newValue in
            saveSession?.updateContents(newValue)
        }
        .onChange(of: saveSession) { _, newValue in
            appState.updateEditorDirtyState(file: file, isDirty: newValue?.isDirty == true)
        }
        .onDisappear {
            if saveSession?.isDirty != true {
                appState.updateEditorDirtyState(file: file, isDirty: false)
            }
        }
        .focusedSceneValue(\.editorSaveAction, editorSaveAction)
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

    private var header: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Text(file.displayName)
                    .font(.headline)

                if saveSession?.isDirty == true {
                    Circle()
                        .fill(.secondary)
                        .frame(width: 6, height: 6)
                        .accessibilityLabel("Unsaved changes")
                }
            }

            Text(file.relativePath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var editorSaveAction: EditorSaveAction {
        EditorSaveAction(isAvailable: saveSession?.canSave == true) {
            saveCurrentNote()
        }
    }

    private func load() async {
        state = .loading
        saveSession = nil
        let timer = AppTelemetryTimer()
        do {
            let document = try await Task.detached(priority: .userInitiated) {
                try FileSystemNoteDocumentLoader().loadNote(at: vaultURL, file: file)
            }.value

            if Task.isCancelled {
                return
            }

            text = document.contents
            saveSession = EditorSaveSession(file: file, contents: document.contents)
            state = .loaded
            AppTelemetry.noteLoadCompleted(
                file,
                success: true,
                durationMilliseconds: timer.elapsedMilliseconds()
            )
            await captureSaveBaseline()
        } catch {
            if Task.isCancelled {
                return
            }
            text = ""
            saveSession = nil
            state = .failed(displayMessage(for: error))
            AppTelemetry.noteLoadCompleted(
                file,
                success: false,
                durationMilliseconds: timer.elapsedMilliseconds()
            )
        }
    }

    private func captureSaveBaseline() async {
        do {
            let saver = noteSaver
            let vaultURL = vaultURL
            let file = file
            let baseline = try await Task.detached(priority: .userInitiated) {
                try saver.captureBaseline(vaultURL: vaultURL, file: file)
            }.value

            if Task.isCancelled {
                return
            }
            saveSession?.completeBaseline(baseline)
        } catch {
            if Task.isCancelled {
                return
            }
            saveSession?.failBaseline(EditorSaveFailure(error: error).message)
        }
    }

    private func saveCurrentNote() {
        guard var session = saveSession,
              let request = session.beginSave()
        else {
            AppTelemetry.saveRequested(file: file, available: false)
            return
        }

        saveSession = session
        AppTelemetry.saveRequested(file: file, available: true)

        Task {
            do {
                let saver = noteSaver
                let vaultURL = vaultURL
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try saver.save(
                        vaultURL: vaultURL,
                        baseline: request.baseline,
                        contents: request.contents
                    )
                }.value

                if Task.isCancelled {
                    return
                }
                session = saveSession ?? session
                session.completeSave(outcome, savedContents: request.contents)
                saveSession = session
            } catch {
                if Task.isCancelled {
                    return
                }
                session = saveSession ?? session
                session.failSave(error)
                saveSession = session
            }
        }
    }

    private func reloadAfterConflict() {
        guard let queueURL = appState.indexLocation?.indexingQueueFile,
              var session = saveSession,
              let conflict = session.beginConflictResolution()
        else {
            showConflictActionUnavailable()
            return
        }

        saveSession = session
        Task {
            do {
                let saver = noteSaver
                let vaultURL = vaultURL
                let generation = Self.conflictActionGeneration
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try saver.reloadAfterConflict(
                        vaultURL: vaultURL,
                        queueURL: queueURL,
                        conflict: conflict,
                        generation: generation
                    )
                }.value

                if Task.isCancelled {
                    return
                }
                text = outcome.contents
                session = saveSession ?? session
                session.completeReload(outcome)
                saveSession = session
            } catch {
                if Task.isCancelled {
                    return
                }
                session = saveSession ?? session
                session.failSave(error)
                saveSession = session
            }
        }
    }

    private func keepConflictAsNewNote() {
        guard let queueURL = appState.indexLocation?.indexingQueueFile,
              var session = saveSession,
              session.beginConflictResolution() != nil
        else {
            showConflictActionUnavailable()
            return
        }

        let savedSnapshot = text
        let newRelativePath = conflictCopyRelativePath(for: file.relativePath)
        saveSession = session
        Task {
            do {
                let saver = noteSaver
                let vaultURL = vaultURL
                let generation = Self.conflictActionGeneration
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try saver.keepConflictAsNewNote(
                        vaultURL: vaultURL,
                        queueURL: queueURL,
                        newRelativePath: newRelativePath,
                        contents: savedSnapshot,
                        generation: generation
                    )
                }.value

                if Task.isCancelled {
                    return
                }
                session = saveSession ?? session
                session.completeChoice(outcome, savedContents: savedSnapshot)
                saveSession = session
                appState.updateEditorDirtyState(file: file, isDirty: session.isDirty)
                appState.openFile(FileTreeItem(relativePath: outcome.baseline.relativePath))
            } catch {
                if Task.isCancelled {
                    return
                }
                session = saveSession ?? session
                session.failSave(error)
                saveSession = session
            }
        }
    }

    private func overwriteAfterConflict() {
        guard let queueURL = appState.indexLocation?.indexingQueueFile,
              var session = saveSession,
              let conflict = session.beginConflictResolution()
        else {
            showConflictActionUnavailable()
            return
        }

        let savedSnapshot = text
        saveSession = session
        Task {
            do {
                let saver = noteSaver
                let vaultURL = vaultURL
                let generation = Self.conflictActionGeneration
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try saver.overwriteAfterConflict(
                        vaultURL: vaultURL,
                        queueURL: queueURL,
                        conflict: conflict,
                        contents: savedSnapshot,
                        generation: generation
                    )
                }.value

                if Task.isCancelled {
                    return
                }
                session = saveSession ?? session
                session.completeChoice(outcome, savedContents: savedSnapshot)
                saveSession = session
            } catch {
                if Task.isCancelled {
                    return
                }
                session = saveSession ?? session
                session.failSave(error)
                saveSession = session
            }
        }
    }

    private func showConflictActionUnavailable() {
        interactionNotice = EditorInteractionNotice(
            title: "Conflict Action Unavailable",
            message: "Save queue or conflict details are unavailable."
        )
    }

    private func conflictCopyRelativePath(for relativePath: String) -> String {
        let path = relativePath as NSString
        let parent = path.deletingLastPathComponent
        let fileName = path.lastPathComponent as NSString
        let stem = fileName.deletingPathExtension
        let ext = fileName.pathExtension
        let copyName = ext.isEmpty ? "\(stem) Conflict Copy" : "\(stem) Conflict Copy.\(ext)"
        return parent.isEmpty || parent == "." ? copyName : "\(parent)/\(copyName)"
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

private struct SaveStatusStrip: View {
    let session: EditorSaveSession?
    let save: () -> Void
    let reloadAfterConflict: () -> Void
    let keepConflictAsNewNote: () -> Void
    let overwriteAfterConflict: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            statusContent
            Spacer(minLength: 12)
            if session?.conflict != nil {
                Button(action: reloadAfterConflict) {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                Button(action: keepConflictAsNewNote) {
                    Label("Keep Copy", systemImage: "doc.badge.plus")
                }
                Button(action: overwriteAfterConflict) {
                    Label("Overwrite", systemImage: "square.and.pencil")
                }
            }
            Button(action: save) {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .disabled(session?.canSave != true)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var statusContent: some View {
        switch session?.status {
        case .baselinePending:
            ProgressView()
                .controlSize(.small)
            Text("Preparing safe save")
        case .unavailable(let message):
            Label("Read-only: \(message)", systemImage: "lock")
                .lineLimit(1)
        case .clean:
            Label("Saved", systemImage: "checkmark.circle")
        case .dirty:
            Label("Unsaved changes", systemImage: "circle.fill")
        case .saving:
            ProgressView()
                .controlSize(.small)
            Text("Saving")
        case .failed(let failure):
            Label("\(failure.title): \(failure.message)", systemImage: "exclamationmark.triangle")
                .lineLimit(1)
        case nil:
            EmptyView()
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
