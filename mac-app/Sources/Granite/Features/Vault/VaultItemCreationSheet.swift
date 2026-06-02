import SwiftUI

enum VaultItemCreationKind: String {
    case note
    case folder

    var title: String {
        switch self {
        case .note:
            return "New note"
        case .folder:
            return "New folder"
        }
    }

    var actionTitle: String {
        switch self {
        case .note:
            return "Create Note"
        case .folder:
            return "Create Folder"
        }
    }
}

struct VaultItemCreationSheet: View {
    @Environment(\.appContentZoomScale) private var appContentZoomScale
    @State private var name: String
    @Binding var error: String?

    let kind: VaultItemCreationKind
    let submit: (String) -> Bool
    let cancel: () -> Void

    init(
        kind: VaultItemCreationKind,
        defaultName: String,
        error: Binding<String?>,
        submit: @escaping (String) -> Bool,
        cancel: @escaping () -> Void
    ) {
        self.kind = kind
        self._name = State(initialValue: defaultName)
        self._error = error
        self.submit = submit
        self.cancel = cancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ObsidianUI.scaled(14, scale: appContentZoomScale)) {
            Text(kind.title)
                .font(.system(size: ObsidianUI.fontSize(18, scale: appContentZoomScale), weight: .semibold))

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)

            if let error {
                Text(error)
                    .font(.system(size: ObsidianUI.fontSize(12, scale: appContentZoomScale)))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(kind.actionTitle) {
                    if submit(name) {
                        error = nil
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }
}
