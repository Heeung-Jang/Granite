import Foundation

public struct EditorSaveSession: Equatable, Sendable {
    public let file: FileTreeItem
    public private(set) var baseline: EngineSaveBaseline?
    public private(set) var savedContents: String
    public private(set) var currentContents: String
    public private(set) var status: EditorSaveStatus

    public init(file: FileTreeItem, contents: String) {
        self.file = file
        baseline = nil
        savedContents = contents
        currentContents = contents
        status = .baselinePending
    }

    public var isDirty: Bool {
        currentContents != savedContents
    }

    public var canEdit: Bool {
        baseline != nil
    }

    public var canSave: Bool {
        baseline != nil && isDirty && !status.isSaving
    }

    public mutating func updateContents(_ contents: String) {
        currentContents = contents
        refreshStatusAfterContentChange()
    }

    public mutating func completeBaseline(_ baseline: EngineSaveBaseline) {
        self.baseline = baseline
        status = isDirty ? .dirty : .clean
    }

    public mutating func failBaseline(_ message: String) {
        baseline = nil
        status = .unavailable(message)
    }

    public mutating func beginSave() -> EditorSaveRequest? {
        guard let baseline, isDirty, !status.isSaving else {
            return nil
        }
        status = .saving
        return EditorSaveRequest(baseline: baseline, contents: currentContents)
    }

    public mutating func completeSave(_ outcome: EngineSaveOutcome, savedContents: String) {
        baseline = outcome.baseline
        self.savedContents = savedContents
        status = currentContents == savedContents ? .clean : .dirty
    }

    public mutating func failSave(_ error: Error) {
        status = .failed(EditorSaveFailure(error: error))
    }

    private mutating func refreshStatusAfterContentChange() {
        guard baseline != nil else {
            return
        }
        if status.isSaving {
            return
        }
        status = isDirty ? .dirty : .clean
    }
}

public struct EditorSaveRequest: Equatable, Sendable {
    public let baseline: EngineSaveBaseline
    public let contents: String
}

public enum EditorSaveStatus: Equatable, Sendable {
    case baselinePending
    case unavailable(String)
    case clean
    case dirty
    case saving
    case failed(EditorSaveFailure)

    public var isSaving: Bool {
        if case .saving = self {
            return true
        }
        return false
    }
}

public struct EditorSaveFailure: Equatable, Sendable {
    public let title: String
    public let message: String
    public let conflictKind: String?

    public init(title: String, message: String, conflictKind: String? = nil) {
        self.title = title
        self.message = message
        self.conflictKind = conflictKind
    }

    public init(error: Error) {
        switch error {
        case EngineSaveClientError.engine(let payload):
            if payload.code == "save_conflict" || payload.conflictKind != nil {
                self.init(
                    title: "External Change Detected",
                    message: payload.message,
                    conflictKind: payload.conflictKind
                )
            } else {
                self.init(title: "Save Failed", message: payload.message)
            }
        case EngineSaveClientError.missingLibrary(let message):
            self.init(title: "Save Engine Unavailable", message: message)
        case EngineSaveClientError.missingSymbol(let message):
            self.init(title: "Save Engine Incompatible", message: message)
        case EngineSaveClientError.callFailed(let message):
            self.init(title: "Save Failed", message: message)
        case EngineSaveClientError.invalidResponse(let message):
            self.init(title: "Save Response Invalid", message: message)
        default:
            self.init(title: "Save Failed", message: error.localizedDescription)
        }
    }
}
