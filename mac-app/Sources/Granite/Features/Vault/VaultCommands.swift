import SwiftUI

@MainActor
struct VaultCommandAction {
    let newVault: @MainActor () -> Void
}

private struct VaultCommandActionKey: FocusedValueKey {
    typealias Value = VaultCommandAction
}

extension FocusedValues {
    var vaultCommandAction: VaultCommandAction? {
        get { self[VaultCommandActionKey.self] }
        set { self[VaultCommandActionKey.self] = newValue }
    }
}

struct VaultCommands: Commands {
    @FocusedValue(\.vaultCommandAction) private var vaultCommandAction

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Vault...") {
                vaultCommandAction?.newVault()
            }
            .disabled(vaultCommandAction == nil)
        }
    }
}
