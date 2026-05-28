import AppKit
import Darwin
import Foundation
import NativeMarkdownCore

struct LivePreviewProbeReport: Codable, Equatable {
    var hardCeilingPassed: Bool
    var telemetrySchema: AppTelemetryPrivacySchema
    var cases: [LivePreviewProbeCaseReport]
}

struct LivePreviewProbeCaseReport: Codable, Equatable {
    var fixtureID: String
    var byteCount: Int
    var visibleRangeLength: Int
    var iterationCount: Int
    var mode: String
    var fallbackReason: String?
    var hardCeilingPassed: Bool
    var hardCeilingViolations: [String]
    var memoryDeltaBytes: Int?
    var appKitControlCountBefore: Int
    var appKitControlCountAfter: Int
    var appKitControlDelta: Int
    var blockCount: Int
    var tableCellCount: Int
    var embedCount: Int
    var stages: [LivePreviewProbeStageReport]
}

struct LivePreviewProbeStageReport: Codable, Equatable {
    var stageName: String
    var iterationCount: Int
    var p50Milliseconds: Double?
    var p95Milliseconds: Double?
    var p99Milliseconds: Double?
    var maxMilliseconds: Double?
}

@MainActor
enum LivePreviewProbe {
    static func encodedReport(_ report: LivePreviewProbeReport = run()) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try! encoder.encode(report)
        return String(decoding: data, as: UTF8.self)
    }

    static func run() -> LivePreviewProbeReport {
        let cases = fixtures().map(measure)
        return LivePreviewProbeReport(
            hardCeilingPassed: cases.allSatisfy(\.hardCeilingPassed),
            telemetrySchema: AppTelemetry.privacySchema,
            cases: cases
        )
    }

    private static func measure(_ fixture: LivePreviewProbeFixture) -> LivePreviewProbeCaseReport {
        let strategy = EditorStrategyDecision()
        let thresholds = strategy.thresholds
        var samples: [String: [Double]] = [:]
        var mode = "live-preview"
        var fallbackReason: String?
        var blockCount = 0
        var tableCellCount = 0
        var embedCount = 0
        let documentLength = (fixture.document as NSString).length
        let visibleLength = min(fixture.visibleRangeLength, documentLength)
        let visibleLocation = min(
            max(0, fixture.visibleRangeLocation),
            max(0, documentLength - visibleLength)
        )
        let visibleRange = NSRange(location: visibleLocation, length: visibleLength)
        let textView = MarkdownEditorTextViewFactory.makeTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 900, height: 1400)
        textView.textContainer?.containerSize = NSSize(width: 900, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.string = fixture.document
        let memoryBefore = residentMemoryBytes()
        let controlCountBefore = appKitControlCount(in: textView)

        for _ in 0..<fixture.iterations {
            var profile: EditorDocumentProfile!
            record("documentProfile", in: &samples) {
                profile = EditorDocumentProfiler.profile(fixture.document)
            }

            switch strategy.renderingMode(for: profile) {
            case .decoratedSource:
                mode = "live-preview"
                fallbackReason = nil
                measureDecorated(
                    fixture.document,
                    textView: textView,
                    visibleRange: visibleRange,
                    samples: &samples,
                    blockCount: &blockCount,
                    tableCellCount: &tableCellCount,
                    embedCount: &embedCount
                )
            case .degradedSource(let reason):
                mode = "degraded-source"
                fallbackReason = reason.rawValue
                measureFallback(
                    textView: textView,
                    visibleRange: visibleRange,
                    reason: reason,
                    samples: &samples
                )
            }
        }

        let memoryAfter = residentMemoryBytes()
        let controlCountAfter = appKitControlCount(in: textView)
        let controlDelta = max(0, controlCountAfter - controlCountBefore)
        let memoryDelta = memoryBefore.flatMap { before in
            memoryAfter.map { max(0, $0 - before) }
        }
        let stages = samples.map { stageName, values in
            stageReport(name: stageName, samples: values)
        }.sorted { $0.stageName < $1.stageName }
        let hardCeilingViolations = fallbackReason == nil
            ? violations(
                stages: stages,
                memoryDeltaBytes: memoryDelta,
                appKitControlDelta: controlDelta,
                thresholds: thresholds
            )
            : []

        return LivePreviewProbeCaseReport(
            fixtureID: fixture.id,
            byteCount: fixture.document.utf8.count,
            visibleRangeLength: visibleRange.length,
            iterationCount: fixture.iterations,
            mode: mode,
            fallbackReason: fallbackReason,
            hardCeilingPassed: hardCeilingViolations.isEmpty,
            hardCeilingViolations: hardCeilingViolations,
            memoryDeltaBytes: memoryDelta,
            appKitControlCountBefore: controlCountBefore,
            appKitControlCountAfter: controlCountAfter,
            appKitControlDelta: controlDelta,
            blockCount: blockCount,
            tableCellCount: tableCellCount,
            embedCount: embedCount,
            stages: stages
        )
    }

    private static func measureDecorated(
        _ document: String,
        textView: NSTextView,
        visibleRange: NSRange,
        samples: inout [String: [Double]],
        blockCount: inout Int,
        tableCellCount: inout Int,
        embedCount: inout Int
    ) {
        var parsed: LivePreviewParseResult!
        var parseWindow: LivePreviewSourceRange!
        var listResolution: LivePreviewListMarkerResolution!
        record("parse", in: &samples) {
            parseWindow = LivePreviewVisibleParseWindow.window(
                in: document,
                visibleRange: LivePreviewSourceRange(location: visibleRange.location, length: visibleRange.length),
                paddingLines: 2,
                maxUTF16Length: max(visibleRange.length + 4_096, 8_192)
            )
            parsed = LivePreviewParser.parse(document, in: parseWindow)
        }
        record("listDepthResolve", in: &samples) {
            listResolution = LivePreviewListMarkerResolver.resolve(
                source: document,
                blocks: parsed.blocks,
                parseWindow: parseWindow
            )
        }
        record("spanDiff", in: &samples) {
            blockCount = parsed.blocks.count
            _ = parsed.blocks.reduce(0) { $0 + $1.inlineSpans.count }
        }
        record("widgetBuild", in: &samples) {
            tableCellCount = parsed.blocks.compactMap {
                LivePreviewTableParser.parse($0, in: document)
            }.reduce(0) { $0 + $1.cellCount }
        }
        record("embedParse", in: &samples) {
            embedCount = LivePreviewEmbedParser.parse(document).count
        }
        var listGuideSegmentCount = 0
        record("listGuideBuild", in: &samples) {
            listGuideSegmentCount = guideSegmentCount(
                contexts: Array(listResolution.contextsByBlockRange.values)
            )
        }
        record("listGuideDrawPlanning", in: &samples) {
            _ = listGuideSegmentCount + listResolution.contextsByBlockRange.count
        }
        record("textKitApply", in: &samples) {
            MarkdownVisibleRangeDecorator.decorateVisibleRange(
                in: textView,
                range: visibleRange
            )
        }
        for location in selectionSweepLocations(documentLength: (document as NSString).length, visibleRange: visibleRange) {
            let selection = NSRange(location: location, length: 0)
            textView.setSelectedRange(selection)
            record("selectionSweep", in: &samples) {
                MarkdownVisibleRangeDecorator.decorateVisibleRange(
                    in: textView,
                    range: visibleRange,
                    revealRange: selection
                )
            }
        }
    }

    private static func measureFallback(
        textView: NSTextView,
        visibleRange: NSRange,
        reason: EditorDegradationReason,
        samples: inout [String: [Double]]
    ) {
        record("textKitApply", in: &samples) {
            MarkdownVisibleRangeDecorator.decorateVisibleRange(
                in: textView,
                range: visibleRange,
                livePreviewMode: .fallbackSource(reason: reason)
            )
        }
    }

    private static func record(
        _ stageName: String,
        in samples: inout [String: [Double]],
        _ work: () -> Void
    ) {
        let start = DispatchTime.now().uptimeNanoseconds
        work()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        samples[stageName, default: []].append(elapsed.rounded(toPlaces: 3))
    }

    private static func guideSegmentCount(contexts: [LivePreviewListMarkerContext]) -> Int {
        let sorted = contexts.sorted { $0.blockRange.location < $1.blockRange.location }
        guard sorted.count > 1 else {
            return 0
        }

        var count = 0
        for index in sorted.indices {
            let parent = sorted[index]
            let childStartIndex = index + 1
            guard childStartIndex < sorted.endIndex,
                  sorted[childStartIndex].clusterID == parent.clusterID,
                  sorted[childStartIndex].depth > parent.depth
            else {
                continue
            }
            count += 1
        }
        return count
    }

    private static func stageReport(name: String, samples: [Double]) -> LivePreviewProbeStageReport {
        LivePreviewProbeStageReport(
            stageName: name,
            iterationCount: samples.count,
            p50Milliseconds: percentile(samples, fraction: 0.50),
            p95Milliseconds: percentile(samples, fraction: 0.95),
            p99Milliseconds: percentile(samples, fraction: 0.99),
            maxMilliseconds: samples.max()
        )
    }

    private static func violations(
        stages: [LivePreviewProbeStageReport],
        memoryDeltaBytes: Int?,
        appKitControlDelta: Int,
        thresholds: EditorDegradationThresholds
    ) -> [String] {
        var violations: [String] = []
        if p95("parse", in: stages) > thresholds.maxVisibleParseP95Milliseconds {
            violations.append("parse")
        }
        for stageName in ["spanDiff", "embedParse", "widgetBuild"] {
            if p95(stageName, in: stages) > thresholds.maxVisibleRenderP95Milliseconds {
                violations.append(stageName)
            }
        }
        if p95("textKitApply", in: stages) > thresholds.maxVisibleDecorationP95Milliseconds {
            violations.append("textKitApply")
        }
        if p95("selectionSweep", in: stages) > thresholds.maxVisibleDecorationP95Milliseconds {
            violations.append("selectionSweep")
        }
        if let memoryDeltaBytes,
           memoryDeltaBytes > thresholds.maxRenderMemoryDeltaBytes {
            violations.append("memoryDeltaBytes")
        }
        if appKitControlDelta > 0 {
            violations.append("appKitControlDelta")
        }
        return violations
    }

    private static func appKitControlCount(in view: NSView) -> Int {
        let ownCount = view is NSControl ? 1 : 0
        return view.subviews.reduce(ownCount) { total, subview in
            total + appKitControlCount(in: subview)
        }
    }

    private static func p95(_ stageName: String, in stages: [LivePreviewProbeStageReport]) -> Double {
        stages.first { $0.stageName == stageName }?.p95Milliseconds ?? 0
    }

    private static func percentile(_ samples: [Double], fraction: Double) -> Double? {
        guard !samples.isEmpty else {
            return nil
        }
        let sorted = samples.sorted()
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded(.up)))
        return sorted[index]
    }

    private static func residentMemoryBytes() -> Int? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<natural_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return nil
        }
        return Int(info.resident_size)
    }

    private static func fixtures() -> [LivePreviewProbeFixture] {
        let nested100KB = nestedListDenseDocument(targetBytes: 100 * 1024)
        let nested1MB = nestedListDenseDocument(targetBytes: 1024 * 1024)
        return [
            LivePreviewProbeFixture(id: "compatibility-100kb", document: markdownDocument(targetBytes: 100 * 1024), iterations: 10),
            LivePreviewProbeFixture(id: "compatibility-1mb", document: markdownDocument(targetBytes: 1024 * 1024), iterations: 5),
            LivePreviewProbeFixture(id: "horizontal-rule-dense", document: horizontalRuleDenseDocument(targetBytes: 100 * 1024), iterations: 10),
            LivePreviewProbeFixture(id: "marker-policy-dense", document: markerPolicyDenseDocument(targetBytes: 100 * 1024), iterations: 10),
            LivePreviewProbeFixture(id: "nested-list-100kb-top", document: nested100KB, iterations: 10),
            LivePreviewProbeFixture(
                id: "nested-list-100kb-middle",
                document: nested100KB,
                iterations: 10,
                visibleRangeLocation: middleVisibleLocation(in: nested100KB)
            ),
            LivePreviewProbeFixture(
                id: "nested-list-100kb-end",
                document: nested100KB,
                iterations: 10,
                visibleRangeLocation: endVisibleLocation(in: nested100KB)
            ),
            LivePreviewProbeFixture(
                id: "nested-list-1mb-middle",
                document: nested1MB,
                iterations: 5,
                visibleRangeLocation: middleVisibleLocation(in: nested1MB)
            ),
            LivePreviewProbeFixture(id: "attachment-heavy", document: attachmentHeavyDocument(count: 40), iterations: 5),
            LivePreviewProbeFixture(id: "table-heavy", document: tableDocument(columns: 20, rows: 50), iterations: 5),
            LivePreviewProbeFixture(id: "huge-table", document: tableDocument(columns: 100, rows: 100), iterations: 3),
            LivePreviewProbeFixture(id: "long-line", document: String(repeating: "x", count: 100_001), iterations: 3)
        ]
    }

    private static func markdownDocument(targetBytes: Int) -> String {
        let header = "# Heading\n![[image.png]]\n\n"
        let line = """
        > Quote with [[Wiki Link]] and #tag/native
        - **Strong** and *emphasis* with `code`
        Regular paragraph with [label](https://example.invalid) and Korean text.

        """
        let repeatCount = targetBytes / line.utf8.count + 1
        return header + String(repeating: line, count: repeatCount)
    }

    private static func horizontalRuleDenseDocument(targetBytes: Int) -> String {
        let line = """
        Paragraph before a rule with [[Wiki Link]] and #tag/native.
        ---
        Paragraph after hyphen rule.
        ***
        Paragraph after star rule.
        ___

        """
        let repeatCount = targetBytes / line.utf8.count + 1
        return "# Horizontal Rules\n\n" + String(repeating: line, count: repeatCount)
    }

    private static func markerPolicyDenseDocument(targetBytes: Int) -> String {
        let line = """
        # Section
        - Bullet item with **strong** text
        - [x] Completed task
        > Quote with `code`
        > [!note] Callout body
        Regular context paragraph with [[Wiki Link]], #tag/native, **strong** text, and enough prose to keep the dense marker fixture close to real notes instead of thousands of tiny blocks.

        """
        let repeatCount = targetBytes / line.utf8.count + 1
        return "---\nstatus: dense\n---\n\n" + String(repeating: line, count: repeatCount)
    }

    private static func nestedListDenseDocument(targetBytes: Int) -> String {
        let section = """
        ## Nested Section
        - Bullet parent
          - Bullet child with [[Wiki Link]] and #tag/native
            - Bullet grandchild with **strong** text
        1. Ordered parent
           1. Ordered child
              10. Ordered grandchild
        - [ ] Task parent
          - [x] Task child
            - [ ] Task grandchild
        - Mixed parent
          1. Mixed ordered child
             - [ ] Mixed task grandchild

        Paragraph break between clusters.

        ---

        | Name | Status |
        | --- | --- |
        | Alpha | Draft |

        ```markdown
        - Not a rendered child
        ```

        """
        let repeatCount = targetBytes / section.utf8.count + 1
        return "# Nested List Dense Fixture\n\n" + String(repeating: section, count: repeatCount)
    }

    private static func middleVisibleLocation(in document: String, visibleRangeLength: Int = 16_384) -> Int {
        let length = (document as NSString).length
        return max(0, length / 2 - visibleRangeLength / 2)
    }

    private static func endVisibleLocation(in document: String, visibleRangeLength: Int = 16_384) -> Int {
        max(0, (document as NSString).length - visibleRangeLength)
    }

    private static func attachmentHeavyDocument(count: Int) -> String {
        (0..<count).map { index in
            "![fixture-\(index)](fixture-\(index).png)"
        }.joined(separator: "\n")
    }

    private static func tableDocument(columns: Int, rows: Int) -> String {
        let header = "| " + (0..<columns).map { "C\($0)" }.joined(separator: " | ") + " |"
        let alignment = "| " + Array(repeating: "---", count: columns).joined(separator: " | ") + " |"
        let row = "| " + (0..<columns).map { "v\($0)" }.joined(separator: " | ") + " |"
        return ([header, alignment] + Array(repeating: row, count: rows)).joined(separator: "\n")
    }

    private static func selectionSweepLocations(documentLength: Int, visibleRange: NSRange) -> [Int] {
        guard documentLength > 0 else {
            return [0]
        }
        let lower = min(max(0, visibleRange.location), documentLength)
        let upper = min(documentLength, max(lower, visibleRange.location + visibleRange.length))
        let midpoint = lower + max(0, upper - lower) / 2
        return [
            lower,
            min(documentLength, lower + 1_024),
            midpoint,
            max(lower, upper - 1_024),
            upper
        ].map { min(max(0, $0), documentLength) }
    }
}

private struct LivePreviewProbeFixture {
    var id: String
    var document: String
    var iterations: Int
    var visibleRangeLength: Int = 16_384
    var visibleRangeLocation: Int = 0
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
