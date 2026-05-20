import AppKit
import NativeMarkdownCore
import SwiftUI

@MainActor
struct MarkdownEditorView: NSViewRepresentable {
    @Binding var text: String
    var isEditable = true
    var livePreviewMode: LivePreviewMode = .livePreview
    var linkStyleMap = LivePreviewLinkStyleMap()
    var embedPreviewMap = LivePreviewEmbedPreviewMap()
    var interactionHandler: ((MarkdownEditorInteraction) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            interactionHandler: interactionHandler,
            livePreviewMode: livePreviewMode,
            linkStyleMap: linkStyleMap,
            embedPreviewMap: embedPreviewMap
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = MarkdownEditorTextViewFactory.makeTextView()
        textView.string = text
        textView.isEditable = isEditable
        if let textView = textView as? MarkdownInteractionTextView {
            textView.livePreviewMode = livePreviewMode
        }
        let decorationTimer = AppTelemetryTimer()
        context.coordinator.decorateVisibleRange(in: textView)
        AppTelemetry.editorDecorationCompleted(
            textLength: textView.string.count,
            durationMilliseconds: decorationTimer.elapsedMilliseconds()
        )
        MarkdownEditorAccessibility.apply(to: textView, isEditable: isEditable, mode: livePreviewMode)
        context.coordinator.textView = textView
        textView.delegate = context.coordinator
        if let textView = textView as? MarkdownInteractionTextView {
            textView.interactionDelegate = context.coordinator
        }

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(
            text: $text,
            interactionHandler: interactionHandler,
            livePreviewMode: livePreviewMode,
            linkStyleMap: linkStyleMap,
            embedPreviewMap: embedPreviewMap
        )
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }

        MarkdownEditorTextSynchronizer.applyExternalText(
            text,
            to: textView,
            isApplyingAppKitChange: context.coordinator.isApplyingAppKitChange
        )
        let decorationTimer = AppTelemetryTimer()
        context.coordinator.decorateVisibleRange(in: textView)
        AppTelemetry.editorDecorationCompleted(
            textLength: textView.string.count,
            durationMilliseconds: decorationTimer.elapsedMilliseconds()
        )
        textView.isEditable = isEditable
        if let textView = textView as? MarkdownInteractionTextView {
            textView.livePreviewMode = livePreviewMode
        }
        MarkdownEditorAccessibility.apply(to: textView, isEditable: isEditable, mode: livePreviewMode)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        if let textView = scrollView.documentView as? NSTextView,
           textView.delegate === coordinator {
            textView.delegate = nil
        }
        if let textView = scrollView.documentView as? MarkdownInteractionTextView,
           textView.interactionDelegate === coordinator {
            textView.interactionDelegate = nil
        }
        coordinator.textView = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, MarkdownInteractionTextViewDelegate {
        @Binding private var text: String
        private var interactionHandler: ((MarkdownEditorInteraction) -> Void)?
        private var livePreviewMode: LivePreviewMode
        private var linkStyleMap: LivePreviewLinkStyleMap
        private var embedPreviewMap: LivePreviewEmbedPreviewMap
        private var isDecoratingLivePreview = false
        weak var textView: NSTextView?
        var isApplyingAppKitChange = false

        init(
            text: Binding<String>,
            interactionHandler: ((MarkdownEditorInteraction) -> Void)? = nil,
            livePreviewMode: LivePreviewMode = .livePreview,
            linkStyleMap: LivePreviewLinkStyleMap = LivePreviewLinkStyleMap(),
            embedPreviewMap: LivePreviewEmbedPreviewMap = LivePreviewEmbedPreviewMap()
        ) {
            _text = text
            self.interactionHandler = interactionHandler
            self.livePreviewMode = livePreviewMode
            self.linkStyleMap = linkStyleMap
            self.embedPreviewMap = embedPreviewMap
        }

        func update(
            text: Binding<String>,
            interactionHandler: ((MarkdownEditorInteraction) -> Void)?,
            livePreviewMode: LivePreviewMode,
            linkStyleMap: LivePreviewLinkStyleMap,
            embedPreviewMap: LivePreviewEmbedPreviewMap
        ) {
            _text = text
            self.interactionHandler = interactionHandler
            self.livePreviewMode = livePreviewMode
            self.linkStyleMap = linkStyleMap
            self.embedPreviewMap = embedPreviewMap
        }

        func textDidChange(_ notification: Notification) {
            guard !isDecoratingLivePreview else {
                return
            }
            guard let textView = notification.object as? NSTextView else {
                return
            }

            isApplyingAppKitChange = true
            text = textView.string
            renderCurrentSelection(in: textView)
            isApplyingAppKitChange = false
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isDecoratingLivePreview else {
                return
            }
            guard let textView = notification.object as? NSTextView else {
                return
            }
            renderCurrentSelection(in: textView)
        }

        func textView(_ textView: MarkdownInteractionTextView, handleMouseDown event: NSEvent) -> Bool {
            if textView.isEditable,
               let utf16Offset = textView.utf16Offset(for: event),
               textView.toggleTaskCheckbox(at: utf16Offset) {
                return true
            }

            guard !textView.isEditable || event.modifierFlags.contains(.command),
                  let utf16Offset = textView.utf16Offset(for: event),
                  let interaction = MarkdownEditorInteractionResolver.interaction(
                    in: textView.string,
                    utf16Offset: utf16Offset
                  )
            else {
                return false
            }

            interactionHandler?(interaction)
            return true
        }

        func decorateVisibleRange(in textView: NSTextView) {
            guard !isDecoratingLivePreview else {
                return
            }

            isDecoratingLivePreview = true
            defer { isDecoratingLivePreview = false }
            MarkdownVisibleRangeDecorator.decorateVisibleRange(
                in: textView,
                livePreviewMode: livePreviewMode,
                revealRange: textView.selectedRange(),
                linkStyleMap: linkStyleMap,
                embedPreviewMap: embedPreviewMap
            )
        }

        private func renderCurrentSelection(in textView: NSTextView) {
            decorateVisibleRange(in: textView)
        }
    }
}

