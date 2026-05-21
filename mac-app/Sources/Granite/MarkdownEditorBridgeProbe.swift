import AppKit
import Foundation
import NativeMarkdownCore
import SwiftUI

struct MarkdownEditorBridgeProbeReport: Codable, Equatable {
    var sameTextSkippedUpdate: Bool
    var sameTextSelectionPreserved: Bool
    var externalTextApplied: Bool
    var externalTextSelectionPreserved: Bool
    var shortExternalTextClampedSelection: Bool
    var appKitChangeSkippedExternalSync: Bool
    var coordinatorUpdatedBinding: Bool
    var modeTransitionsPreservedText: Bool
    var modeTransitionsPreservedSelection: Bool
    var modeTransitionsPreservedDirtyState: Bool
    var modeTransitionsKeptUndoEnabled: Bool
    var livePreviewReportsChangedRanges: Bool
    var livePreviewNoOpRenderSkipsChanges: Bool
    var caretRevealRestoresHiddenSyntaxColor: Bool
    var inlineConcealmentAppliesBeyondParagraph: Bool
    var tagMarkersConcealed: Bool
    var markedTextRenderDeferred: Bool
    var sourceModeClearsLivePreviewAttributes: Bool
    var sourceEquivalentSelectionText: Bool
    var markdownImageEmbedDelimitersConcealed: Bool
    var safeMarkdownLinkTargetsConcealed: Bool
    var embedPreviewMapUpdatePreservesSelection: Bool
    var selectionChangeDecorationDoesNotReenter: Bool
    var unsafeMarkdownLinkTargetsRemainVisible: Bool
    var unsafeWikiLinkTargetsRemainVisible: Bool
    var plainTextPastePolicy: Bool
    var checkboxToggleChangesOnlyToken: Bool
    var checkboxToggleUndoRestoresToken: Bool
    var checkboxToggleReadOnlyPreservesBuffer: Bool
    var tableCellContextMenuResolvesCell: Bool
    var tableCellContextMenuSkipsFallback: Bool
    var tableCellEditChangesOnlyCell: Bool
    var tableCellEditUndoRestoresCell: Bool
    var tableCellEditFailurePreservesBuffer: Bool
    var editorAccessibilityHelpMentionsInteractions: Bool
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
        let modeProbe = probeModeTransitions()
        let renderProbe = probeLivePreviewRendering()
        let selectionChangeProbe = probeSelectionChangeDecorationDoesNotReenter()
        let checkboxProbe = probeCheckboxToggle()
        let tableCellProbe = probeTableCellEdit()
        let accessibilityProbe = probeEditorAccessibility()

