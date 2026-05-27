import NativeMarkdownCore
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

    static func normalizedScale(_ scale: Double) -> CGFloat {
        CGFloat(AppContentZoom(rawScale: scale).scale)
    }

    static func scaled(_ value: CGFloat, scale: Double) -> CGFloat {
        value * normalizedScale(scale)
    }

    static func ribbonWidth(scale: Double) -> CGFloat {
        scaled(ribbonWidth, scale: scale)
    }

    static func tabBarHeight(scale: Double) -> CGFloat {
        scaled(tabBarHeight, scale: scale)
    }

    static func noteToolbarHeight(scale: Double) -> CGFloat {
        scaled(noteToolbarHeight, scale: scale)
    }

    static func statusBarHeight(scale: Double) -> CGFloat {
        scaled(statusBarHeight, scale: scale)
    }

    static func iconButtonSize(scale: Double) -> CGFloat {
        scaled(30, scale: scale)
    }

    static func iconFontSize(scale: Double) -> CGFloat {
        scaled(16, scale: scale)
    }

    static func iconCornerRadius(scale: Double) -> CGFloat {
        scaled(6, scale: scale)
    }

    static func fontSize(_ value: CGFloat, scale: Double) -> CGFloat {
        scaled(value, scale: scale)
    }

    static func displayedPaneWidth(logicalWidth: Double, scale: Double) -> CGFloat {
        CGFloat(logicalWidth) * normalizedScale(scale)
    }

    static func logicalPaneWidth(displayedWidth: CGFloat, scale: Double) -> Double {
        Double(displayedWidth / normalizedScale(scale))
    }

    static func logicalWorkspaceAvailableWidth(displayedWidth: CGFloat, scale: Double) -> Double {
        let displayedWorkspaceWidth = max(0, displayedWidth - ribbonWidth(scale: scale))
        return logicalPaneWidth(displayedWidth: displayedWorkspaceWidth, scale: scale)
    }
}
struct ObsidianIconButton: View {
    @Environment(\.appContentZoomScale) private var appContentZoomScale
    let systemName: String
    let accessibilityLabel: String
    var isSelected = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(
                    size: ObsidianUI.iconFontSize(scale: appContentZoomScale),
                    weight: isSelected ? .semibold : .regular
                ))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(
                    width: ObsidianUI.iconButtonSize(scale: appContentZoomScale),
                    height: ObsidianUI.iconButtonSize(scale: appContentZoomScale)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? ObsidianUI.selectedFill : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: ObsidianUI.iconCornerRadius(scale: appContentZoomScale)))
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }
}
