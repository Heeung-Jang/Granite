import SwiftUI

@MainActor
struct EditorSaveAction {
    let isAvailable: Bool
    let perform: @MainActor () -> Void
}

private struct EditorSaveActionKey: FocusedValueKey {
    typealias Value = EditorSaveAction
}

extension FocusedValues {
    var editorSaveAction: EditorSaveAction? {
        get { self[EditorSaveActionKey.self] }
        set { self[EditorSaveActionKey.self] = newValue }
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
