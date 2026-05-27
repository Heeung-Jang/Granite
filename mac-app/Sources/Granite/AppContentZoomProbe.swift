import Foundation
import NativeMarkdownCore

struct AppContentZoomProbeReport: Codable, Equatable {
    var defaultScaleIsActualSize: Bool
    var invalidScaleNormalizesToDefault: Bool
    var scaleClampsToMinimum: Bool
    var scaleClampsToMaximum: Bool
    var zoomInRoundsToStep: Bool
    var zoomOutRoundsToStep: Bool
    var resetReturnsToActualSize: Bool
    var userDefaultsRoundTripsNormalizedScale: Bool
    var uiMetricsDefaultMatchConstants: Bool
    var ribbonWidthScales: Bool
    var tabBarHeightScales: Bool
    var noteToolbarHeightScales: Bool
    var statusBarHeightScales: Bool
    var iconButtonMetricsScale: Bool
    var paneDisplayedWidthsScaleFromLogical: Bool
    var leftPaneDragConvertsDisplayedDeltaToLogicalWidth: Bool
    var rightPaneDragConvertsDisplayedDeltaToLogicalWidth: Bool
    var workspaceAvailableWidthSubtractsScaledRibbon: Bool
    var summary: ProbeCheckSummary
}

enum AppContentZoomProbe {
    static func run() -> AppContentZoomProbeReport {
        var report = AppContentZoomProbeReport(
            defaultScaleIsActualSize: AppContentZoom().scale == AppContentZoom.defaultScale
                && AppContentZoom.actualSize.scale == 1.0,
            invalidScaleNormalizesToDefault: AppContentZoom(rawScale: .nan).scale == 1.0
                && AppContentZoom(rawScale: .infinity).scale == 1.0
                && AppContentZoom(rawScale: -.infinity).scale == 1.0,
            scaleClampsToMinimum: AppContentZoom(rawScale: 0.1).scale == AppContentZoom.minimumScale,
            scaleClampsToMaximum: AppContentZoom(rawScale: 3.0).scale == AppContentZoom.maximumScale,
            zoomInRoundsToStep: AppContentZoom(rawScale: 1.0).zoomedIn().scale == 1.1,
            zoomOutRoundsToStep: AppContentZoom(rawScale: 1.0).zoomedOut().scale == 0.9,
            resetReturnsToActualSize: AppContentZoom.actualSize.scale == AppContentZoom.defaultScale,
            userDefaultsRoundTripsNormalizedScale: userDefaultsRoundTripsNormalizedScale(),
            uiMetricsDefaultMatchConstants: uiMetricsDefaultMatchConstants(),
            ribbonWidthScales: ObsidianUI.ribbonWidth(scale: 1.25) == 60,
            tabBarHeightScales: ObsidianUI.tabBarHeight(scale: 1.25) == 53.75,
            noteToolbarHeightScales: ObsidianUI.noteToolbarHeight(scale: 1.25) == 52.5,
            statusBarHeightScales: ObsidianUI.statusBarHeight(scale: 1.25) == 32.5,
            iconButtonMetricsScale: ObsidianUI.iconButtonSize(scale: 1.25) == 37.5
                && ObsidianUI.iconFontSize(scale: 1.25) == 20
                && ObsidianUI.iconCornerRadius(scale: 1.25) == 7.5,
            paneDisplayedWidthsScaleFromLogical: ObsidianUI.displayedPaneWidth(logicalWidth: 272, scale: 1.25) == 340
                && ObsidianUI.logicalPaneWidth(displayedWidth: 340, scale: 1.25) == 272,
            leftPaneDragConvertsDisplayedDeltaToLogicalWidth: ObsidianPaneSplitSide.left.proposedWidth(
                startWidth: 272,
                translationWidth: 25,
                appContentZoomScale: 1.25
            ) == 292,
            rightPaneDragConvertsDisplayedDeltaToLogicalWidth: ObsidianPaneSplitSide.right.proposedWidth(
                startWidth: 300,
                translationWidth: 25,
                appContentZoomScale: 1.25
            ) == 280,
            workspaceAvailableWidthSubtractsScaledRibbon: ObsidianUI.logicalWorkspaceAvailableWidth(
                displayedWidth: 1_440,
                scale: 1.25
            ) == 1_104,
            summary: .passed
        )
        report.summary = ProbeCheckSummary.evaluate(report: report)
        return report
    }

    static func encodedReport(_ report: AppContentZoomProbeReport = run()) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report),
              let string = String(data: data, encoding: .utf8)
        else {
            return #"{"summary":{"passed":false,"unexpectedFailures":["encoding"],"expectedFailures":[]}}"#
        }
        return string
    }

    private static func userDefaultsRoundTripsNormalizedScale() -> Bool {
        let suiteName = "AppContentZoomProbe.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return false
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set(AppContentZoom(rawScale: 1.234).scale, forKey: AppContentZoom.storageKey)
        return defaults.double(forKey: AppContentZoom.storageKey) == 1.23
    }

    private static func uiMetricsDefaultMatchConstants() -> Bool {
        ObsidianUI.ribbonWidth(scale: 1.0) == ObsidianUI.ribbonWidth
            && ObsidianUI.tabBarHeight(scale: 1.0) == ObsidianUI.tabBarHeight
            && ObsidianUI.noteToolbarHeight(scale: 1.0) == ObsidianUI.noteToolbarHeight
            && ObsidianUI.statusBarHeight(scale: 1.0) == ObsidianUI.statusBarHeight
            && ObsidianUI.iconButtonSize(scale: 1.0) == 30
            && ObsidianUI.iconFontSize(scale: 1.0) == 16
            && ObsidianUI.iconCornerRadius(scale: 1.0) == 6
    }
}
