import AppKit
import NativeMarkdownCore
import SwiftUI

private final class SourceSummaryBufferBox {
    var contents = ""
}

struct SourceNoteView: View {
    private static let conflictActionGeneration: UInt64 = 0
    private static let fallbackProfileMinimumByteDelta = 4_096
    private static let fallbackProfileDebounceMilliseconds: UInt64 = 250

    @EnvironmentObject private var appState: AppState
    let vaultURL: URL
    let file: FileTreeItem
    let chrome: SourceNoteChrome
    let isActive: Bool
    let focusRequestID: WorkspaceTab.ID?
    private let noteSaver: any EngineNoteSaving

    @State private var state: SourceNoteViewState = .loading
    @State private var text = ""
    @State private var saveSession: EditorSaveSession?
    @State private var fallbackController = LivePreviewFallbackController()
    @State private var lastFallbackProfileByteCount = 0
    @State private var pendingExternalLink: PendingExternalLink?
    @State private var interactionNotice: EditorInteractionNotice?
    @State private var pendingRecoverySnapshot: EditorRecoverySnapshot?
    @State private var livePreviewLinkStyleMap = LivePreviewLinkStyleMap()
    @State private var livePreviewEmbedPreviewMap = LivePreviewEmbedPreviewMap()
    @State private var recoveryTask: Task<Void, Never>?
    @State private var fallbackProfileTask: Task<Void, Never>?
    @State private var livePreviewMetadataTask: Task<Void, Never>?
    @State private var activityToken = WorkspaceEditorActivityToken()
    @State private var summaryBuffer = SourceSummaryBufferBox()
    @State private var summaryBufferOwnerID = UUID()
    @State private var summaryBufferRevision: UInt64 = 0
    @AppStorage(LivePreviewMarkerStyle.storageKey) private var markerStyleRaw = LivePreviewMarkerStyle.defaultValue.rawValue

    init(
        vaultURL: URL,
        file: FileTreeItem,
        chrome: SourceNoteChrome = .native,
        isActive: Bool = true,
        focusRequestID: WorkspaceTab.ID? = nil,
        noteSaver: any EngineNoteSaving = EngineSaveClient()
    ) {
        self.vaultURL = vaultURL
        self.file = file
        self.chrome = chrome
        self.isActive = isActive
        self.focusRequestID = focusRequestID
        self.noteSaver = noteSaver
    }

