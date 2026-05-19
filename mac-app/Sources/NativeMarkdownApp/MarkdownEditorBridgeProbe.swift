import AppKit
import Foundation
import SwiftUI

struct MarkdownEditorBridgeProbeReport: Codable, Equatable {
    var sameTextSkippedUpdate: Bool
    var sameTextSelectionPreserved: Bool
    var externalTextApplied: Bool
    var externalTextSelectionPreserved: Bool
    var shortExternalTextClampedSelection: Bool
    var appKitChangeSkippedExternalSync: Bool
    var coordinatorUpdatedBinding: Bool
}

@MainActor
enum MarkdownEditorBridgeProbe {
    static func encodedReport() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try! encoder.encode(run())
        return String(decoding: data, as: UTF8.self)
    }

    static func run() -> MarkdownEditorBridgeProbeReport {
        let sameTextProbe = probeSameTextUpdate()
        let externalTextProbe = probeExternalTextUpdate()
        let clampedProbe = probeClampedSelection()
        let appKitChangeProbe = probeAppKitChangeSkip()
        let coordinatorProbe = probeCoordinatorBinding()

        return MarkdownEditorBridgeProbeReport(
            sameTextSkippedUpdate: sameTextProbe.skipped,
            sameTextSelectionPreserved: sameTextProbe.selectionPreserved,
            externalTextApplied: externalTextProbe.applied,
            externalTextSelectionPreserved: externalTextProbe.selectionPreserved,
            shortExternalTextClampedSelection: clampedProbe,
            appKitChangeSkippedExternalSync: appKitChangeProbe,
            coordinatorUpdatedBinding: coordinatorProbe
        )
    }

    private static func probeSameTextUpdate() -> (skipped: Bool, selectionPreserved: Bool) {
        let textView = MarkdownEditorTextViewFactory.makeTextView()
        textView.string = "abcdef"
        let selection = NSRange(location: 2, length: 2)
        textView.setSelectedRange(selection)

        let applied = MarkdownEditorTextSynchronizer.applyExternalText(
            "abcdef",
            to: textView,
            isApplyingAppKitChange: false
        )

        return (!applied, NSEqualRanges(textView.selectedRange(), selection))
    }

    private static func probeExternalTextUpdate() -> (applied: Bool, selectionPreserved: Bool) {
        let textView = MarkdownEditorTextViewFactory.makeTextView()
        textView.string = "abcdef"
        let selection = NSRange(location: 2, length: 2)
        textView.setSelectedRange(selection)

        let applied = MarkdownEditorTextSynchronizer.applyExternalText(
            "abcXYZdef",
            to: textView,
            isApplyingAppKitChange: false
        )

        return (applied, textView.string == "abcXYZdef" && NSEqualRanges(textView.selectedRange(), selection))
    }

    private static func probeClampedSelection() -> Bool {
        let textView = MarkdownEditorTextViewFactory.makeTextView()
        textView.string = "abcdef"
        textView.setSelectedRange(NSRange(location: 5, length: 1))

        let applied = MarkdownEditorTextSynchronizer.applyExternalText(
            "xy",
            to: textView,
            isApplyingAppKitChange: false
        )

        return applied && NSEqualRanges(textView.selectedRange(), NSRange(location: 2, length: 0))
    }

    private static func probeAppKitChangeSkip() -> Bool {
        let textView = MarkdownEditorTextViewFactory.makeTextView()
        textView.string = "appkit"

        let applied = MarkdownEditorTextSynchronizer.applyExternalText(
            "swiftui",
            to: textView,
            isApplyingAppKitChange: true
        )

        return !applied && textView.string == "appkit"
    }

    private static func probeCoordinatorBinding() -> Bool {
        var modelText = "before"
        let binding = Binding<String>(
            get: { modelText },
            set: { modelText = $0 }
        )
        let coordinator = MarkdownEditorView.Coordinator(text: binding)
        let textView = MarkdownEditorTextViewFactory.makeTextView()
        textView.string = "after"
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))

        return modelText == "after"
    }
}
