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
}
