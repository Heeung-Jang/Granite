import SwiftUI

enum ObsidianUI {
    static let ribbonWidth: CGFloat = 48
    static let leftSidebarWidth: CGFloat = 272
    static let rightSidebarWidth: CGFloat = 300
    static let tabBarHeight: CGFloat = 43
    static let noteToolbarHeight: CGFloat = 42
    static let statusBarHeight: CGFloat = 26

    static let border = Color(nsColor: .separatorColor)
    static let ribbonBackground = Color(nsColor: .windowBackgroundColor)
    static let sidebarBackground = Color(nsColor: .controlBackgroundColor)
    static let editorBackground = Color(nsColor: .textBackgroundColor)
    static let selectedFill = Color(nsColor: .selectedContentBackgroundColor).opacity(0.13)
    static let hoverFill = Color.primary.opacity(0.06)
}
struct ObsidianIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    var isSelected = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? ObsidianUI.selectedFill : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }
}
