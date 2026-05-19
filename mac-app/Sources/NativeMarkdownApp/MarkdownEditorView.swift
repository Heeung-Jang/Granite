import NativeMarkdownCore
import SwiftUI

@MainActor
struct MarkdownEditorView: NSViewRepresentable {
    @Binding var text: String
    var isEditable = true

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = MarkdownEditorTextViewFactory.makeTextView()
        textView.delegate = context.coordinator
        textView.string = text
        let decorationTimer = AppTelemetryTimer()
        MarkdownVisibleRangeDecorator.decorateVisibleRange(in: textView)
        AppTelemetry.editorDecorationCompleted(
            textLength: textView.string.count,
            durationMilliseconds: decorationTimer.elapsedMilliseconds()
        )
        context.coordinator.textView = textView

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(text: $text)
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }

        MarkdownEditorTextSynchronizer.applyExternalText(
            text,
            to: textView,
            isApplyingAppKitChange: context.coordinator.isApplyingAppKitChange
        )
        let decorationTimer = AppTelemetryTimer()
        MarkdownVisibleRangeDecorator.decorateVisibleRange(in: textView)
        AppTelemetry.editorDecorationCompleted(
            textLength: textView.string.count,
            durationMilliseconds: decorationTimer.elapsedMilliseconds()
        )
        textView.isEditable = isEditable
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        if let textView = scrollView.documentView as? NSTextView,
           textView.delegate === coordinator {
            textView.delegate = nil
        }
        coordinator.textView = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        weak var textView: NSTextView?
        var isApplyingAppKitChange = false

        init(text: Binding<String>) {
            _text = text
        }

        func update(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }

            isApplyingAppKitChange = true
            text = textView.string
            MarkdownVisibleRangeDecorator.decorateVisibleRange(in: textView)
            isApplyingAppKitChange = false
        }
    }
}

@MainActor
enum MarkdownEditorTextViewFactory {
    static func makeTextView() -> NSTextView {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.textContainer?.widthTracksTextView = true
        return textView
    }
}

@MainActor
enum MarkdownEditorTextSynchronizer {
    @discardableResult
    static func applyExternalText(
        _ text: String,
        to textView: NSTextView,
        isApplyingAppKitChange: Bool
    ) -> Bool {
        guard !isApplyingAppKitChange else {
            return false
        }
        guard textView.string != text else {
            return false
        }

        let selection = textView.selectedRange()
        textView.string = text
        textView.setSelectedRange(clamped(selection, for: text))
        return true
    }

    private static func clamped(_ range: NSRange, for text: String) -> NSRange {
        let length = (text as NSString).length
        let location = min(range.location, length)
        let maxLength = max(0, length - location)
        return NSRange(location: location, length: min(range.length, maxLength))
    }
}
