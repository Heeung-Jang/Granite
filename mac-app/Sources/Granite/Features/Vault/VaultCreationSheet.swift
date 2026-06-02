import AppKit
import NativeMarkdownCore
import SwiftUI

struct VaultCreationSheet: View {
    @Environment(\.appContentZoomScale) private var appContentZoomScale
    @State private var parentURL: URL?
    @State private var vaultName = ""
    @Binding var error: String?

    let submit: (VaultCreationRequest) -> Bool
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ObsidianUI.scaled(14, scale: appContentZoomScale)) {
            Text("Create New Vault")
                .font(.system(size: ObsidianUI.fontSize(18, scale: appContentZoomScale), weight: .semibold))

            VStack(alignment: .leading, spacing: ObsidianUI.scaled(6, scale: appContentZoomScale)) {
                Text("Parent folder")
                    .font(.system(size: ObsidianUI.fontSize(12, scale: appContentZoomScale), weight: .medium))

                HStack {
                    Text(parentURL?.path ?? "Choose a parent folder")
                        .font(.system(size: ObsidianUI.fontSize(12, scale: appContentZoomScale)))
                        .foregroundStyle(parentURL == nil ? .secondary : .primary)
                        .lineLimit(1)

                    Spacer()

                    Button("Choose...") {
                        chooseParentFolder()
                    }
                }
            }

            VStack(alignment: .leading, spacing: ObsidianUI.scaled(6, scale: appContentZoomScale)) {
                Text("Vault name")
                    .font(.system(size: ObsidianUI.fontSize(12, scale: appContentZoomScale), weight: .medium))
                TextField("Vault name", text: $vaultName)
                    .textFieldStyle(.roundedBorder)
            }

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
                Button("Create") {
                    create()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(parentURL == nil || vaultName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }

    private func chooseParentFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK {
            parentURL = panel.url
            error = nil
        }
    }

    private func create() {
        guard let parentURL else {
            return
        }
        let request = VaultCreationRequest(parentURL: parentURL, vaultName: vaultName)
        if submit(request) {
            error = nil
        }
    }
}
