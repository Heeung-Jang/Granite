import AppKit
import Foundation
import NativeMarkdownCore
import SwiftUI

struct MarkdownEditorBridgeProbeReport: Codable, Equatable {
    var summary: ProbeCheckSummary
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
    var livePreviewRenderDoesNotMutateSource: Bool
    var sourceModeShowsRawMarkdownSyntax: Bool
    var overlayStateClearsOnModeSwitch: Bool
    var overlayStateClearsOnSourceChange: Bool
    var overlayStateClearsWhenDisabled: Bool
    var overlayStateClearsDuringMarkedText: Bool
    var activeHeadingLineMovementPreservesSource: Bool
    var activeListLineMovementPreservesSource: Bool
    var activeTaskLineMovementPreservesSource: Bool
    var activeHorizontalRuleLineMovementPreservesSource: Bool
    var caretRevealRestoresHiddenSyntaxColor: Bool
    var headingSelectionRevealsMarkdownSource: Bool
    var inlineConcealmentAppliesBeyondParagraph: Bool
    var tagMarkersConcealed: Bool
    var markerStyleShowsHeadingAndListMarkers: Bool
    var markerStyleCanHideHeadingAndListMarkers: Bool
    var obsidianHeadingMarkerConcealedOutsideReveal: Bool
    var obsidianHeadingMarkerRevealedInsideLine: Bool
    var obsidianListMarkersMutedOutsideReveal: Bool
    var obsidianTaskCheckboxVisibleOutsideReveal: Bool
    var obsidianBlockquoteMarkerConcealedOutsideReveal: Bool
    var obsidianBlockquoteMarkerStaysConcealedInsideBlock: Bool
    var obsidianCalloutSyntaxConcealedOutsideReveal: Bool
    var obsidianCalloutSyntaxStaysConcealedInsideBlock: Bool
    var horizontalRuleSyntaxConcealedOutsideReveal: Bool
    var horizontalRuleSyntaxRevealedInsideLine: Bool
    var horizontalRuleParagraphStyleApplied: Bool
    var horizontalRuleOverlayDrawsOutsideReveal: Bool
    var horizontalRuleOverlaySuppressedInsideReveal: Bool
    var horizontalRuleRenderPreservesSource: Bool
    var markerStyleDefaultIsObsidian: Bool
    var markerStyleRawValuesRemainCompatible: Bool
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
    var renderedTaskCheckboxHitTestResolvesToken: Bool
    var renderedTaskCheckboxHitTestDisabledGuards: Bool
    var renderedTaskCheckboxToggleChangesOnlyToken: Bool
    var renderedTaskCheckboxToggleUndoRestoresToken: Bool
    var tableCellContextMenuResolvesCell: Bool
    var tableCellContextMenuSkipsFallback: Bool
    var tableCellEditChangesOnlyCell: Bool
    var tableCellEditUndoRestoresCell: Bool
    var tableCellEditFailurePreservesBuffer: Bool
    var tableInPlaceEditAvailable: Bool
    var tableInPlaceEditSelectionPreserved: Bool
    var tableInPlaceEditUndoPreservesSelection: Bool
    var frontmatterBoundaryDeleteUndoPreservesBuffer: Bool
    var editorAccessibilityHelpMentionsInteractions: Bool
}

@MainActor
enum MarkdownEditorBridgeProbe {
    private static let expectedFailures: Set<String> = [
        "tableInPlaceEditAvailable",
        "tableInPlaceEditSelectionPreserved",
        "tableInPlaceEditUndoPreservesSelection"
    ]

    static func encodedReport(_ report: MarkdownEditorBridgeProbeReport = run()) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try! encoder.encode(report)
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
        let sourcePreservationProbe = probeSourcePreservationGuards()
        let overlayStateProbe = probeOverlayStateLifecycle()
        let markerStyleProbe = probeMarkerStyleStorageCompatibility()
        let selectionChangeProbe = probeSelectionChangeDecorationDoesNotReenter()
        let checkboxProbe = probeCheckboxToggle()
        let tableCellProbe = probeTableCellEdit()
        let frontmatterBoundaryProbe = probeFrontmatterBoundaryDeleteUndo()
        let accessibilityProbe = probeEditorAccessibility()

