import NativeMarkdownCore
import SwiftUI

enum ObsidianPaneSplitSide {
    case left
    case right

    var accessibilityLabel: String {
        switch self {
        case .left:
            return "Resize left sidebar"
        case .right:
            return "Resize right inspector"
        }
    }

    func proposedWidth(startWidth: Double, translationWidth: Double) -> Double {
        switch self {
        case .left:
            return WorkspacePaneLayout.proposedLeftSidebarWidth(
                startWidth: startWidth,
                translationWidth: translationWidth
            )
        case .right:
            return WorkspacePaneLayout.proposedRightSidebarWidth(
                startWidth: startWidth,
                translationWidth: translationWidth
            )
        }
    }
}

struct ObsidianPaneSplitHandle: View {
    let side: ObsidianPaneSplitSide
    let currentWidth: Double
    let onResize: (Double) -> Void

    @State private var isHovering = false
    @State private var dragStartWidth: Double?

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 7)
            .overlay(alignment: .center) {
                Rectangle()
                    .fill(isHovering || dragStartWidth != nil ? Color.accentColor.opacity(0.65) : ObsidianUI.border)
                    .frame(width: 1)
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let startWidth = dragStartWidth ?? currentWidth
                        if dragStartWidth == nil {
                            dragStartWidth = startWidth
                        }
                        onResize(side.proposedWidth(
                            startWidth: startWidth,
                            translationWidth: value.translation.width
                        ))
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                    }
            )
            .accessibilityLabel(side.accessibilityLabel)
            .accessibilityValue("\(Int(currentWidth.rounded())) points")
    }
}
