import AppKit
import Foundation
import NativeMarkdownCore

struct MarkdownDecorationResult: Codable, Equatable {
    var mode: String
    var reason: String?
    var rangeLength: Int
    var appliedRuns: Int
    var changedRangeCount: Int
    var changedUTF16Length: Int
    var elapsedMilliseconds: Double
}

@MainActor
enum MarkdownVisibleRangeDecorator {
    @discardableResult
    static func decorateVisibleRange(
        in textView: NSTextView,
        range requestedRange: NSRange? = nil,
        livePreviewMode: LivePreviewMode = .livePreview,
        revealRange: NSRange? = nil,
        linkStyleMap: LivePreviewLinkStyleMap = LivePreviewLinkStyleMap()
    ) -> MarkdownDecorationResult {
        LivePreviewRenderer.render(
            in: textView,
            range: requestedRange,
            mode: livePreviewMode,
            revealRange: revealRange,
            linkStyleMap: linkStyleMap
        )
    }
}
