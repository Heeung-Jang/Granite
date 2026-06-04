import SwiftUI

@MainActor
struct EditorFilePropertyAction {
    let isAvailable: Bool
    let perform: @MainActor () -> Void
}

private struct EditorFilePropertyActionKey: FocusedValueKey {
    typealias Value = EditorFilePropertyAction
}

extension FocusedValues {
    var editorFilePropertyAction: EditorFilePropertyAction? {
        get { self[EditorFilePropertyActionKey.self] }
        set { self[EditorFilePropertyActionKey.self] = newValue }
    }
}
