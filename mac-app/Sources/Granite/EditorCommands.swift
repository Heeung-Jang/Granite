import AppKit
import SwiftUI

@MainActor
struct EditorSaveAction {
    let isAvailable: Bool
    let perform: @MainActor () -> Void
}

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

private struct EditorSaveActionKey: FocusedValueKey {
    typealias Value = EditorSaveAction
}

private struct WorkspaceTabActionKey: FocusedValueKey {
    typealias Value = WorkspaceTabAction
}

extension FocusedValues {
    var editorSaveAction: EditorSaveAction? {
        get { self[EditorSaveActionKey.self] }
        set { self[EditorSaveActionKey.self] = newValue }
    }

    var workspaceTabAction: WorkspaceTabAction? {
        get { self[WorkspaceTabActionKey.self] }
        set { self[WorkspaceTabActionKey.self] = newValue }
    }
}

struct EditorCommands: Commands {
    @FocusedValue(\.editorSaveAction) private var editorSaveAction
    @FocusedValue(\.workspaceTabAction) private var workspaceTabAction
    @ObservedObject private var workspaceTabCommandRegistry = WorkspaceTabCommandRegistry.shared

    private var currentWorkspaceTabAction: WorkspaceTabAction? {
        workspaceTabAction ?? workspaceTabCommandRegistry.action
    }

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                editorSaveAction?.perform()
            }
            .keyboardShortcut("s")
            .disabled(editorSaveAction?.isAvailable != true)
        }

        CommandMenu("Tabs") {
            Button("New Tab") {
                currentWorkspaceTabAction?.newTab()
            }
            .keyboardShortcut("t")
            .disabled(currentWorkspaceTabAction?.isAvailable != true)

            Button("Close Tab") {
                currentWorkspaceTabAction?.closeActiveTab()
            }
            .keyboardShortcut("w")
            .disabled(currentWorkspaceTabAction?.isAvailable != true)

            Button("Reopen Closed Tab") {
                currentWorkspaceTabAction?.restoreClosedTab()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(currentWorkspaceTabAction?.isAvailable != true)

            Divider()

            Button("Next Tab") {
                currentWorkspaceTabAction?.activateNextTab()
            }
            .keyboardShortcut(.tab, modifiers: [.control])
            .disabled(currentWorkspaceTabAction?.isAvailable != true)

            Button("Previous Tab") {
                currentWorkspaceTabAction?.activatePreviousTab()
            }
            .keyboardShortcut(.tab, modifiers: [.control, .shift])
            .disabled(currentWorkspaceTabAction?.isAvailable != true)

            Divider()

            ForEach(1...9, id: \.self) { index in
                Button(index == 9 ? "Last Tab" : "Tab \(index)") {
                    currentWorkspaceTabAction?.activateTabAtShortcutIndex(index)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: [.command])
                .disabled(currentWorkspaceTabAction?.isAvailable != true)
            }
        }
    }
}
