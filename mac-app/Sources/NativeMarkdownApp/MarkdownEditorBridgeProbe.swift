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
    var caretRevealRestoresHiddenSyntaxColor: Bool
    var markedTextRenderDeferred: Bool
    var sourceEquivalentSelectionText: Bool
    var plainTextPastePolicy: Bool
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
            caretRevealRestoresHiddenSyntaxColor: renderProbe.caretRevealRestoresHiddenSyntaxColor,
            markedTextRenderDeferred: renderProbe.markedTextRenderDeferred,
            sourceEquivalentSelectionText: renderProbe.sourceEquivalentSelectionText,
            plainTextPastePolicy: renderProbe.plainTextPastePolicy
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
        caretRevealRestoresHiddenSyntaxColor: Bool,
        markedTextRenderDeferred: Bool,
        sourceEquivalentSelectionText: Bool,
        plainTextPastePolicy: Bool
    ) {
        let text = "# Heading\n\n**Strong** and `code` with [[Link]]\n"
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

        textView.setSelectedRange(NSRange(location: 2, length: 0))
        MarkdownVisibleRangeDecorator.decorateVisibleRange(
            in: textView,
            livePreviewMode: .livePreview,
            revealRange: textView.selectedRange()
        )
        let revealedHeadingColor = textView.textStorage?.attribute(
            .foregroundColor,
            at: 0,
            effectiveRange: nil
        ) as? NSColor

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

        let selection = NSRange(location: 2, length: 7)
        textView.setSelectedRange(selection)
        let selectedSource = (textView.string as NSString).substring(with: selection)

        return (
            hiddenResult.changedRangeCount > 0 && hiddenResult.changedUTF16Length > 0,
            hiddenHeadingColor == LivePreviewTheme.concealedColor && revealedHeadingColor != LivePreviewTheme.concealedColor,
            markedTextWasActive && markedResult.mode == "marked-text-deferred",
            selectedSource == "Heading",
            !textView.isRichText && !textView.importsGraphics
        )
    }
}