        var report = MarkdownEditorBridgeProbeReport(
            summary: .passed,
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
            livePreviewRenderDoesNotMutateSource: sourcePreservationProbe.livePreviewRenderDoesNotMutateSource,
            sourceModeShowsRawMarkdownSyntax: sourcePreservationProbe.sourceModeShowsRawMarkdownSyntax,
            overlayStateClearsOnModeSwitch: overlayStateProbe.clearsOnModeSwitch,
            overlayStateClearsOnSourceChange: overlayStateProbe.clearsOnSourceChange,
            overlayStateClearsWhenDisabled: overlayStateProbe.clearsWhenDisabled,
            overlayStateClearsDuringMarkedText: overlayStateProbe.clearsDuringMarkedText,
            activeHeadingLineMovementPreservesSource: sourcePreservationProbe.activeHeadingLineMovementPreservesSource,
            activeListLineMovementPreservesSource: sourcePreservationProbe.activeListLineMovementPreservesSource,
            activeTaskLineMovementPreservesSource: sourcePreservationProbe.activeTaskLineMovementPreservesSource,
            activeHorizontalRuleLineMovementPreservesSource: sourcePreservationProbe.activeHorizontalRuleLineMovementPreservesSource,
            caretRevealRestoresHiddenSyntaxColor: renderProbe.caretRevealRestoresHiddenSyntaxColor,
            headingSelectionRevealsMarkdownSource: renderProbe.headingSelectionRevealsMarkdownSource,
            inlineConcealmentAppliesBeyondParagraph: renderProbe.inlineConcealmentAppliesBeyondParagraph,
            tagMarkersConcealed: renderProbe.tagMarkersConcealed,
            markerStyleShowsHeadingAndListMarkers: renderProbe.markerStyleShowsHeadingAndListMarkers,
            markerStyleCanHideHeadingAndListMarkers: renderProbe.markerStyleCanHideHeadingAndListMarkers,
            obsidianHeadingMarkerConcealedOutsideReveal: renderProbe.obsidianHeadingMarkerConcealedOutsideReveal,
            obsidianHeadingMarkerRevealedInsideLine: renderProbe.obsidianHeadingMarkerRevealedInsideLine,
            obsidianListMarkersMutedOutsideReveal: renderProbe.obsidianListMarkersMutedOutsideReveal,
            obsidianTaskCheckboxVisibleOutsideReveal: renderProbe.obsidianTaskCheckboxVisibleOutsideReveal,
            obsidianBlockquoteMarkerConcealedOutsideReveal: renderProbe.obsidianBlockquoteMarkerConcealedOutsideReveal,
            obsidianBlockquoteMarkerStaysConcealedInsideBlock: renderProbe.obsidianBlockquoteMarkerStaysConcealedInsideBlock,
            obsidianCalloutSyntaxConcealedOutsideReveal: renderProbe.obsidianCalloutSyntaxConcealedOutsideReveal,
            obsidianCalloutSyntaxStaysConcealedInsideBlock: renderProbe.obsidianCalloutSyntaxStaysConcealedInsideBlock,
            horizontalRuleSyntaxConcealedOutsideReveal: renderProbe.horizontalRuleSyntaxConcealedOutsideReveal,
            horizontalRuleSyntaxRevealedInsideLine: renderProbe.horizontalRuleSyntaxRevealedInsideLine,
            horizontalRuleParagraphStyleApplied: renderProbe.horizontalRuleParagraphStyleApplied,
            horizontalRuleOverlayDrawsOutsideReveal: renderProbe.horizontalRuleOverlayDrawsOutsideReveal,
            horizontalRuleOverlaySuppressedInsideReveal: renderProbe.horizontalRuleOverlaySuppressedInsideReveal,
            horizontalRuleRenderPreservesSource: renderProbe.horizontalRuleRenderPreservesSource,
            markerStyleDefaultIsObsidian: markerStyleProbe.defaultIsObsidian,
            markerStyleRawValuesRemainCompatible: markerStyleProbe.rawValuesRemainCompatible,
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
            renderedTaskCheckboxHitTestResolvesToken: checkboxProbe.renderedHitTestResolvesToken,
            renderedTaskCheckboxHitTestDisabledGuards: checkboxProbe.renderedHitTestDisabledGuards,
            renderedTaskCheckboxToggleChangesOnlyToken: checkboxProbe.renderedToggleChangesOnlyToken,
            renderedTaskCheckboxToggleUndoRestoresToken: checkboxProbe.renderedToggleUndoRestoresToken,
            tableCellContextMenuResolvesCell: tableCellProbe.contextMenuResolvesCell,
            tableCellContextMenuSkipsFallback: tableCellProbe.contextMenuSkipsFallback,
            tableCellEditChangesOnlyCell: tableCellProbe.changesOnlyCell,
            tableCellEditUndoRestoresCell: tableCellProbe.undoRestoresCell,
            tableCellEditFailurePreservesBuffer: tableCellProbe.failurePreservesBuffer,
            tableInPlaceEditAvailable: false,
            tableInPlaceEditSelectionPreserved: false,
            tableInPlaceEditUndoPreservesSelection: false,
            frontmatterBoundaryDeleteUndoPreservesBuffer: frontmatterBoundaryProbe,
            editorAccessibilityHelpMentionsInteractions: accessibilityProbe
        )
        report.summary = ProbeCheckSummary.evaluate(report: report, expectedFailures: expectedFailures)
        return report
    }

    private static func probeSourcePreservationGuards() -> (
        livePreviewRenderDoesNotMutateSource: Bool,
        sourceModeShowsRawMarkdownSyntax: Bool,
        activeHeadingLineMovementPreservesSource: Bool,
        activeListLineMovementPreservesSource: Bool,
        activeTaskLineMovementPreservesSource: Bool,
        activeHorizontalRuleLineMovementPreservesSource: Bool
    ) {
        let source = """
        # Heading

        - Bullet
        - [x] Done

        ---

        | Name | Status |
        | --- | --- |
        | Alpha | Draft |
        """
        let textView = MarkdownEditorTextViewFactory.makeTextView()
        textView.string = source
        let endSelection = NSRange(location: (source as NSString).length, length: 0)
        textView.setSelectedRange(endSelection)

        MarkdownVisibleRangeDecorator.decorateVisibleRange(
            in: textView,
            livePreviewMode: .livePreview,
            revealRange: textView.selectedRange(),
            markerStyle: .obsidian
        )
        let livePreviewRenderDoesNotMutateSource = textView.string == source

        MarkdownVisibleRangeDecorator.decorateVisibleRange(
            in: textView,
            livePreviewMode: .source,
            revealRange: textView.selectedRange(),
            markerStyle: .obsidian
        )
        let sourceModeShowsRawMarkdownSyntax = textView.string == source
            && foregroundColor(in: textView, text: source, marker: "# Heading") != LivePreviewTheme.concealedColor
            && foregroundColor(in: textView, text: source, marker: "- Bullet") != LivePreviewTheme.concealedColor
            && foregroundColor(in: textView, text: source, marker: "- [x]") != LivePreviewTheme.concealedColor
            && foregroundColor(in: textView, text: source, marker: "---") != LivePreviewTheme.concealedColor
            && foregroundColor(in: textView, text: source, marker: "| Name") != LivePreviewTheme.concealedColor

        func moveSelection(to marker: String) -> Bool {
            guard let offset = utf16Offset(of: marker, in: source) else {
                return false
            }
            textView.setSelectedRange(NSRange(location: offset, length: 0))
            MarkdownVisibleRangeDecorator.decorateVisibleRange(
                in: textView,
                livePreviewMode: .livePreview,
                revealRange: textView.selectedRange(),
                markerStyle: .obsidian
            )
            return textView.string == source
        }

        return (
            livePreviewRenderDoesNotMutateSource,
            sourceModeShowsRawMarkdownSyntax,
            moveSelection(to: "Heading"),
            moveSelection(to: "Bullet"),
            moveSelection(to: "Done"),
            moveSelection(to: "---")
        )
    }

    private static func probeOverlayStateLifecycle() -> (
        clearsOnModeSwitch: Bool,
        clearsOnSourceChange: Bool,
        clearsWhenDisabled: Bool,
        clearsDuringMarkedText: Bool
    ) {
        let activeCell = LivePreviewTableCell(
            text: "Alpha",
            sourceRange: LivePreviewSourceRange(location: 0, length: 7),
            contentRange: LivePreviewSourceRange(location: 2, length: 5),
            columnIndex: 0
        )

        let modeTextView = MarkdownEditorTextViewFactory.makeTextView() as! MarkdownInteractionTextView
        modeTextView.string = "| A | B |\n| --- | --- |\n| Alpha | Beta |\n"
        modeTextView.livePreviewMode = .livePreview
        modeTextView.setLivePreviewOverlayTableState(hovered: nil, active: activeCell)
        modeTextView.livePreviewMode = .source
        modeTextView.refreshLivePreviewOverlayState()
        let clearsOnModeSwitch = modeTextView.livePreviewOverlayState.mode == .source
            && modeTextView.livePreviewOverlayState.activeTableCell == nil

        let sourceTextView = MarkdownEditorTextViewFactory.makeTextView() as! MarkdownInteractionTextView
        sourceTextView.string = "Before"
        sourceTextView.refreshLivePreviewOverlayState()
        sourceTextView.setLivePreviewOverlayTableState(hovered: nil, active: activeCell)
        sourceTextView.string = "After"
        sourceTextView.noteLivePreviewSourceChanged()
        sourceTextView.refreshLivePreviewOverlayState()
        let clearsOnSourceChange = sourceTextView.livePreviewOverlayState.activeTableCell == nil

        let disabledTextView = MarkdownEditorTextViewFactory.makeTextView() as! MarkdownInteractionTextView
        disabledTextView.string = "Body"
        disabledTextView.refreshLivePreviewOverlayState()
        disabledTextView.setLivePreviewOverlayTableState(hovered: activeCell, active: activeCell)
        disabledTextView.isEditable = false
        disabledTextView.refreshLivePreviewOverlayState()
        let clearsWhenDisabled = disabledTextView.livePreviewOverlayState.hoveredTableCell == nil
            && disabledTextView.livePreviewOverlayState.activeTableCell == nil
            && !disabledTextView.livePreviewOverlayState.allowsTransientControls

        let markedTextView = MarkdownEditorTextViewFactory.makeTextView() as! MarkdownInteractionTextView
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
        markedTextView.string = "Body"
        markedTextView.refreshLivePreviewOverlayState()
        markedTextView.setLivePreviewOverlayTableState(hovered: activeCell, active: activeCell)
        markedTextView.setMarkedText(
            "한글",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        markedTextView.refreshLivePreviewOverlayState()
        let clearsDuringMarkedText = markedTextView.hasMarkedText()
            && markedTextView.livePreviewOverlayState.hoveredTableCell == nil
            && markedTextView.livePreviewOverlayState.activeTableCell == nil
            && !markedTextView.livePreviewOverlayState.allowsTransientControls
        markedTextView.unmarkText()

        return (
            clearsOnModeSwitch,
            clearsOnSourceChange,
            clearsWhenDisabled,
            clearsDuringMarkedText
        )
    }

    private static func probeMarkerStyleStorageCompatibility() -> (
        defaultIsObsidian: Bool,
        rawValuesRemainCompatible: Bool
    ) {
        let rawValuesRemainCompatible = LivePreviewMarkerStyle(rawValue: "obsidian") == .obsidian
            && LivePreviewMarkerStyle(rawValue: "accent") == .accent
            && LivePreviewMarkerStyle(rawValue: "muted") == .muted
            && LivePreviewMarkerStyle(rawValue: "hidden") == .hidden

        return (
            LivePreviewMarkerStyle.defaultValue == .obsidian,
            rawValuesRemainCompatible
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
        headingSelectionRevealsMarkdownSource: Bool,
        inlineConcealmentAppliesBeyondParagraph: Bool,
        tagMarkersConcealed: Bool,
        markerStyleShowsHeadingAndListMarkers: Bool,
        markerStyleCanHideHeadingAndListMarkers: Bool,
        obsidianHeadingMarkerConcealedOutsideReveal: Bool,
        obsidianHeadingMarkerRevealedInsideLine: Bool,
        obsidianListMarkersMutedOutsideReveal: Bool,
        obsidianTaskCheckboxVisibleOutsideReveal: Bool,
        obsidianBlockquoteMarkerConcealedOutsideReveal: Bool,
        obsidianBlockquoteMarkerStaysConcealedInsideBlock: Bool,
        obsidianCalloutSyntaxConcealedOutsideReveal: Bool,
        obsidianCalloutSyntaxStaysConcealedInsideBlock: Bool,
        horizontalRuleSyntaxConcealedOutsideReveal: Bool,
        horizontalRuleSyntaxRevealedInsideLine: Bool,
        horizontalRuleParagraphStyleApplied: Bool,
        horizontalRuleOverlayDrawsOutsideReveal: Bool,
        horizontalRuleOverlaySuppressedInsideReveal: Bool,
        horizontalRuleRenderPreservesSource: Bool,
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
            revealRange: textView.selectedRange(),
            markerStyle: .hidden
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
            revealRange: textView.selectedRange(),
            markerStyle: .hidden
        )

        textView.setSelectedRange(NSRange(location: (text as NSString).range(of: "Strong").location, length: 0))
        MarkdownVisibleRangeDecorator.decorateVisibleRange(
            in: textView,
            livePreviewMode: .livePreview,
            revealRange: textView.selectedRange(),
            markerStyle: .hidden
        )
        let revealedStrongInlineTokenColor = foregroundColor(in: textView, text: text, marker: "**Strong")

        textView.setSelectedRange(NSRange(location: (text as NSString).range(of: "Heading").location, length: 0))
        MarkdownVisibleRangeDecorator.decorateVisibleRange(
            in: textView,
            livePreviewMode: .livePreview,
            revealRange: textView.selectedRange(),
            markerStyle: .hidden
        )
        let revealedHeadingMarkerColor = foregroundColor(in: textView, text: text, marker: "# **Heading")

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
            revealRange: markedTextView.selectedRange(),
            markerStyle: .hidden
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
            revealRange: unsafeTextView.selectedRange(),
            markerStyle: .hidden
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
            revealRange: safeTextView.selectedRange(),
            markerStyle: .hidden
        )
        let safeMarkdownLinkTargetsConcealed = foregroundColor(
            in: safeTextView,
            text: safeText,
            marker: "Targets/Alpha.md"
        ) == LivePreviewTheme.concealedColor
            && foregroundColor(in: safeTextView, text: safeText, marker: "https://obsidian.md") == LivePreviewTheme.concealedColor
        let embedPreviewMapUpdatePreservesSelection = probeEmbedPreviewMapUpdatePreservesSelection()
        let markerStyleProbe = probeMarkerStyleRendering()
        let horizontalRuleProbe = probeHorizontalRuleRendering()

        return (
            hiddenResult.changedRangeCount > 0 && hiddenResult.changedUTF16Length > 0,
            noOpResult.changedRangeCount == 0 && noOpResult.changedUTF16Length == 0,
            hiddenHeadingColor == LivePreviewTheme.concealedColor
                && hiddenStrongInlineTokenColor == LivePreviewTheme.concealedColor
                && revealedStrongInlineTokenColor != LivePreviewTheme.concealedColor,
            revealedHeadingMarkerColor != LivePreviewTheme.concealedColor,
            hiddenHeadingInlineTokenColor == LivePreviewTheme.concealedColor,
            hiddenTagMarkerColor == LivePreviewTheme.concealedColor,
            markerStyleProbe.showsMarkers,
            markerStyleProbe.hidesMarkers,
            markerStyleProbe.obsidianHeadingConcealed,
            markerStyleProbe.obsidianHeadingRevealed,
            markerStyleProbe.obsidianListMarkersMuted,
            markerStyleProbe.obsidianTaskCheckboxVisible,
            markerStyleProbe.obsidianBlockquoteConcealed,
            markerStyleProbe.obsidianBlockquoteConcealedInsideBlock,
            markerStyleProbe.obsidianCalloutConcealed,
            markerStyleProbe.obsidianCalloutConcealedInsideBlock,
            horizontalRuleProbe.syntaxConcealed,
            horizontalRuleProbe.syntaxRevealed,
            horizontalRuleProbe.paragraphStyleApplied,
            horizontalRuleProbe.overlayDrawsOutsideReveal,
            horizontalRuleProbe.overlaySuppressedInsideReveal,
            horizontalRuleProbe.sourcePreserved,
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

    private static func probeHorizontalRuleRendering() -> (
        syntaxConcealed: Bool,
        syntaxRevealed: Bool,
        paragraphStyleApplied: Bool,
        overlayDrawsOutsideReveal: Bool,
        overlaySuppressedInsideReveal: Bool,
        sourcePreserved: Bool
    ) {
        let text = "Before\n---\nAfter\n"
        let endSelection = NSRange(location: (text as NSString).length, length: 0)
        let textView = MarkdownEditorTextViewFactory.makeTextView()
        textView.string = text
        textView.setSelectedRange(endSelection)
        MarkdownVisibleRangeDecorator.decorateVisibleRange(
            in: textView,
            livePreviewMode: .livePreview,
            revealRange: textView.selectedRange(),
            markerStyle: .obsidian
        )

        let ruleOffset = (text as NSString).range(of: "---").location
        let hiddenColor = foregroundColor(in: textView, text: text, marker: "---")
        let paragraphStyle = textView.textStorage?.attribute(
            .paragraphStyle,
            at: ruleOffset,
            effectiveRange: nil
        ) as? NSParagraphStyle
        let parsedRule = LivePreviewParser.parse(text).blocks.first { $0.kind == .horizontalRule }
        let overlayDrawsOutsideReveal = parsedRule.map {
            LivePreviewOverlayRenderer.shouldDrawHorizontalRule($0, selectedRange: endSelection)
        } ?? false

        let revealSelection = NSRange(location: ruleOffset, length: 0)
        textView.setSelectedRange(revealSelection)
        MarkdownVisibleRangeDecorator.decorateVisibleRange(
            in: textView,
            livePreviewMode: .livePreview,
            revealRange: textView.selectedRange(),
            markerStyle: .obsidian
        )
        let revealedColor = foregroundColor(in: textView, text: text, marker: "---")
        let overlaySuppressedInsideReveal = parsedRule.map {
            !LivePreviewOverlayRenderer.shouldDrawHorizontalRule($0, selectedRange: revealSelection)
        } ?? false

        return (
            hiddenColor == LivePreviewTheme.concealedColor,
            revealedColor != LivePreviewTheme.concealedColor,
            paragraphStyle?.minimumLineHeight == LivePreviewTheme.horizontalRuleParagraphStyle.minimumLineHeight,
            overlayDrawsOutsideReveal,
            overlaySuppressedInsideReveal,
            textView.string == text
        )
    }

    private static func probeMarkerStyleRendering() -> (
        showsMarkers: Bool,
        hidesMarkers: Bool,
        obsidianHeadingConcealed: Bool,
        obsidianHeadingRevealed: Bool,
        obsidianListMarkersMuted: Bool,
        obsidianTaskCheckboxVisible: Bool,
        obsidianBlockquoteConcealed: Bool,
        obsidianBlockquoteConcealedInsideBlock: Bool,
        obsidianCalloutConcealed: Bool,
        obsidianCalloutConcealedInsideBlock: Bool
    ) {
        let text = "# Heading\n- Bullet\n- [x] Done\n> Quote\n> [!note] Callout\n"
        let endSelection = NSRange(location: (text as NSString).length, length: 0)

        let visibleTextView = MarkdownEditorTextViewFactory.makeTextView()
        visibleTextView.string = text
        visibleTextView.setSelectedRange(endSelection)
        MarkdownVisibleRangeDecorator.decorateVisibleRange(
            in: visibleTextView,
            livePreviewMode: .livePreview,
            revealRange: visibleTextView.selectedRange(),
            markerStyle: .accent
        )
        let showsMarkers = foregroundColor(in: visibleTextView, text: text, marker: "# Heading") == LivePreviewTheme.listMarkerColor
            && foregroundColor(in: visibleTextView, text: text, marker: "- Bullet") == LivePreviewTheme.listMarkerColor
            && foregroundColor(in: visibleTextView, text: text, marker: "- [x]") == LivePreviewTheme.listMarkerColor
            && foregroundColor(in: visibleTextView, text: text, marker: "[x]") != LivePreviewTheme.concealedColor

        let hiddenTextView = MarkdownEditorTextViewFactory.makeTextView()
        hiddenTextView.string = text
        hiddenTextView.setSelectedRange(endSelection)
        MarkdownVisibleRangeDecorator.decorateVisibleRange(
            in: hiddenTextView,
            livePreviewMode: .livePreview,
            revealRange: hiddenTextView.selectedRange(),
            markerStyle: .hidden
        )
        let hidesMarkers = foregroundColor(in: hiddenTextView, text: text, marker: "# Heading") == LivePreviewTheme.concealedColor
            && foregroundColor(in: hiddenTextView, text: text, marker: "- Bullet") == LivePreviewTheme.concealedColor
            && foregroundColor(in: hiddenTextView, text: text, marker: "- [x]") == LivePreviewTheme.concealedColor
            && foregroundColor(in: hiddenTextView, text: text, marker: "[x]") != LivePreviewTheme.concealedColor

        let obsidianTextView = MarkdownEditorTextViewFactory.makeTextView()
        obsidianTextView.string = text
        obsidianTextView.setSelectedRange(endSelection)
        MarkdownVisibleRangeDecorator.decorateVisibleRange(
            in: obsidianTextView,
            livePreviewMode: .livePreview,
            revealRange: obsidianTextView.selectedRange(),
            markerStyle: .obsidian
        )
        let obsidianHeadingConcealed = foregroundColor(
            in: obsidianTextView,
            text: text,
            marker: "# Heading"
        ) == LivePreviewTheme.concealedColor
        let obsidianListMarkersMuted = foregroundColor(
            in: obsidianTextView,
            text: text,
            marker: "- Bullet"
        ) == LivePreviewTheme.concealedColor
            && foregroundColor(in: obsidianTextView, text: text, marker: "- [x]") == LivePreviewTheme.concealedColor
        let obsidianTaskCheckboxVisible = taskCheckboxOverlayAvailable(in: obsidianTextView, text: text)
        let obsidianBlockquoteConcealed = foregroundColor(
            in: obsidianTextView,
            text: text,
            marker: "> Quote"
        ) == LivePreviewTheme.concealedColor
        let obsidianCalloutConcealed = foregroundColor(
            in: obsidianTextView,
            text: text,
            marker: "> [!note]"
        ) == LivePreviewTheme.concealedColor

        let headingOffset = (text as NSString).range(of: "Heading").location
        obsidianTextView.setSelectedRange(NSRange(location: headingOffset, length: 0))
        MarkdownVisibleRangeDecorator.decorateVisibleRange(
            in: obsidianTextView,
            livePreviewMode: .livePreview,
            revealRange: obsidianTextView.selectedRange(),
            markerStyle: .obsidian
        )
        let obsidianHeadingRevealed = foregroundColor(
            in: obsidianTextView,
            text: text,
            marker: "# Heading"
        ) == LivePreviewTheme.secondaryTextColor

        let quoteOffset = (text as NSString).range(of: "Quote").location
        obsidianTextView.setSelectedRange(NSRange(location: quoteOffset, length: 0))
        MarkdownVisibleRangeDecorator.decorateVisibleRange(
            in: obsidianTextView,
            livePreviewMode: .livePreview,
            revealRange: obsidianTextView.selectedRange(),
            markerStyle: .obsidian
        )
        let obsidianBlockquoteConcealedInsideBlock = foregroundColor(
            in: obsidianTextView,
            text: text,
            marker: "> Quote"
        ) == LivePreviewTheme.concealedColor

        let calloutOffset = (text as NSString).range(of: "Callout").location
        obsidianTextView.setSelectedRange(NSRange(location: calloutOffset, length: 0))
        MarkdownVisibleRangeDecorator.decorateVisibleRange(
            in: obsidianTextView,
            livePreviewMode: .livePreview,
            revealRange: obsidianTextView.selectedRange(),
            markerStyle: .obsidian
        )
        let obsidianCalloutConcealedInsideBlock = foregroundColor(
            in: obsidianTextView,
            text: text,
            marker: "> [!note]"
        ) == LivePreviewTheme.concealedColor

        return (
            showsMarkers,
            hidesMarkers,
            obsidianHeadingConcealed,
            obsidianHeadingRevealed,
            obsidianListMarkersMuted,
            obsidianTaskCheckboxVisible,
            obsidianBlockquoteConcealed,
            obsidianBlockquoteConcealedInsideBlock,
            obsidianCalloutConcealed,
            obsidianCalloutConcealedInsideBlock
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

    private static func taskCheckboxOverlayAvailable(in textView: NSTextView, text: String) -> Bool {
        guard let block = LivePreviewParser.parse(text).blocks.first(where: {
            if case .taskList = $0.kind {
                return true
            }
            return false
        }),
              let markerKind = LivePreviewOverlayRenderer.markerGeometries(in: textView)
                .first(where: { $0.kind == .taskCheckbox })?.kind
        else {
            return false
        }
        return LivePreviewOverlayRenderer.shouldDrawMarkerOverlay(
            for: block,
            markerKind: markerKind,
            state: LivePreviewOverlayState(
                markerStyle: .obsidian,
                revealRange: NSRange(location: (text as NSString).length, length: 0)
            )
        )
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
        readOnlyPreservesBuffer: Bool,
        renderedHitTestResolvesToken: Bool,
        renderedHitTestDisabledGuards: Bool,
        renderedToggleChangesOnlyToken: Bool,
        renderedToggleUndoRestoresToken: Bool
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
            return (false, false, false, false, false, false, false)
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

        let renderedText = "- [ ] Task\n"
        let renderedTextView = MarkdownEditorTextViewFactory.makeTextView() as! MarkdownInteractionTextView
        let renderedScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        renderedScrollView.documentView = renderedTextView
        let renderedWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        renderedWindow.contentView = renderedScrollView
        renderedWindow.makeFirstResponder(renderedTextView)
        renderedTextView.string = renderedText
        renderedTextView.livePreviewMarkerStyle = .obsidian
        renderedTextView.setSelectedRange(NSRange(location: (renderedText as NSString).length, length: 0))
        MarkdownVisibleRangeDecorator.decorateVisibleRange(
            in: renderedTextView,
            livePreviewMode: .livePreview,
            revealRange: renderedTextView.selectedRange(),
            markerStyle: .obsidian
        )
        renderedTextView.refreshLivePreviewOverlayState()
        let renderedGeometry = LivePreviewOverlayRenderer.markerGeometries(in: renderedTextView)
            .first { $0.kind == .taskCheckbox }
        let renderedPoint = renderedGeometry.map { NSPoint(x: $0.rect.midX, y: $0.rect.midY) }
        let renderedOffset = renderedPoint.flatMap { renderedTextView.taskCheckboxToggleOffset(at: $0) }
        let renderedHitTestResolvesToken = renderedOffset == (utf16Offset(of: "[ ]", in: renderedText) ?? -10) + 1

        let renderedToggled = renderedOffset.map { renderedTextView.toggleTaskCheckbox(at: $0) } == true
        let renderedToggleChangesOnlyToken = renderedToggled && renderedTextView.string == "- [x] Task\n"
        let renderedCanUndo = renderedTextView.undoManager?.canUndo ?? false
        renderedTextView.undoManager?.undo()
        let renderedToggleUndoRestoresToken = renderedCanUndo && renderedTextView.string == renderedText

        let sourceModeTextView = MarkdownEditorTextViewFactory.makeTextView() as! MarkdownInteractionTextView
        sourceModeTextView.string = renderedText
        sourceModeTextView.livePreviewMode = .source
        sourceModeTextView.livePreviewMarkerStyle = .obsidian
        sourceModeTextView.refreshLivePreviewOverlayState()

        let readOnlyRenderedTextView = MarkdownEditorTextViewFactory.makeTextView() as! MarkdownInteractionTextView
        readOnlyRenderedTextView.string = renderedText
        readOnlyRenderedTextView.livePreviewMarkerStyle = .obsidian
        readOnlyRenderedTextView.isEditable = false
        readOnlyRenderedTextView.refreshLivePreviewOverlayState()

        let markedTextView = MarkdownEditorTextViewFactory.makeTextView() as! MarkdownInteractionTextView
        markedTextView.string = renderedText
        markedTextView.livePreviewMarkerStyle = .obsidian
        markedTextView.setMarkedText(
            "한글",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        markedTextView.refreshLivePreviewOverlayState()

        let renderedTaskPoint = renderedPoint ?? .zero
        let renderedHitTestDisabledGuards = sourceModeTextView.taskCheckboxToggleOffset(at: renderedTaskPoint) == nil
            && readOnlyRenderedTextView.taskCheckboxToggleOffset(at: renderedTaskPoint) == nil
            && markedTextView.taskCheckboxToggleOffset(at: renderedTaskPoint) == nil

        return (
            changesOnlyToken,
            undoRestoresToken,
            readOnlyPreservesBuffer,
            renderedHitTestResolvesToken,
            renderedHitTestDisabledGuards,
            renderedToggleChangesOnlyToken,
            renderedToggleUndoRestoresToken
        )
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

    private static func probeFrontmatterBoundaryDeleteUndo() -> Bool {
        let original = """
        ---
        title: fix: Normalize RestTemplate downstream error handling
        type: fix
        date: 2026-04-23
        ---
        # fix: Normalize RestTemplate downstream error handling

        ## Enhancement Summary

        HttpStatus 중심 설계를 HttpStatusCode 유지 중심으로 바꿔 비표준 downstream status까지 보존한다.
        """
        let afterDelete = original.replacingOccurrences(
            of: "# fix: Normalize",
            with: "#fix: Normalize",
            options: [],
            range: original.range(of: "# fix: Normalize")
        )
        var modelText = original
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
        textView.string = original

        guard let headingOffset = utf16Offset(of: "# fix:", in: original) else {
            window.close()
            return false
        }

        textView.setSelectedRange(NSRange(location: headingOffset + 2, length: 0))
        coordinator.decorateVisibleRange(in: textView)
        textView.deleteBackward(nil)
        runPendingEditorDecoration()
        let deletePreservedBuffer = textView.string == afterDelete && modelText == afterDelete
        let deleteGlyphRangeValid = visibleGlyphRangeIsValid(in: textView)
        let deleteKoreanBodyRemainsVisible = foregroundColor(
            in: textView,
            text: afterDelete,
            marker: "중심 설계"
        ) != LivePreviewTheme.concealedColor

        let canUndo = textView.undoManager?.canUndo ?? false
        textView.undoManager?.undo()
        runPendingEditorDecoration()
        let undoPreservedBuffer = textView.string == original && modelText == original
        let undoGlyphRangeValid = visibleGlyphRangeIsValid(in: textView)
        let undoKoreanBodyRemainsVisible = foregroundColor(
            in: textView,
            text: original,
            marker: "중심 설계"
        ) != LivePreviewTheme.concealedColor
        window.close()

        return deletePreservedBuffer
            && deleteGlyphRangeValid
            && deleteKoreanBodyRemainsVisible
            && canUndo
            && undoPreservedBuffer
            && undoGlyphRangeValid
            && undoKoreanBodyRemainsVisible
    }

    private static func runPendingEditorDecoration() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    private static func visibleGlyphRangeIsValid(in textView: NSTextView) -> Bool {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else {
            return false
        }
        let glyphRange = layoutManager.glyphRange(
            forBoundingRect: textView.visibleRect,
            in: textContainer
        )
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        return characterRange.location != NSNotFound
            && characterRange.location >= 0
            && characterRange.location + characterRange.length <= (textView.string as NSString).length
    }
}
