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

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                editorSaveAction?.perform()
            }
            .keyboardShortcut("s")
            .disabled(editorSaveAction?.isAvailable != true)
        }
    }
}