@MainActor
enum MarkdownEditorTextViewFactory {
    static func makeTextView() -> NSTextView {
        let textView = MarkdownInteractionTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.textContainer?.widthTracksTextView = true
        MarkdownEditorAccessibility.apply(to: textView, isEditable: true, mode: .livePreview)
        textView.setAccessibilityIdentifier("markdown-editor")
        return textView
    }
}

@MainActor
enum MarkdownEditorAccessibility {
    static func apply(to textView: NSTextView, isEditable: Bool, mode: LivePreviewMode) {
        textView.setAccessibilityLabel(isEditable ? "Markdown editor" : "Markdown viewer")
        textView.setAccessibilityHelp(help(isEditable: isEditable, mode: mode))
    }

    private static func help(isEditable: Bool, mode: LivePreviewMode) -> String {
        switch mode {
        case .livePreview:
            isEditable
                ? "Live Preview editor. Edit properties, embeds, and tables as source, command-click links and tags, click task checkboxes to toggle them."
                : "Live Preview viewer. Review properties, embeds, and tables, click links and tags to open or search."
        case .source:
            "Source editor. Markdown syntax is shown as plain text."
        case .fallbackSource:
            "Fallback source editor. Live Preview is disabled for this note."
        }
    }
}

@MainActor
protocol MarkdownInteractionTextViewDelegate: AnyObject {
    func textView(_ textView: MarkdownInteractionTextView, handleMouseDown event: NSEvent) -> Bool
}

@MainActor
final class MarkdownInteractionTextView: NSTextView {
    weak var interactionDelegate: MarkdownInteractionTextViewDelegate?
    var livePreviewMode: LivePreviewMode = .livePreview
    private var tableCellMenuTarget: LivePreviewTableCell?