        return MarkdownEditorBridgeProbeReport(
            sameTextSkippedUpdate: sameTextProbe.skipped,
            sameTextSelectionPreserved: sameTextProbe.selectionPreserved,
            externalTextApplied: externalTextProbe.applied,
            externalTextSelectionPreserved: externalTextProbe.selectionPreserved,
            shortExternalTextClampedSelection: clampedProbe,
            appKitChangeSkippedExternalSync: appKitChangeProbe,
            coordinatorUpdatedBinding: coordinatorProbe,
            modeTransitionsPreservedText: modeProbe.textPreserved,
            modeTransitionsPreservedSelection: modeProbe.selectionPreserved,
            modeTransitionsPreservedDirtyState: modeProbe.dirtyStatePreserved,
            modeTransitionsKeptUndoEnabled: modeProbe.undoEnabled,
            livePreviewReportsChangedRanges: renderProbe.reportsChangedRanges,
            livePreviewNoOpRenderSkipsChanges: renderProbe.noOpRenderSkipsChanges,
            caretRevealRestoresHiddenSyntaxColor: renderProbe.caretRevealRestoresHiddenSyntaxColor,
            inlineConcealmentAppliesBeyondParagraph: renderProbe.inlineConcealmentAppliesBeyondParagraph,
            tagMarkersConcealed: renderProbe.tagMarkersConcealed,
            markedTextRenderDeferred: renderProbe.markedTextRenderDeferred,
            sourceModeClearsLivePreviewAttributes: renderProbe.sourceModeClearsLivePreviewAttributes,
            sourceEquivalentSelectionText: renderProbe.sourceEquivalentSelectionText,
            markdownImageEmbedDelimitersConcealed: renderProbe.markdownImageEmbedDelimitersConcealed,
            safeMarkdownLinkTargetsConcealed: renderProbe.safeMarkdownLinkTargetsConcealed,
            embedPreviewMapUpdatePreservesSelection: renderProbe.embedPreviewMapUpdatePreservesSelection,
            selectionChangeDecorationDoesNotReenter: selectionChangeProbe,
            unsafeMarkdownLinkTargetsRemainVisible: renderProbe.unsafeMarkdownLinkTargetsRemainVisible,
            unsafeWikiLinkTargetsRemainVisible: renderProbe.unsafeWikiLinkTargetsRemainVisible,
            plainTextPastePolicy: renderProbe.plainTextPastePolicy,
            checkboxToggleChangesOnlyToken: checkboxProbe.changesOnlyToken,
            checkboxToggleUndoRestoresToken: checkboxProbe.undoRestoresToken,
            checkboxToggleReadOnlyPreservesBuffer: checkboxProbe.readOnlyPreservesBuffer,
            tableCellContextMenuResolvesCell: tableCellProbe.contextMenuResolvesCell,
            tableCellContextMenuSkipsFallback: tableCellProbe.contextMenuSkipsFallback,
            tableCellEditChangesOnlyCell: tableCellProbe.changesOnlyCell,
            tableCellEditUndoRestoresCell: tableCellProbe.undoRestoresCell,
            tableCellEditFailurePreservesBuffer: tableCellProbe.failurePreservesBuffer,
            editorAccessibilityHelpMentionsInteractions: accessibilityProbe
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

    private static func probeModeTransitions() -> (
        textPreserved: Bool,
        selectionPreserved: Bool,
        dirtyStatePreserved: Bool,
        undoEnabled: Bool
    ) {
        let text = "# Heading\n\n**Strong** and `code` with [[Link]]\n"
        let selection = NSRange(location: 4, length: 7)
        let textView = MarkdownEditorTextViewFactory.makeTextView()
        textView.string = text
        textView.setSelectedRange(selection)
        var saveSession = EditorSaveSession(file: FileTreeItem(relativePath: "Probe.md"), contents: text)
        saveSession.updateContents("\(text)Edited\n")
        let saveSessionBefore = saveSession

        MarkdownVisibleRangeDecorator.decorateVisibleRange(in: textView, livePreviewMode: .livePreview)
        MarkdownVisibleRangeDecorator.decorateVisibleRange(in: textView, livePreviewMode: .source)
        MarkdownVisibleRangeDecorator.decorateVisibleRange(
            in: textView,
            livePreviewMode: .fallbackSource(reason: .fileTooLarge)
        )

        return (
            textView.string == text,
            NSEqualRanges(textView.selectedRange(), selection),
            saveSession == saveSessionBefore && saveSession.isDirty,
            textView.allowsUndo
        )
    }

    private static func probeLivePreviewRendering() -> (
        reportsChangedRanges: Bool,
        noOpRenderSkipsChanges: Bool,
        caretRevealRestoresHiddenSyntaxColor: Bool,
        inlineConcealmentAppliesBeyondParagraph: Bool,
        tagMarkersConcealed: Bool,
        markedTextRenderDeferred: Bool,
        sourceModeClearsLivePreviewAttributes: Bool,
        sourceEquivalentSelectionText: Bool,
        markdownImageEmbedDelimitersConcealed: Bool,
        safeMarkdownLinkTargetsConcealed: Bool,
        embedPreviewMapUpdatePreservesSelection: Bool,
        unsafeMarkdownLinkTargetsRemainVisible: Bool,
        unsafeWikiLinkTargetsRemainVisible: Bool,
        plainTextPastePolicy: Bool
    ) {
        let text = "# **Heading**\n\n**Strong** and `code` with [[Link]] #tag/native\n"
        let textView = MarkdownEditorTextViewFactory.makeTextView()
        textView.string = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))

