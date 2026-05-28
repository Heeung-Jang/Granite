import Foundation
import NativeMarkdownCore

struct LivePreviewOverlayState: Equatable {
    var mode: LivePreviewMode
    var markerStyle: LivePreviewMarkerStyle
    var revealRange: NSRange
    var hoveredTableCell: LivePreviewTableCell?
    var activeTableCell: LivePreviewTableCell?
    var sourceVersion: Int
    var isEditable: Bool
    var hasMarkedText: Bool
    var isSelectionDragActive: Bool

    init(
        mode: LivePreviewMode = .livePreview,
        markerStyle: LivePreviewMarkerStyle = .defaultValue,
        revealRange: NSRange = NSRange(location: 0, length: 0),
        hoveredTableCell: LivePreviewTableCell? = nil,
        activeTableCell: LivePreviewTableCell? = nil,
        sourceVersion: Int = 0,
        isEditable: Bool = true,
        hasMarkedText: Bool = false,
        isSelectionDragActive: Bool = false
    ) {
        self.mode = mode
        self.markerStyle = markerStyle
        self.revealRange = revealRange
        self.hoveredTableCell = hoveredTableCell
        self.activeTableCell = activeTableCell
        self.sourceVersion = sourceVersion
        self.isEditable = isEditable
        self.hasMarkedText = hasMarkedText
        self.isSelectionDragActive = isSelectionDragActive
    }

    var drawsLivePreviewChrome: Bool {
        mode == .livePreview
    }

    var allowsTransientControls: Bool {
        mode == .livePreview && isEditable && !hasMarkedText && !isSelectionDragActive
    }

    func synchronized(
        mode: LivePreviewMode,
        markerStyle: LivePreviewMarkerStyle,
        revealRange: NSRange,
        sourceVersion: Int,
        isEditable: Bool,
        hasMarkedText: Bool,
        isSelectionDragActive: Bool
    ) -> LivePreviewOverlayState {
        let shouldClearTransientState = self.mode != mode
            || self.sourceVersion != sourceVersion
            || mode != .livePreview
            || !isEditable
            || hasMarkedText
            || isSelectionDragActive

        return LivePreviewOverlayState(
            mode: mode,
            markerStyle: markerStyle,
            revealRange: revealRange,
            hoveredTableCell: shouldClearTransientState ? nil : hoveredTableCell,
            activeTableCell: shouldClearTransientState ? nil : activeTableCell,
            sourceVersion: sourceVersion,
            isEditable: isEditable,
            hasMarkedText: hasMarkedText,
            isSelectionDragActive: isSelectionDragActive
        )
    }

    func withTableCells(
        hovered: LivePreviewTableCell?,
        active: LivePreviewTableCell?
    ) -> LivePreviewOverlayState {
        var next = self
        next.hoveredTableCell = hovered
        next.activeTableCell = active
        return next
    }
}
