import SwiftUI

struct AppKitEditorBridgePlaceholder: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.string = ""
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