        let hiddenResult = MarkdownVisibleRangeDecorator.decorateVisibleRange(
            in: textView,
            livePreviewMode: .livePreview,
            revealRange: textView.selectedRange()
        )
        let hiddenHeadingColor = textView.textStorage?.attribute(
            .foregroundColor,
            at: 0,
            effectiveRange: nil
        ) as? NSColor
        let hiddenHeadingInlineTokenColor = foregroundColor(in: textView, text: text, marker: "**Heading")
        let hiddenStrongInlineTokenColor = foregroundColor(in: textView, text: text, marker: "**Strong")
        let hiddenTagMarkerColor = foregroundColor(in: textView, text: text, marker: "#tag")
        let noOpResult = MarkdownVisibleRangeDecorator.decorateVisibleRange(
            in: textView,
            livePreviewMode: .livePreview,
            revealRange: textView.selectedRange()
        )

        textView.setSelectedRange(NSRange(location: (text as NSString).range(of: "Strong").location, length: 0))
        MarkdownVisibleRangeDecorator.decorateVisibleRange(
            in: textView,
            livePreviewMode: .livePreview,
            revealRange: textView.selectedRange()
        )
        let revealedStrongInlineTokenColor = foregroundColor(in: textView, text: text, marker: "**Strong")

        MarkdownVisibleRangeDecorator.decorateVisibleRange(in: textView, livePreviewMode: .source)
        let sourceHeadingColor = textView.textStorage?.attribute(
            .foregroundColor,
            at: 0,
            effectiveRange: nil
        ) as? NSColor
        let sourceHeadingFont = textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let sourceStrongFont = font(in: textView, text: text, marker: "Strong")
        let sourceModeClearsLivePreviewAttributes = sourceHeadingColor != LivePreviewTheme.concealedColor
            && sourceHeadingFont == LivePreviewTheme.sourceFont
            && sourceStrongFont == LivePreviewTheme.sourceFont

