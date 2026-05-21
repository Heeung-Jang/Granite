import SwiftUI

struct GraniteHelpView: View {
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Granite Help")
                    .font(.title2.weight(.semibold))

                Spacer()

                Button("Done", action: dismiss)
                    .keyboardShortcut(.cancelAction)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HelpSection(
                        title: "Vaults",
                        text: "Open a folder of Markdown files, switch vaults from the bottom-left vault switcher, and use Vault actions to reveal or close the current vault."
                    )

                    HelpSection(
                        title: "Editing",
                        text: "Granite protects unsaved edits before closing the current note, opening a blank workspace, closing a vault, or quitting the app."
                    )

                    HelpSection(
                        title: "Workspace",
                        text: "Use the left ribbon for Files, Search, Bookmarks, Help, and Settings. The tab close and plus buttons clear the current note selection in this version."
                    )
                }
                .padding(20)
            }
        }
    }
}

private struct HelpSection: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)

            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
