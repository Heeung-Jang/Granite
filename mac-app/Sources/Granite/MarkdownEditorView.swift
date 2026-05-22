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
    var markerStyle: LivePreviewMarkerStyle = .defaultValue
    var documentTitle: String?
    var isActive = true
    var focusRequestID: UUID?
    var interactionHandler: ((MarkdownEditorInteractionRequest) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            interactionHandler: interactionHandler,
            livePreviewMode: livePreviewMode,
            linkStyleMap: linkStyleMap,
            embedPreviewMap: embedPreviewMap,
            markerStyle: markerStyle,
            documentTitle: documentTitle,
            focusRequestID: focusRequestID
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = MarkdownEditorTextViewFactory.makeTextView()
        textView.string = text
        textView.isEditable = isEditable
        if let textView = textView as? MarkdownInteractionTextView {
            textView.livePreviewMode = livePreviewMode
            textView.livePreviewMarkerStyle = markerStyle
            textView.livePreviewDocumentTitle = documentTitle
            textView.refreshLivePreviewOverlayState()
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
            embedPreviewMap: embedPreviewMap,
            markerStyle: markerStyle,
            documentTitle: documentTitle,
            focusRequestID: focusRequestID
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
            textView.livePreviewMarkerStyle = markerStyle
            textView.livePreviewDocumentTitle = documentTitle
            textView.refreshLivePreviewOverlayState()
        }
        MarkdownEditorAccessibility.apply(to: textView, isEditable: isEditable, mode: livePreviewMode)
        context.coordinator.applyFocusRequestIfNeeded(isActive: isActive, in: scrollView)
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
        private var interactionHandler: ((MarkdownEditorInteractionRequest) -> Void)?
        private var livePreviewMode: LivePreviewMode
        private var linkStyleMap: LivePreviewLinkStyleMap
        private var embedPreviewMap: LivePreviewEmbedPreviewMap
        private var markerStyle: LivePreviewMarkerStyle
        private var documentTitle: String?
        private var focusRequestID: UUID?
        private var appliedFocusRequestID: UUID?
        private var isDecoratingLivePreview = false
        private var decorationGeneration = 0
        weak var textView: NSTextView?
        var isApplyingAppKitChange = false

        init(
            text: Binding<String>,
            interactionHandler: ((MarkdownEditorInteractionRequest) -> Void)? = nil,
            livePreviewMode: LivePreviewMode = .livePreview,
            linkStyleMap: LivePreviewLinkStyleMap = LivePreviewLinkStyleMap(),
            embedPreviewMap: LivePreviewEmbedPreviewMap = LivePreviewEmbedPreviewMap(),
            markerStyle: LivePreviewMarkerStyle = .defaultValue,
            documentTitle: String? = nil,
            focusRequestID: UUID? = nil
        ) {
            _text = text
            self.interactionHandler = interactionHandler
            self.livePreviewMode = livePreviewMode
            self.linkStyleMap = linkStyleMap
            self.embedPreviewMap = embedPreviewMap
            self.markerStyle = markerStyle
            self.documentTitle = documentTitle
            self.focusRequestID = focusRequestID
        }

        func update(
            text: Binding<String>,
            interactionHandler: ((MarkdownEditorInteractionRequest) -> Void)?,
            livePreviewMode: LivePreviewMode,
            linkStyleMap: LivePreviewLinkStyleMap,
            embedPreviewMap: LivePreviewEmbedPreviewMap,
            markerStyle: LivePreviewMarkerStyle,
            documentTitle: String?,
            focusRequestID: UUID?
        ) {
            _text = text
            self.interactionHandler = interactionHandler
            self.livePreviewMode = livePreviewMode
            self.linkStyleMap = linkStyleMap
            self.embedPreviewMap = embedPreviewMap
            self.markerStyle = markerStyle
            self.documentTitle = documentTitle
            self.focusRequestID = focusRequestID
            if let textView = textView as? MarkdownInteractionTextView {
                textView.livePreviewDocumentTitle = documentTitle
                textView.livePreviewMarkerStyle = markerStyle
                textView.refreshLivePreviewOverlayState()
            }
        }

        func applyFocusRequestIfNeeded(isActive: Bool, in scrollView: NSScrollView) {
            guard isActive,
                  let focusRequestID,
                  appliedFocusRequestID != focusRequestID,
                  let textView = scrollView.documentView as? NSTextView
            else {
                return
            }
            appliedFocusRequestID = focusRequestID
            scrollView.window?.makeFirstResponder(textView)
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
            scheduleLivePreviewDecoration(in: textView, afterTextMutation: true)
            isApplyingAppKitChange = false
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isDecoratingLivePreview else {
                return
            }
            guard let textView = notification.object as? NSTextView else {
                return
            }
            scheduleLivePreviewDecoration(in: textView)
        }

        func textView(_ textView: MarkdownInteractionTextView, handleMouseDown event: NSEvent) -> Bool {
            if textView.isEditable,
               let utf16Offset = textView.taskCheckboxToggleOffset(for: event) ?? textView.utf16Offset(for: event),
               textView.toggleTaskCheckbox(at: utf16Offset) {
                return true
            }
            if textView.performTableControl(at: textView.convert(event.locationInWindow, from: nil)) {
                return true
            }
            if textView.setActiveTableCell(at: textView.convert(event.locationInWindow, from: nil)) {
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

            interactionHandler?(MarkdownEditorInteractionRequest(
                interaction: interaction,
                disposition: OpenDispositionResolver.resolve(
                    isCommandPressed: event.modifierFlags.contains(.command)
                )
            ))
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
                embedPreviewMap: embedPreviewMap,
                markerStyle: markerStyle
            )
            if let textView = textView as? MarkdownInteractionTextView {
                textView.livePreviewMarkerStyle = markerStyle
                textView.refreshLivePreviewOverlayState(revealRange: textView.selectedRange())
            }
        }

        private func renderCurrentSelection(in textView: NSTextView) {
            decorateVisibleRange(in: textView)
        }

        private func scheduleLivePreviewDecoration(
            in textView: NSTextView,
            afterTextMutation: Bool = false
        ) {
            if afterTextMutation {
                invalidateLayoutAfterTextMutation(in: textView)
            }

            decorationGeneration += 1
            let generation = decorationGeneration
            Task { @MainActor [weak self, weak textView] in
                guard let self,
                      let textView,
                      generation == self.decorationGeneration,
                      !self.isDecoratingLivePreview
                else {
                    return
                }

                self.renderCurrentSelection(in: textView)
                if let textContainer = textView.textContainer {
                    textView.layoutManager?.ensureLayout(for: textContainer)
                }
                textView.needsDisplay = true
            }
        }

        private func invalidateLayoutAfterTextMutation(in textView: NSTextView) {
            let textLength = (textView.string as NSString).length
            guard textLength > 0 else {
                textView.needsDisplay = true
                return
            }
            let fullRange = NSRange(location: 0, length: textLength)
            textView.layoutManager?.invalidateLayout(
                forCharacterRange: fullRange,
                actualCharacterRange: nil
            )
            textView.needsDisplay = true
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
        textView.font = LivePreviewTheme.baseFont
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 18, height: 18)
        textView.textContainer?.widthTracksTextView = true
        textView.layoutManager?.allowsNonContiguousLayout = true
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
                ? "Live Preview editor. Edit properties, embeds, and tables as source, use table row and column menus or plus controls, command-click links and tags, click task checkboxes to toggle them."
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
final class MarkdownInteractionTextView: NSTextView, NSTextFieldDelegate {
    weak var interactionDelegate: MarkdownInteractionTextViewDelegate?
    var livePreviewMode: LivePreviewMode = .livePreview {
        didSet {
            refreshLivePreviewOverlayState()
            needsDisplay = true
        }
    }
    var livePreviewMarkerStyle: LivePreviewMarkerStyle = .defaultValue {
        didSet {
            refreshLivePreviewOverlayState()
        }
    }
    var livePreviewDocumentTitle: String? {
        didSet {
            needsDisplay = true
        }
    }
    private(set) var livePreviewOverlayState = LivePreviewOverlayState()
    private var livePreviewOverlaySourceVersion = 0
    private var tableCellMenuTarget: LivePreviewTableCell?
    private(set) var tableCellEditor: NSTextField?
    private var tableCellEditorTarget: LivePreviewTableCell?
    private var tableCellEditorSelectionBeforeEdit: NSRange?
    private var isClosingTableCellEditor = false

    var activeTableCellEditorFrame: NSRect? {
        tableCellEditor?.frame
    }

    override func draw(_ dirtyRect: NSRect) {
        refreshLivePreviewOverlayState(syncEditor: false)
        let overlayState = livePreviewOverlayState
        super.draw(dirtyRect)
        LivePreviewOverlayRenderer.drawBackgrounds(in: self, dirtyRect: dirtyRect, state: overlayState)
        LivePreviewOverlayRenderer.drawForegrounds(in: self, dirtyRect: dirtyRect, state: overlayState)
    }

    override func didChangeText() {
        super.didChangeText()
        noteLivePreviewSourceChanged()
    }

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
              let cell = tableCellForEditing(at: convert(event.locationInWindow, from: nil)) ??
                utf16Offset(for: event).flatMap({ tableCellForEditing(at: $0) })
        else {
            return menu
        }

        tableCellMenuTarget = cell
        return tableContextMenu(for: cell, baseMenu: menu)
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(editTableCellFromMenu(_:)) {
            return currentTableMenuTarget() != nil
        }
        if menuItem.action == #selector(performTableOperationFromMenu(_:)) {
            guard let command = menuItem.representedObject as? TableMenuCommand,
                  let cell = currentTableMenuTarget()
            else {
                return false
            }
            return LivePreviewTableEdit.applying(command.operation, to: cell, in: string) != nil
        }
        return super.validateMenuItem(menuItem)
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

    func tableCellForEditing(at point: NSPoint) -> LivePreviewTableCell? {
        guard livePreviewMode == .livePreview else {
            return nil
        }
        return LivePreviewTableLayout.tableCell(at: point, in: self)
    }

    @discardableResult
    func setActiveTableCell(at point: NSPoint) -> Bool {
        refreshLivePreviewOverlayState()
        guard livePreviewOverlayState.allowsTransientControls,
              let cell = tableCellForEditing(at: point)
        else {
            setLivePreviewOverlayTableState(hovered: nil, active: nil)
            needsDisplay = true
            return false
        }
        setLivePreviewOverlayTableState(hovered: cell, active: cell)
        needsDisplay = true
        return true
    }

    @discardableResult
    func performTableControl(at point: NSPoint) -> Bool {
        refreshLivePreviewOverlayState()
        guard livePreviewOverlayState.allowsTransientControls,
              let cell = livePreviewOverlayState.activeTableCell,
              let layoutCell = LivePreviewTableLayout.layoutCell(for: cell, in: self)
        else {
            return false
        }
        let layout = LivePreviewTableParser.parse(string).compactMap { LivePreviewTableLayout.make(for: $0, in: self) }
            .first { $0.layoutCell(for: cell) != nil }
        guard let layout else {
            return false
        }
        if layout.rowAddControlRect(for: cell)?.contains(point) == true {
            return applyTableSourceEdit(LivePreviewTableEdit.applying(
                .insertRowAfter,
                to: layoutCell.tableCell,
                in: string
            ))
        }
        if layout.columnAddControlRect(for: cell)?.contains(point) == true {
            return applyTableSourceEdit(LivePreviewTableEdit.applying(
                .insertColumnAfter,
                to: layoutCell.tableCell,
                in: string
            ))
        }
        return false
    }

    func tableContextMenu(for cell: LivePreviewTableCell, baseMenu: NSMenu = NSMenu()) -> NSMenu {
        let menu = baseMenu
        let editItem = NSMenuItem(
            title: "Edit Table Cell...",
            action: #selector(editTableCellFromMenu(_:)),
            keyEquivalent: ""
        )
        editItem.target = self

        let rowItem = NSMenuItem(title: "Row", action: nil, keyEquivalent: "")
        rowItem.submenu = operationSubmenu(
            title: "Row",
            operations: [
                ("Insert Row Above", .insertRowBefore),
                ("Insert Row Below", .insertRowAfter),
                ("Move Row Up", .moveRowUp),
                ("Move Row Down", .moveRowDown),
                ("Duplicate Row", .duplicateRow),
                ("Remove Row", .removeRow)
            ]
        )

        let columnItem = NSMenuItem(title: "Column", action: nil, keyEquivalent: "")
        columnItem.submenu = operationSubmenu(
            title: "Column",
            operations: [
                ("Insert Column Left", .insertColumnBefore),
                ("Insert Column Right", .insertColumnAfter),
                ("Move Column Left", .moveColumnLeft),
                ("Move Column Right", .moveColumnRight),
                ("Align Left", .alignColumn(.left)),
                ("Align Center", .alignColumn(.center)),
                ("Align Right", .alignColumn(.right)),
                ("Duplicate Column", .duplicateColumn),
                ("Remove Column", .removeColumn),
                ("Sort Ascending", .sortColumnAscending),
                ("Sort Descending", .sortColumnDescending)
            ]
        )

        if !menu.items.isEmpty {
            menu.insertItem(.separator(), at: 0)
        }
        menu.insertItem(columnItem, at: 0)
        menu.insertItem(rowItem, at: 0)
        menu.insertItem(editItem, at: 0)
        tableCellMenuTarget = cell
        return menu
    }

    func tableContextMenuOperationIDs(for cell: LivePreviewTableCell) -> [String] {
        tableContextMenu(for: cell).items.flatMap(operationIDs(in:))
    }

    @discardableResult
    func performTableMenuOperation(
        _ operation: LivePreviewTableOperation,
        for cell: LivePreviewTableCell
    ) -> Bool {
        guard isEditable, livePreviewMode == .livePreview else {
            return false
        }
        tableCellMenuTarget = cell
        guard prepareForTableStructureOperation(),
              let currentCell = currentTableMenuTarget()
        else {
            return false
        }
        return applyTableSourceEdit(LivePreviewTableEdit.applying(operation, to: currentCell, in: string))
    }

    func refreshLivePreviewOverlayState(revealRange: NSRange? = nil, syncEditor: Bool = true) {
        livePreviewOverlayState = livePreviewOverlayState.synchronized(
            mode: livePreviewMode,
            markerStyle: livePreviewMarkerStyle,
            revealRange: revealRange ?? selectedRange(),
            sourceVersion: livePreviewOverlaySourceVersion,
            isEditable: isEditable,
            hasMarkedText: hasMarkedText(),
            isSelectionDragActive: false
        )
        if syncEditor {
            syncTableCellEditor()
        }
    }

    func noteLivePreviewSourceChanged() {
        livePreviewOverlaySourceVersion += 1
        refreshLivePreviewOverlayState()
    }

    func setLivePreviewOverlayTableState(
        hovered: LivePreviewTableCell?,
        active: LivePreviewTableCell?
    ) {
        livePreviewOverlayState = livePreviewOverlayState.withTableCells(
            hovered: hovered,
            active: active
        )
        syncTableCellEditor()
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

    func taskCheckboxToggleOffset(for event: NSEvent) -> Int? {
        taskCheckboxToggleOffset(at: convert(event.locationInWindow, from: nil))
    }

    func taskCheckboxToggleOffset(at point: NSPoint) -> Int? {
        refreshLivePreviewOverlayState()
        guard let tokenRange = LivePreviewOverlayRenderer.taskCheckboxTokenRange(
            at: point,
            in: self,
            state: livePreviewOverlayState
        ) else {
            return nil
        }
        return tokenRange.location + min(1, max(0, tokenRange.length - 1))
    }

    @objc private func editTableCellFromMenu(_ sender: NSMenuItem) {
        guard let cell = currentTableMenuTarget() else {
            return
        }
        presentTableCellEditor(for: cell)
    }

    @objc private func performTableOperationFromMenu(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? TableMenuCommand,
              let cell = currentTableMenuTarget(),
              performTableMenuOperation(command.operation, for: cell)
        else {
            NSSound.beep()
            return
        }
    }

    private func operationSubmenu(
        title: String,
        operations: [(String, LivePreviewTableOperation)]
    ) -> NSMenu {
        let menu = NSMenu(title: title)
        for (title, operation) in operations {
            let item = NSMenuItem(
                title: title,
                action: #selector(performTableOperationFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = TableMenuCommand(operation: operation)
            menu.addItem(item)
        }
        return menu
    }

    private func operationIDs(in item: NSMenuItem) -> [String] {
        if let command = item.representedObject as? TableMenuCommand {
            return [command.operation.identifier]
        }
        return item.submenu?.items.flatMap(operationIDs(in:)) ?? []
    }

    private func currentTableMenuTarget() -> LivePreviewTableCell? {
        guard let target = tableCellMenuTarget else {
            return nil
        }
        let cells = LivePreviewTableParser.parse(string).flatMap { [$0.header] + $0.bodyRows }.flatMap { $0 }
        if let current = cells.first(where: {
            $0.sourceRange.location == target.sourceRange.location
                && $0.columnIndex == target.columnIndex
        }) {
            return current
        }
        let fallbackOffset = min(target.contentRange.location, max(0, (string as NSString).length - 1))
        return LivePreviewTableParser.cell(atUTF16Offset: fallbackOffset, in: string).flatMap {
            $0.columnIndex == target.columnIndex ? $0 : nil
        }
    }

    private func prepareForTableStructureOperation() -> Bool {
        guard tableCellEditor != nil else {
            return true
        }
        return commitActiveTableCellEditor()
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

    private func applyTableSourceEdit(_ edit: LivePreviewTableSourceEdit?) -> Bool {
        guard let edit,
              let range = LivePreviewRangeMapper.stringRange(for: edit.replacementRange, in: string),
              String(string[range]) != edit.replacement,
              shouldChangeText(in: edit.replacementRange.nsRange, replacementString: edit.replacement)
        else {
            return false
        }
        let selection = selectedRange()
        replaceCharacters(in: edit.replacementRange.nsRange, with: edit.replacement)
        didChangeText()
        undoManager?.setActionName(edit.actionName)
        setSelectedRange(NSRange(
            location: min(selection.location, (string as NSString).length),
            length: min(selection.length, max(0, (string as NSString).length - min(selection.location, (string as NSString).length)))
        ))
        setLivePreviewOverlayTableState(hovered: nil, active: nil)
        return true
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

    private func syncTableCellEditor() {
        guard livePreviewOverlayState.allowsTransientControls,
              let cell = livePreviewOverlayState.activeTableCell,
              let layoutCell = LivePreviewTableLayout.layoutCell(for: cell, in: self)
        else {
            removeTableCellEditor()
            return
        }
        updateTableCellEditor(for: cell, frame: layoutCell.textRect.insetBy(dx: -2, dy: -2))
    }

    private func updateTableCellEditor(for cell: LivePreviewTableCell, frame: NSRect) {
        let editor: NSTextField
        if let existing = tableCellEditor {
            editor = existing
        } else {
            let field = NSTextField(string: cell.text)
            field.isBordered = false
            field.isBezeled = false
            field.drawsBackground = true
            field.backgroundColor = LivePreviewTheme.tableCellBackgroundColor
            field.font = LivePreviewTheme.baseFont
            field.focusRingType = .none
            field.usesSingleLineMode = true
            field.lineBreakMode = .byTruncatingTail
            field.delegate = self
            addSubview(field)
            editor = field
            tableCellEditor = field
        }

        if tableCellEditorTarget != cell {
            editor.stringValue = cell.text
            tableCellEditorSelectionBeforeEdit = selectedRange()
        }
        tableCellEditorTarget = cell
        editor.frame = frame
        if window?.firstResponder !== editor.currentEditor() {
            window?.makeFirstResponder(editor)
        }
    }

    private func removeTableCellEditor() {
        tableCellEditor?.delegate = nil
        tableCellEditor?.removeFromSuperview()
        tableCellEditor = nil
        tableCellEditorTarget = nil
        tableCellEditorSelectionBeforeEdit = nil
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard control === tableCellEditor else {
            return false
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            _ = commitActiveTableCellEditor()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelActiveTableCellEditor()
            return true
        }
        return false
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === tableCellEditor else {
            return
        }
        tableCellEditor?.backgroundColor = LivePreviewTheme.tableCellBackgroundColor
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === tableCellEditor,
              !isClosingTableCellEditor
        else {
            return
        }
        _ = commitActiveTableCellEditor()
    }

    @discardableResult
    func commitActiveTableCellEditor() -> Bool {
        guard let editor = tableCellEditor,
              let target = tableCellEditorTarget,
              (editor.currentEditor() as? NSTextView)?.hasMarkedText() != true,
              let currentCell = LivePreviewTableParser.cell(
                atUTF16Offset: target.contentRange.location,
                in: string
              ),
              currentCell == target,
              LivePreviewTableCellEdit.replacing(cell: currentCell, with: editor.stringValue, in: string) != nil
        else {
            markTableCellEditorInvalid()
            return false
        }

        let selection = tableCellEditorSelectionBeforeEdit
        isClosingTableCellEditor = true
        defer { isClosingTableCellEditor = false }
        guard replaceTableCell(currentCell, with: editor.stringValue) else {
            markTableCellEditorInvalid()
            return false
        }
        setLivePreviewOverlayTableState(hovered: nil, active: nil)
        window?.makeFirstResponder(self)
        restoreSelection(selection)
        return true
    }

    func cancelActiveTableCellEditor() {
        let selection = tableCellEditorSelectionBeforeEdit
        isClosingTableCellEditor = true
        defer { isClosingTableCellEditor = false }
        setLivePreviewOverlayTableState(hovered: nil, active: nil)
        window?.makeFirstResponder(self)
        restoreSelection(selection)
    }

    private func markTableCellEditorInvalid() {
        tableCellEditor?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.14)
        NSSound.beep()
    }

    private func restoreSelection(_ selection: NSRange?) {
        guard let selection else {
            return
        }
        setSelectedRange(NSRange(
            location: min(selection.location, (string as NSString).length),
            length: min(selection.length, max(0, (string as NSString).length - min(selection.location, (string as NSString).length)))
        ))
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

private final class TableMenuCommand: NSObject {
    let operation: LivePreviewTableOperation

    init(operation: LivePreviewTableOperation) {
        self.operation = operation
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
        if let textView = textView as? MarkdownInteractionTextView {
            textView.noteLivePreviewSourceChanged()
        }
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
