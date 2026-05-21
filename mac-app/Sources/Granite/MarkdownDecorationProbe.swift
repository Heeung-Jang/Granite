import AppKit
import Foundation
import NativeMarkdownCore

struct MarkdownDecorationProbeReport: Codable, Equatable {
    var measurements: [MarkdownDecorationMeasurement]
}

struct MarkdownDecorationMeasurement: Codable, Equatable {
    var label: String
    var bytes: Int
    var mode: String
    var reason: String?
    var rangeLength: Int
    var appliedRuns: Int
    var changedRangeCount: Int
    var changedUTF16Length: Int
    var iterations: Int
    var p95Milliseconds: Double?
}

@MainActor
enum MarkdownDecorationProbe {
    static func encodedReport() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try! encoder.encode(run())
        return String(decoding: data, as: UTF8.self)
    }

    static func run() -> MarkdownDecorationProbeReport {
        MarkdownDecorationProbeReport(measurements: [
            measurement(label: "100KB", targetBytes: 100 * 1024),
            measurement(label: "1MB", targetBytes: 1024 * 1024),
            measurement(label: "5MB", targetBytes: 5 * 1024 * 1024)
        ])
    }

    private static func measurement(label: String, targetBytes: Int) -> MarkdownDecorationMeasurement {
        let document = markdownDocument(targetBytes: targetBytes)
        let profile = EditorDocumentProfiler.profile(document)
        let strategy = EditorStrategyDecision()
        let textView = MarkdownEditorTextViewFactory.makeTextView()
        textView.string = document
        let range = NSRange(location: 0, length: min(16_384, (document as NSString).length))

        if case .degradedSource(let reason) = strategy.renderingMode(for: profile) {
            return MarkdownDecorationMeasurement(
                label: label,
                bytes: document.utf8.count,
                mode: "degraded-source",
                reason: reason.rawValue,
                rangeLength: 0,
                appliedRuns: 0,
                changedRangeCount: 0,
                changedUTF16Length: 0,
                iterations: 0,
                p95Milliseconds: nil
            )
        }

        var samples: [Double] = []
        var firstResult: MarkdownDecorationResult?
        for _ in 0..<20 {
            let start = DispatchTime.now().uptimeNanoseconds
            let result = MarkdownVisibleRangeDecorator.decorateVisibleRange(
                in: textView,
                range: range
            )
            let end = DispatchTime.now().uptimeNanoseconds
            if firstResult == nil {
                firstResult = result
            }
            samples.append((Double(end - start) / 1_000_000).rounded(toPlaces: 3))
        }
        let result = firstResult ?? MarkdownDecorationResult(
            mode: "decorated-source",
            reason: nil,
            rangeLength: 0,
            appliedRuns: 0,
            changedRangeCount: 0,
            changedUTF16Length: 0,
            elapsedMilliseconds: 0
        )

        return MarkdownDecorationMeasurement(
            label: label,
            bytes: document.utf8.count,
            mode: result.mode,
            reason: result.reason,
            rangeLength: result.rangeLength,
            appliedRuns: result.appliedRuns,
            changedRangeCount: result.changedRangeCount,
            changedUTF16Length: result.changedUTF16Length,
            iterations: samples.count,
            p95Milliseconds: percentile95(samples)
        )
    }

    private static func markdownDocument(targetBytes: Int) -> String {
        let header = "# Heading\n![[image.png]]\n"
        let line = """
        > Quote with [[Wiki Link]] and #tag/native
        - **Strong** and *emphasis* with `code`

        """
        let repeatCount = targetBytes / line.utf8.count + 1
        return header + String(repeating: line, count: repeatCount)
    }

    private static func percentile95(_ samples: [Double]) -> Double? {
        guard !samples.isEmpty else {
            return nil
        }
        let sorted = samples.sorted()
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * 0.95).rounded(.up)))
        return sorted[index]
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
