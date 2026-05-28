import AppKit
import SwiftUI

@MainActor
struct WorkspaceTabAction {
    let isAvailable: Bool
    let newTab: @MainActor () -> Void
    let closeActiveTab: @MainActor () -> Void
    let restoreClosedTab: @MainActor () -> Void
    let activateNextTab: @MainActor () -> Void
    let activatePreviousTab: @MainActor () -> Void
    let activateTabAtShortcutIndex: @MainActor (Int) -> Void
}

@MainActor
final class WorkspaceTabCommandRegistry: ObservableObject {
    static let shared = WorkspaceTabCommandRegistry()

    @Published private var revision = 0
    private var registeredAction: WorkspaceTabAction?
    private weak var registeredWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []

    var action: WorkspaceTabAction? {
        action(for: NSApp.keyWindow)
    }

    func action(for keyWindow: NSWindow?) -> WorkspaceTabAction? {
        guard let registeredAction,
              let registeredWindow,
              keyWindow === registeredWindow
        else {
            return nil
        }
        return registeredAction
    }

    private init() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.revision += 1 }
            },
            center.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.revision += 1 }
            }
        ]
    }

    func register(action: WorkspaceTabAction, for window: NSWindow?) {
        registeredAction = action
        registeredWindow = window
        revision += 1
    }

    func unregister(window: NSWindow?) {
        guard window == nil || registeredWindow === window else {
            return
        }
        registeredAction = nil
        registeredWindow = nil
        revision += 1
    }
}

private struct WorkspaceTabActionKey: FocusedValueKey {
    typealias Value = WorkspaceTabAction
}

extension FocusedValues {
    var workspaceTabAction: WorkspaceTabAction? {
        get { self[WorkspaceTabActionKey.self] }
        set { self[WorkspaceTabActionKey.self] = newValue }
    }
}