        let markedTextView = MarkdownEditorTextViewFactory.makeTextView()
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        scrollView.documentView = markedTextView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentView = scrollView
        window.makeFirstResponder(markedTextView)
        markedTextView.string = text
        markedTextView.setMarkedText(
            "한글",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let markedResult = MarkdownVisibleRangeDecorator.decorateVisibleRange(
            in: markedTextView,
            livePreviewMode: .livePreview,
            revealRange: markedTextView.selectedRange()
        )
        let markedTextWasActive = markedTextView.hasMarkedText()
        markedTextView.unmarkText()

        let selection = NSRange(location: 4, length: 7)
        textView.setSelectedRange(selection)
        let selectedSource = (textView.string as NSString).substring(with: selection)

        let unsafeText = """
        [bad](javascript:alert(1)) [file](file:///private/a]b) [ok](http://[::1]/)
        ![Data](data:text/plain,a[b])
        ![File](file:///private/a]b)
        ![WikiText](data:text/plain,![[x]])
        [Obsidian](obsidian://open?vault=Private&file=Secret)
        [[file:///private/wiki|Open]] [[data:text/plain,value|Open]]
        [[javascript:alert(1)|Open]] [[/private/wiki|Open]]
        [[Private/Payroll|Open]] [[../Secrets|Open]] [[http://[::1|Open]]
        """
        let unsafeTextView = MarkdownEditorTextViewFactory.makeTextView()
        unsafeTextView.string = unsafeText
        unsafeTextView.setSelectedRange(NSRange(location: (unsafeText as NSString).length, length: 0))
        MarkdownVisibleRangeDecorator.decorateVisibleRange(
            in: unsafeTextView,
            livePreviewMode: .livePreview,
            revealRange: unsafeTextView.selectedRange()
        )
        let unsafeMarkdownLinkTargetsRemainVisible = foregroundColor(in: unsafeTextView, text: unsafeText, marker: "javascript") != LivePreviewTheme.concealedColor
            && foregroundColor(in: unsafeTextView, text: unsafeText, marker: "data:text") != LivePreviewTheme.concealedColor
            && foregroundColor(in: unsafeTextView, text: unsafeText, marker: "file:///") != LivePreviewTheme.concealedColor
            && foregroundColor(in: unsafeTextView, text: unsafeText, marker: "obsidian://open") != LivePreviewTheme.concealedColor
            && foregroundColor(in: unsafeTextView, text: unsafeText, marker: "[::1]") != LivePreviewTheme.concealedColor
            && foregroundColor(in: unsafeTextView, text: unsafeText, marker: "]b") != LivePreviewTheme.concealedColor
            && foregroundColor(in: unsafeTextView, text: unsafeText, marker: "[b]") != LivePreviewTheme.concealedColor
            && foregroundColor(in: unsafeTextView, text: unsafeText, marker: "![[x]]") != LivePreviewTheme.concealedColor
        let markdownImageEmbedDelimitersConcealed = foregroundColor(
            in: unsafeTextView,
            text: unsafeText,
            marker: "![Data"
        ) == LivePreviewTheme.concealedColor
        let unsafeWikiLinkTargetsRemainVisible = foregroundColor(
            in: unsafeTextView,
            text: unsafeText,
            marker: "file:///private/wiki"
        ) != LivePreviewTheme.concealedColor
            && foregroundColor(in: unsafeTextView, text: unsafeText, marker: "data:text/plain,value") != LivePreviewTheme.concealedColor
            && foregroundColor(in: unsafeTextView, text: unsafeText, marker: "javascript:alert") != LivePreviewTheme.concealedColor
            && foregroundColor(in: unsafeTextView, text: unsafeText, marker: "/private/wiki") != LivePreviewTheme.concealedColor
            && foregroundColor(in: unsafeTextView, text: unsafeText, marker: "Private/Payroll") != LivePreviewTheme.concealedColor
            && foregroundColor(in: unsafeTextView, text: unsafeText, marker: "../Secrets") != LivePreviewTheme.concealedColor
            && foregroundColor(in: unsafeTextView, text: unsafeText, marker: "http://[::1") != LivePreviewTheme.concealedColor
        let safeText = "[Alpha](Targets/Alpha.md) [Site](https://obsidian.md)\n"
        let safeTextView = MarkdownEditorTextViewFactory.makeTextView()
        safeTextView.string = safeText
        safeTextView.setSelectedRange(NSRange(location: (safeText as NSString).length, length: 0))
        MarkdownVisibleRangeDecorator.decorateVisibleRange(
            in: safeTextView,
            livePreviewMode: .livePreview,
            revealRange: safeTextView.selectedRange()
        )
        let safeMarkdownLinkTargetsConcealed = foregroundColor(
            in: safeTextView,
            text: safeText,
            marker: "Targets/Alpha.md"
        ) == LivePreviewTheme.concealedColor
            && foregroundColor(in: safeTextView, text: safeText, marker: "https://obsidian.md") == LivePreviewTheme.concealedColor
        let embedPreviewMapUpdatePreservesSelection = probeEmbedPreviewMapUpdatePreservesSelection()

        return (
            hiddenResult.changedRangeCount > 0 && hiddenResult.changedUTF16Length > 0,
            noOpResult.changedRangeCount == 0 && noOpResult.changedUTF16Length == 0,
            hiddenHeadingColor == LivePreviewTheme.concealedColor
                && hiddenStrongInlineTokenColor == LivePreviewTheme.concealedColor
                && revealedStrongInlineTokenColor != LivePreviewTheme.concealedColor,
            hiddenHeadingInlineTokenColor == LivePreviewTheme.concealedColor,
            hiddenTagMarkerColor == LivePreviewTheme.concealedColor,
            markedTextWasActive && markedResult.mode == "marked-text-deferred",
            sourceModeClearsLivePreviewAttributes,
            selectedSource == "Heading",
            markdownImageEmbedDelimitersConcealed,
            safeMarkdownLinkTargetsConcealed,
            embedPreviewMapUpdatePreservesSelection,
            unsafeMarkdownLinkTargetsRemainVisible,
            unsafeWikiLinkTargetsRemainVisible,
            !textView.isRichText && !textView.importsGraphics
        )
    }

    private static func foregroundColor(in textView: NSTextView, text: String, marker: String) -> NSColor? {
        guard let offset = utf16Offset(of: marker, in: text) else {
            return nil
        }
        return textView.textStorage?.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor
    }