    override func mouseDown(with event: NSEvent) {
        if interactionDelegate?.textView(self, handleMouseDown: event) == true {
            return
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        tableCellMenuTarget = nil
        guard isEditable,
              let utf16Offset = utf16Offset(for: event),
              let cell = tableCellForEditing(at: utf16Offset)
        else {
            return menu
        }

        tableCellMenuTarget = cell
        let item = NSMenuItem(
            title: "Edit Table Cell...",
            action: #selector(editTableCellFromMenu(_:)),
            keyEquivalent: ""
        )
        item.target = self
        if !menu.items.isEmpty {
            menu.insertItem(.separator(), at: 0)
        }
        menu.insertItem(item, at: 0)
        return menu
    }

    override func paste(_ sender: Any?) {
        guard let pasted = NSPasteboard.general.string(forType: .string) else {
            return
        }
        let range = selectedRange()
        guard shouldChangeText(in: range, replacementString: pasted) else {
            return
        }
        replaceCharacters(in: range, with: pasted)
        didChangeText()
    }

    @discardableResult
    func toggleTaskCheckbox(at utf16Offset: Int) -> Bool {
        guard isEditable,
              let edit = MarkdownTaskCheckboxToggle.edit(in: string, utf16Offset: utf16Offset)
        else {
            return false
        }
        replaceTaskCheckbox(edit.tokenRange.nsRange, with: edit.replacement, registersUndo: true)
        return true
    }

    @discardableResult
    func replaceTableCell(_ cell: LivePreviewTableCell, with replacement: String) -> Bool {
        guard isEditable,
              LivePreviewTableCellEdit.replacing(cell: cell, with: replacement, in: string) != nil
        else {
            return false
        }
        replaceTableCell(cell.contentRange.nsRange, with: replacement, registersUndo: true)
        return true
    }

    func tableCellForEditing(at utf16Offset: Int) -> LivePreviewTableCell? {
        guard livePreviewMode == .livePreview else {
            return nil
        }
        return LivePreviewTableParser.cell(atUTF16Offset: utf16Offset, in: string)
    }

    func utf16Offset(for event: NSEvent) -> Int? {
        guard let layoutManager, let textContainer else {
            return nil
        }

        var point = convert(event.locationInWindow, from: nil)
        point.x -= textContainerOrigin.x
        point.y -= textContainerOrigin.y
        guard point.x >= 0, point.y >= 0 else {
            return nil
        }

        let glyphIndex = layoutManager.glyphIndex(for: point, in: textContainer)
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        return min(characterIndex, (string as NSString).length - 1)
    }

    @objc private func editTableCellFromMenu(_ sender: NSMenuItem) {
        guard let cell = tableCellMenuTarget else {
            return
        }
        presentTableCellEditor(for: cell)
    }

    private func replaceTaskCheckbox(_ range: NSRange, with replacement: String, registersUndo: Bool) {
        guard shouldChangeText(in: range, replacementString: replacement) else {
            return
        }
        let original = (string as NSString).substring(with: range)
        let selection = selectedRange()
        if registersUndo {
            undoManager?.registerUndo(withTarget: self) { textView in
                MainActor.assumeIsolated {
                    textView.replaceTaskCheckbox(range, with: original, registersUndo: true)
                }
            }
            undoManager?.setActionName("Toggle Checkbox")
        }
        replaceCharacters(in: range, with: replacement)
        didChangeText()
        setSelectedRange(NSRange(
            location: min(selection.location, (string as NSString).length),
            length: min(selection.length, max(0, (string as NSString).length - min(selection.location, (string as NSString).length)))
        ))
    }

    private func presentTableCellEditor(for cell: LivePreviewTableCell) {
        let alert = NSAlert()
        alert.messageText = "Edit Table Cell"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(string: cell.text)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        if !replaceTableCell(cell, with: field.stringValue) {
            NSSound.beep()
        }
    }

    private func replaceTableCell(_ range: NSRange, with replacement: String, registersUndo: Bool) {
        guard shouldChangeText(in: range, replacementString: replacement) else {
            return
        }
        let selection = selectedRange()
        if registersUndo {
            undoManager?.setActionName("Edit Table Cell")
        }
        replaceCharacters(in: range, with: replacement)
        didChangeText()
        setSelectedRange(NSRange(
            location: min(selection.location, (string as NSString).length),
            length: min(selection.length, max(0, (string as NSString).length - min(selection.location, (string as NSString).length)))
        ))
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
