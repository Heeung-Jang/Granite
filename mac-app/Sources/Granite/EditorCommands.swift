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
                workspaceTabAction?.newTab()
            }
            .keyboardShortcut("t")
            .disabled(workspaceTabAction?.isAvailable != true)

            Button("Close Tab") {
                workspaceTabAction?.closeActiveTab()
            }
            .keyboardShortcut("w")
            .disabled(workspaceTabAction?.isAvailable != true)

            Button("Reopen Closed Tab") {
                workspaceTabAction?.restoreClosedTab()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(workspaceTabAction?.isAvailable != true)

            Divider()

            Button("Next Tab") {
                workspaceTabAction?.activateNextTab()
            }
            .keyboardShortcut(.tab, modifiers: [.control])
            .disabled(workspaceTabAction?.isAvailable != true)

            Button("Previous Tab") {
                workspaceTabAction?.activatePreviousTab()
            }
            .keyboardShortcut(.tab, modifiers: [.control, .shift])
            .disabled(workspaceTabAction?.isAvailable != true)

            Divider()

            ForEach(1...9, id: \.self) { index in
                Button(index == 9 ? "Last Tab" : "Tab \(index)") {
                    workspaceTabAction?.activateTabAtShortcutIndex(index)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: [.command])
                .disabled(workspaceTabAction?.isAvailable != true)
            }
        }
    }
}