    private static func probeEmbedPreviewMapUpdatePreservesSelection() -> Bool {
        let text = "![[image.png|100]]\nNext line\n"
        let reference = AttachmentReferenceItem(
            id: "0-wikiEmbed-image.png",
            source: .wikiEmbed,
            rawTarget: "image.png",
            state: .resolved(FileTreeItem(relativePath: "image.png"))
        )
        let pendingMap = LivePreviewEmbedPreviewMap(
            source: text,
            references: [reference],
            previewStatesByID: [:]
        )
        let readyMap = LivePreviewEmbedPreviewMap(
            source: text,
            references: [reference],
            previewStatesByID: [
                reference.id: .eligible(AttachmentPreviewInfo(
                    file: FileTreeItem(relativePath: "image.png"),
                    url: URL(fileURLWithPath: "/tmp/vault/image.png"),
                    byteSize: 128,
                    pixelWidth: 320,
                    pixelHeight: 240
                ))
            ]
        )
        let textView = MarkdownEditorTextViewFactory.makeTextView()
        textView.string = text
        guard let selectionOffset = utf16Offset(of: "Next", in: text) else {
            return false
        }
        let selection = NSRange(location: selectionOffset, length: 4)
        textView.setSelectedRange(selection)
        MarkdownVisibleRangeDecorator.decorateVisibleRange(
            in: textView,
            livePreviewMode: .livePreview,
            revealRange: textView.selectedRange(),
            embedPreviewMap: pendingMap
        )
        textView.setSelectedRange(selection)
        MarkdownVisibleRangeDecorator.decorateVisibleRange(
            in: textView,
            livePreviewMode: .livePreview,
            revealRange: textView.selectedRange(),
            embedPreviewMap: readyMap
        )

        return NSEqualRanges(textView.selectedRange(), selection)
            && textView.string == text
            && foregroundColor(in: textView, text: text, marker: "image.png") == LivePreviewTheme.embedImageColor
    }

    private static func probeSelectionChangeDecorationDoesNotReenter() -> Bool {
        var modelText = "# Heading\n\n**Strong** and [[Link]]\n"
        let binding = Binding<String>(
            get: { modelText },
            set: { modelText = $0 }
        )
        let coordinator = MarkdownEditorView.Coordinator(text: binding)
        let textView = MarkdownEditorTextViewFactory.makeTextView()
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        scrollView.documentView = textView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentView = scrollView
        window.makeFirstResponder(textView)
        textView.delegate = coordinator
        coordinator.textView = textView
        textView.string = modelText
        let selection = NSRange(location: 2, length: 0)
        textView.setSelectedRange(selection)
        coordinator.textViewDidChangeSelection(Notification(
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        ))
        window.close()

        return modelText == textView.string
            && NSEqualRanges(textView.selectedRange(), selection)
    }

    private static func font(in textView: NSTextView, text: String, marker: String) -> NSFont? {
        guard let offset = utf16Offset(of: marker, in: text) else {
            return nil
        }
        return textView.textStorage?.attribute(.font, at: offset, effectiveRange: nil) as? NSFont
    }

    private static func utf16Offset(of marker: String, in text: String) -> Int? {
        guard let range = text.range(of: marker) else {
            return nil
        }
        return NSRange(range, in: text).location
    }

    private static func probeCheckboxToggle() -> (
        changesOnlyToken: Bool,
        undoRestoresToken: Bool,
        readOnlyPreservesBuffer: Bool
    ) {
        let text = "- [ ] Task\n- [x] Done\n"
        let textView = MarkdownEditorTextViewFactory.makeTextView()
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        scrollView.documentView = textView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentView = scrollView
        window.makeFirstResponder(textView)
        textView.string = text
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        guard let offset = utf16Offset(of: "[ ]", in: text) else {
            return (false, false, false)
        }

        let toggled = (textView as? MarkdownInteractionTextView)?.toggleTaskCheckbox(at: offset + 1) == true
        let expected = "- [x] Task\n- [x] Done\n"
        let changesOnlyToken = toggled && textView.string == expected
        let canUndo = textView.undoManager?.canUndo ?? false
        textView.undoManager?.undo()
        let undoRestoresToken = canUndo && textView.string == text

        let readOnlyTextView = MarkdownEditorTextViewFactory.makeTextView()
        readOnlyTextView.string = text
        readOnlyTextView.isEditable = false
        let readOnlyToggled = (readOnlyTextView as? MarkdownInteractionTextView)?.toggleTaskCheckbox(at: offset + 1) == true
        let readOnlyPreservesBuffer = !readOnlyToggled
            && readOnlyTextView.string == text

        return (changesOnlyToken, undoRestoresToken, readOnlyPreservesBuffer)
    }

