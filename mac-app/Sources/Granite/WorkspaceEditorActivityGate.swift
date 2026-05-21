import Foundation

struct WorkspaceEditorActivityCounters: Codable, Equatable {
    var activeEventCount = 0
    var inactiveEventCount = 0
    var suppressedInactiveEventCount = 0
}

enum WorkspaceEditorActivityEvent: String, CaseIterable, Codable {
    case textChangeSideEffects
    case fallbackProfile
    case recoverySnapshot
    case livePreviewMetadata
}

enum WorkspaceEditorActivityGate {
    static func shouldRun(
        _ event: WorkspaceEditorActivityEvent,
        isActive: Bool,
        counters: inout WorkspaceEditorActivityCounters
    ) -> Bool {
        if isActive {
            counters.activeEventCount += 1
            return true
        }
        counters.suppressedInactiveEventCount += 1
        return false
    }

    static func shouldRun(_ event: WorkspaceEditorActivityEvent, isActive: Bool) -> Bool {
        var counters = WorkspaceEditorActivityCounters()
        return shouldRun(event, isActive: isActive, counters: &counters)
    }
}

final class WorkspaceEditorActivityToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.withLock {
            cancelled = true
        }
    }

    var isCancelled: Bool {
        lock.withLock {
            cancelled
        }
    }
}