    var body: some View {
        VStack(spacing: chrome.verticalSpacing) {
            if chrome.showsHeader {
                header
            }

            switch state {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                MarkdownEditorView(
                    text: $text,
                    isEditable: saveSession?.canEdit == true,
                    livePreviewMode: livePreviewMode,
                    linkStyleMap: livePreviewLinkStyleMap,
                    embedPreviewMap: livePreviewEmbedPreviewMap,
                    markerStyle: livePreviewMarkerStyle,
                    documentTitle: file.displayName,
                    isActive: isActive,
                    focusRequestID: focusRequestID,
                    interactionHandler: handleEditorInteraction
                )
                    .frame(minHeight: 320)
                    .padding(.horizontal, chrome.editorHorizontalPadding)
                    .padding(.vertical, chrome.editorVerticalPadding)
                    .accessibilityLabel("Markdown editor for \(file.displayName)")

                if chrome == .native {
                    LivePreviewStatusStrip(
                        mode: livePreviewMode,
                        retryLivePreview: retryLivePreview
                    )
                    SaveStatusStrip(
                        session: saveSession,
                        save: saveCurrentNote,
                        reloadAfterConflict: reloadAfterConflict,
                        keepConflictAsNewNote: keepConflictAsNewNote,
                        overwriteAfterConflict: overwriteAfterConflict
                    )
                } else {
                    ObsidianEditorStatusBar(
                        mode: livePreviewMode,
                        session: saveSession,
                        save: saveCurrentNote,
                        retryLivePreview: retryLivePreview,
                        reloadAfterConflict: reloadAfterConflict,
                        keepConflictAsNewNote: keepConflictAsNewNote,
                        overwriteAfterConflict: overwriteAfterConflict
                    )
                }
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
        .padding(chrome.outerPadding)
        .background(ObsidianUI.editorBackground)
        .task(id: file.id) {
            await load()
        }
        .onChange(of: text) { _, newValue in
            guard WorkspaceEditorActivityGate.shouldRun(.textChangeSideEffects, isActive: isActive) else {
                return
            }
            saveSession?.updateContents(newValue)
            updateSummaryBuffer(contents: newValue)
            clearLivePreviewMetadata()
            updateAutomaticFallbackAfterTextChange(for: newValue)
            scheduleRecoverySnapshot(contents: newValue)
        }
        .onChange(of: isActive) { _, newValue in
            if newValue {
                activityToken = WorkspaceEditorActivityToken()
                registerSummaryBufferIfActive(contents: text)
                refreshLivePreviewMetadataIfNeeded(contents: text)
            } else {
                clearSummaryBufferProvider()
                cancelInactiveEditorWork()
            }
        }
        .onChange(of: saveSession) { oldValue, newValue in
            appState.updateEditorDirtyState(file: file, isDirty: newValue?.isDirty == true)
            if oldValue?.isDirty == true, newValue?.isDirty == false {
                clearRecoverySnapshot()
            }
        }
        .onDisappear {
            recoveryTask?.cancel()
            fallbackProfileTask?.cancel()
            livePreviewMetadataTask?.cancel()
            clearSummaryBufferProvider()
            if saveSession?.isDirty == true, appState.isEditorDirty(file: file) {
                writeRecoverySnapshot(contents: text)
            } else {
                clearRecoverySnapshot()
                appState.updateEditorDirtyState(file: file, isDirty: false)
            }
        }
        .focusedSceneValue(\.editorSaveAction, activeEditorSaveAction)
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
        .alert("Recovered Draft", isPresented: recoveryAlertBinding) {
            Button("Use Draft") {
                applyRecoverySnapshot()
            }
            Button("Discard Draft", role: .destructive) {
                discardRecoverySnapshot()
            }
        } message: {
            Text("A newer unsaved draft exists for \(file.displayName).")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
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
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Current note \(file.displayName)")
            Spacer(minLength: 12)
            Button(action: toggleEditorMode) {
                Label(modeToggleTitle, systemImage: livePreviewMode.rendersSourceOnly ? "eye" : "curlybraces")
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .help("Toggle Live Preview and Source mode")
        }
    }

    private var modeToggleTitle: String {
        livePreviewMode.rendersSourceOnly ? "Live Preview" : "Source"
    }

    private var livePreviewMode: LivePreviewMode {
        fallbackController.mode
    }

    private var livePreviewMarkerStyle: LivePreviewMarkerStyle {
        LivePreviewMarkerStyle(rawValue: markerStyleRaw) ?? .defaultValue
    }

    private func toggleEditorMode() {
        if livePreviewMode.rendersSourceOnly {
            retryLivePreview()
        } else {
            var controller = fallbackController
            controller.selectSourceMode()
            fallbackController = controller
            clearLivePreviewMetadata()
        }
    }

    private func retryLivePreview() {
        var controller = fallbackController
        controller.retryLivePreview()
        fallbackController = controller
        updateAutomaticFallback(for: text)
        refreshLivePreviewMetadataIfNeeded(contents: text)
    }

    private func updateAutomaticFallbackAfterTextChange(for contents: String) {
        guard WorkspaceEditorActivityGate.shouldRun(.fallbackProfile, isActive: isActive) else {
            return
        }
        guard livePreviewMode != .source else {
            return
        }
        let byteCount = contents.utf8.count
        let thresholds = EditorDegradationThresholds()
        let byteDelta = abs(byteCount - lastFallbackProfileByteCount)
        if byteCount > thresholds.maxDecoratedFileBytes ||
            byteDelta >= Self.fallbackProfileMinimumByteDelta {
            updateAutomaticFallback(for: contents)
            return
        }
        scheduleFallbackProfile(contents: contents)
    }

    private func updateAutomaticFallback(for contents: String) {
        guard livePreviewMode != .source else {
            return
        }
        lastFallbackProfileByteCount = contents.utf8.count
        var controller = fallbackController
        let profile = EditorDocumentProfiler.profile(contents)
        controller.observe(EditorStrategyDecision().renderingMode(for: profile))
        fallbackController = controller
        if livePreviewMode.rendersSourceOnly {
            clearLivePreviewMetadata()
        }
    }

    private func scheduleFallbackProfile(contents: String) {
        fallbackProfileTask?.cancel()
        fallbackProfileTask = Task {
            try? await Task.sleep(for: .milliseconds(Self.fallbackProfileDebounceMilliseconds))
            if Task.isCancelled {
                return
            }
            await MainActor.run {
                guard isActive, contents == text else {
                    return
                }
                updateAutomaticFallback(for: contents)
            }
        }
    }

    private var editorSaveAction: EditorSaveAction {
        EditorSaveAction(isAvailable: saveSession?.canSave == true) {
            saveCurrentNote()
        }
    }

    private var activeEditorSaveAction: EditorSaveAction? {
        isActive ? editorSaveAction : nil
    }

    private func load() async {
        state = .loading
        saveSession = nil
        pendingRecoverySnapshot = nil
        fallbackProfileTask?.cancel()
        livePreviewMetadataTask?.cancel()
        livePreviewLinkStyleMap = LivePreviewLinkStyleMap()
        livePreviewEmbedPreviewMap = LivePreviewEmbedPreviewMap()
        fallbackController = LivePreviewFallbackController()
        lastFallbackProfileByteCount = 0
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
            registerSummaryBufferIfActive(contents: document.contents)
            updateAutomaticFallback(for: document.contents)
            state = .loaded
            refreshLivePreviewMetadataIfNeeded(contents: document.contents)
            AppTelemetry.noteLoadCompleted(
                file,
                success: true,
                durationMilliseconds: timer.elapsedMilliseconds()
            )
            await captureSaveBaseline()
            await loadRecoverySnapshot(diskContents: document.contents)
        } catch {
            if Task.isCancelled {
                return
            }
            text = ""
            saveSession = nil
            pendingRecoverySnapshot = nil
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
                refreshLivePreviewMetadataIfNeeded(contents: request.contents)
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
                updateSummaryBuffer(contents: outcome.contents)
                session = saveSession ?? session
                session.completeReload(outcome)
                saveSession = session
                refreshLivePreviewMetadataIfNeeded(contents: outcome.contents)
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
                refreshLivePreviewMetadataIfNeeded(contents: savedSnapshot)
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
                refreshLivePreviewMetadataIfNeeded(contents: savedSnapshot)
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

    private var recoveryAlertBinding: Binding<Bool> {
        Binding {
            pendingRecoverySnapshot != nil
        } set: { isPresented in
            if !isPresented {
                pendingRecoverySnapshot = nil
            }
        }
    }

    private func loadRecoverySnapshot(diskContents: String) async {
        guard let store = recoveryStore() else {
            return
        }

        do {
            let file = file
            let snapshot = try await Task.detached(priority: .utility) {
                try store.loadSnapshot(for: file)
            }.value

            if Task.isCancelled {
                return
            }

            if let snapshot, snapshot.contents != diskContents {
                pendingRecoverySnapshot = snapshot
            } else if snapshot != nil {
                clearRecoverySnapshot()
            }
        } catch {
            pendingRecoverySnapshot = nil
        }
    }

    private func applyRecoverySnapshot() {
        guard let snapshot = pendingRecoverySnapshot else {
            return
        }
        text = snapshot.contents
        saveSession?.updateContents(snapshot.contents)
        updateSummaryBuffer(contents: snapshot.contents)
        appState.updateEditorDirtyState(file: file, isDirty: saveSession?.isDirty == true)
        pendingRecoverySnapshot = nil
        clearLivePreviewMetadata()
        scheduleRecoverySnapshot(contents: snapshot.contents)
    }

    private func discardRecoverySnapshot() {
        pendingRecoverySnapshot = nil
        clearRecoverySnapshot()
    }

    private func scheduleRecoverySnapshot(contents: String) {
        guard WorkspaceEditorActivityGate.shouldRun(.recoverySnapshot, isActive: isActive) else {
            return
        }
        guard saveSession?.isDirty == true else {
            return
        }
        recoveryTask?.cancel()
        recoveryTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled {
                return
            }
            writeRecoverySnapshot(contents: contents)
        }
    }

    private func writeRecoverySnapshot(contents: String) {
        guard let store = recoveryStore() else {
            return
        }
        let file = file
        Task {
            try? await Task.detached(priority: .utility) {
                try store.writeSnapshot(file: file, contents: contents)
            }.value
        }
    }

    private func clearRecoverySnapshot() {
        recoveryTask?.cancel()
        guard let store = recoveryStore() else {
            return
        }
        let file = file
        Task {
            try? await Task.detached(priority: .utility) {
                try store.clearSnapshot(for: file)
            }.value
        }
    }

    private func recoveryStore() -> EditorRecoveryStore? {
        guard let dataDirectory = appState.indexLocation?.dataDirectory else {
            return nil
        }
        return EditorRecoveryStore(dataDirectory: dataDirectory)
    }

    private func registerSummaryBufferIfActive(contents: String) {
        guard isActive,
              let tabID = summaryTabID
        else {
            return
        }
        summaryBuffer.contents = contents
        appState.registerActiveEditorBufferProvider(
            vaultID: vaultURL.standardizedFileURL.path,
            ownerID: summaryBufferOwnerID,
            tabID: tabID,
            fileID: file.id,
            revision: summaryBufferRevision
        ) { [summaryBuffer] in
            summaryBuffer.contents
        }
    }

    private func updateSummaryBuffer(contents: String) {
        guard isActive,
              let tabID = summaryTabID
        else {
            return
        }
        summaryBuffer.contents = contents
        summaryBufferRevision &+= 1
        appState.updateActiveEditorBufferRevision(
            ownerID: summaryBufferOwnerID,
            tabID: tabID,
            fileID: file.id,
            revision: summaryBufferRevision
        )
    }

    private func clearSummaryBufferProvider() {
        guard let tabID = summaryTabID else {
            return
        }
        appState.clearActiveEditorBufferProvider(
            ownerID: summaryBufferOwnerID,
            tabID: tabID,
            fileID: file.id
        )
    }

    private var summaryTabID: WorkspaceTab.ID? {
        focusRequestID ?? appState.activeTabID
    }

    private func clearLivePreviewMetadata() {
        livePreviewMetadataTask?.cancel()
        if !livePreviewLinkStyleMap.isEmpty || !livePreviewEmbedPreviewMap.isEmpty {
            livePreviewLinkStyleMap = LivePreviewLinkStyleMap()
            livePreviewEmbedPreviewMap = LivePreviewEmbedPreviewMap()
        }
    }

    private func refreshLivePreviewMetadataIfNeeded(contents: String) {
        guard WorkspaceEditorActivityGate.shouldRun(.livePreviewMetadata, isActive: isActive) else {
            clearLivePreviewMetadata()
            return
        }
        guard livePreviewMode == .livePreview else {
            clearLivePreviewMetadata()
            return
        }
        refreshLivePreviewMetadata(contents: contents)
    }

    private func refreshLivePreviewMetadata(contents: String) {
        livePreviewMetadataTask?.cancel()
        let vaultURL = vaultURL
        let file = file
        let reader = appState.readClient
        let readAvailability = appState.readAvailability
        let readGeneration = appState.readGeneration
        let activityToken = activityToken
        livePreviewMetadataTask = Task {
            guard let reader, readAvailability == .ready, !activityToken.isCancelled else {
                clearLivePreviewMetadata()
                return
            }

            let maps = try? await Task.detached(priority: .utility) {
                guard !activityToken.isCancelled else {
                    return (LivePreviewLinkStyleMap(), LivePreviewEmbedPreviewMap())
                }
                let metadata = try await EngineLivePreviewMetadataLoader(reader: reader).loadMetadata(
                    file: file,
                    requestID: readGeneration,
                    contents: contents
                )
                guard !activityToken.isCancelled else {
                    return (metadata.linkStyleMap(source: contents), LivePreviewEmbedPreviewMap())
                }
                let embedPreviewPlan = LivePreviewEmbedPreviewPlan(
                    source: contents,
                    references: metadata.attachments
                )
                let previewStates = livePreviewStates(
                    vaultURL: vaultURL,
                    references: metadata.attachments.filter { embedPreviewPlan.referenceIDs.contains($0.id) }
                )
                return (
                    metadata.linkStyleMap(source: contents),
                    embedPreviewPlan.previewMap(previewStatesByID: previewStates)
                )
            }.value

            if Task.isCancelled ||
                activityToken.isCancelled ||
                !LivePreviewMetadataFreshness.accepts(candidateContents: contents, currentContents: text) {
                return
            }
            livePreviewLinkStyleMap = maps?.0 ?? LivePreviewLinkStyleMap()
            livePreviewEmbedPreviewMap = maps?.1 ?? LivePreviewEmbedPreviewMap()
        }
    }

    private func cancelInactiveEditorWork() {
        activityToken.cancel()
        fallbackProfileTask?.cancel()
        livePreviewMetadataTask?.cancel()
    }

    private func handleEditorInteraction(_ request: MarkdownEditorInteractionRequest) {
        switch request.interaction {
        case .wikiLink(let link):
            Task {
                await resolveAndOpen(link, disposition: request.disposition)
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
    private func resolveAndOpen(
        _ link: EditorWikiLink,
        disposition: WorkspaceTabOpenDisposition
    ) async {
        do {
            let state = try await Task.detached(priority: .userInitiated) {
                try FileSystemEditorWikiLinkResolver().resolve(link, at: vaultURL)
            }.value

            switch state {
            case .resolved(let file):
                appState.openFile(file, disposition: disposition)
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

enum SourceNoteChrome {
    case native
    case obsidian

    var showsHeader: Bool {
        self == .native
    }

    var verticalSpacing: CGFloat {
        self == .native ? 12 : 0
    }

    var outerPadding: CGFloat {
        self == .native ? 16 : 0
    }

    var editorHorizontalPadding: CGFloat {
        self == .native ? 0 : 34
    }

    var editorVerticalPadding: CGFloat {
        self == .native ? 0 : 22
    }
}

private func livePreviewStates(
    vaultURL: URL,
    references: [AttachmentReferenceItem]
) -> [String: AttachmentPreviewState] {
    let gate = FileSystemAttachmentPreviewGate()
    var states: [String: AttachmentPreviewState] = [:]
    for reference in references where reference.source == .wikiEmbed || reference.source == .markdownImage {
        let state = gate.previewState(vaultURL: vaultURL, reference: reference)
        if case .eligible(let info) = state,
           !AttachmentPreviewImageDecoder.canDecode(info) {
            states[reference.id] = .blocked(.invalidImage)
        } else {
            states[reference.id] = state
        }
    }
    return states
}

private struct LivePreviewStatusStrip: View {
    let mode: LivePreviewMode
    let retryLivePreview: () -> Void

    var body: some View {
        if let statusText = mode.statusText {
            HStack(spacing: 10) {
                Label(statusText, systemImage: statusImageName)
                    .lineLimit(1)
                Spacer(minLength: 12)
                if case .fallbackSource = mode {
                    Button(action: retryLivePreview) {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(statusText)
        }
    }

    private var statusImageName: String {
        switch mode {
        case .livePreview:
            return "eye"
        case .source:
            return "curlybraces"
        case .fallbackSource:
            return "exclamationmark.triangle"
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Save status")
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

private struct ObsidianEditorStatusBar: View {
    let mode: LivePreviewMode
    let session: EditorSaveSession?
    let save: () -> Void
    let retryLivePreview: () -> Void
    let reloadAfterConflict: () -> Void
    let keepConflictAsNewNote: () -> Void
    let overwriteAfterConflict: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            statusContent

            Spacer(minLength: 12)

            if case .fallbackSource = mode {
                Button(action: retryLivePreview) {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }

            if session?.conflict != nil {
                Button("Reload", action: reloadAfterConflict)
                    .buttonStyle(.borderless)
                Button("Keep Copy", action: keepConflictAsNewNote)
                    .buttonStyle(.borderless)
                Button("Overwrite", action: overwriteAfterConflict)
                    .buttonStyle(.borderless)
            }

            Button(action: save) {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.borderless)
            .disabled(session?.canSave != true)
            .help("Save")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: ObsidianUI.statusBarHeight)
        .background(ObsidianUI.sidebarBackground.opacity(0.55))
        .overlay(alignment: .top) {
            ObsidianUI.border.frame(height: 1)
        }
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