    private static func probeTableCellEdit() -> (
        contextMenuResolvesCell: Bool,
        contextMenuSkipsFallback: Bool,
        changesOnlyCell: Bool,
        undoRestoresCell: Bool,
        failurePreservesBuffer: Bool
    ) {
        let text = """
        | Name | Status |
        | --- | --- |
        | Alpha | Draft |
        """
        let textView = MarkdownEditorTextViewFactory.makeTextView()
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        scrollView.documentView = textView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentView = scrollView
        window.makeFirstResponder(textView)
        textView.string = text
        guard let table = LivePreviewTableParser.parse(text).first else {
            return (false, false, false, false, false)
        }
        let cell = table.bodyRows[0][1]
        let cellOffset = utf16Offset(of: "Draft", in: text) ?? -1
        let menuCell = (textView as? MarkdownInteractionTextView)?.tableCellForEditing(at: cellOffset)
        let contextMenuResolvesCell = menuCell == cell

        let fallbackTextView = MarkdownEditorTextViewFactory.makeTextView()
        fallbackTextView.string = text
        (fallbackTextView as? MarkdownInteractionTextView)?.livePreviewMode = .fallbackSource(reason: .tooManyTableCells)
        let fallbackCell = (fallbackTextView as? MarkdownInteractionTextView)?.tableCellForEditing(at: cellOffset)
        let contextMenuSkipsFallback = fallbackCell == nil

        let edited = (textView as? MarkdownInteractionTextView)?.replaceTableCell(cell, with: "Published") == true
        let expected = """
        | Name | Status |
        | --- | --- |
        | Alpha | Published |
        """
        let changesOnlyCell = edited && textView.string == expected
        let canUndo = textView.undoManager?.canUndo ?? false
        textView.undoManager?.undo()
        let undoRestoresCell = canUndo && textView.string == text

        let failed = (textView as? MarkdownInteractionTextView)?.replaceTableCell(cell, with: "bad|value") == true
        let readOnlyTextView = MarkdownEditorTextViewFactory.makeTextView()
        readOnlyTextView.string = text
        readOnlyTextView.isEditable = false
        let readOnlyEdited = (readOnlyTextView as? MarkdownInteractionTextView)?.replaceTableCell(cell, with: "Final") == true
        let failurePreservesBuffer = !failed
            && !readOnlyEdited
            && textView.string == text
            && readOnlyTextView.string == text

        return (contextMenuResolvesCell, contextMenuSkipsFallback, changesOnlyCell, undoRestoresCell, failurePreservesBuffer)
    }

    private static func probeEditorAccessibility() -> Bool {
        let textView = MarkdownEditorTextViewFactory.makeTextView()
        let livePreviewHelp = textView.accessibilityHelp() ?? ""

        MarkdownEditorAccessibility.apply(to: textView, isEditable: false, mode: .livePreview)
        let viewerHelp = textView.accessibilityHelp() ?? ""

        MarkdownEditorAccessibility.apply(to: textView, isEditable: true, mode: .source)
        let sourceHelp = textView.accessibilityHelp() ?? ""

        return livePreviewHelp.contains("links")
            && livePreviewHelp.contains("tags")
            && livePreviewHelp.contains("properties")
            && livePreviewHelp.contains("embeds")
            && livePreviewHelp.contains("tables")
            && livePreviewHelp.contains("checkboxes")
            && viewerHelp.contains("links")
            && viewerHelp.contains("tags")
            && viewerHelp.contains("properties")
            && viewerHelp.contains("embeds")
            && viewerHelp.contains("tables")
            && sourceHelp.contains("Markdown syntax")
    }
}
