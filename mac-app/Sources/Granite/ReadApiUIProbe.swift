import Foundation
import NativeMarkdownCore

struct ReadApiUIProbeReport: Codable, Equatable {
    var schemaVersion: Int
    var mode: String
    var hardCeilingPassed: Bool
    var placeholderLatencyMilliseconds: Double
    var fileTree: ReadApiUIProbeMetric
    var search: ReadApiUIProbeMetric
    var inspectorBacklinks: ReadApiUIProbeMetric
    var mainThread: ReadApiUIProbeMainThreadReport
    var notes: [String]
}

struct ReadApiUIProbeMetric: Codable, Equatable {
    var iterationCount: Int
    var resultCounts: [Int]
    var p50Milliseconds: Double?
    var p95Milliseconds: Double?
    var p99Milliseconds: Double?
}

struct ReadApiUIProbeMainThreadReport: Codable, Equatable {
    var maxStallMilliseconds: Double
    var stallCountOver50Milliseconds: Int
    var sampleCount: Int
}

private struct ReadApiUIProbeConfiguration: Sendable {
    var fixture: Bool
    var vaultRoot: URL?
    var outputURL: URL?
    var query: String
    var limit: Int
    var iterations: Int
}

enum ReadApiUIProbe {
    static func helpText() -> String {
        """
        Granite probe flags:
          --read-api-ui-probe        Run the Rust read API UI latency probe.
          --fixture                  Use deterministic in-memory fixture data.
          --vault-root <path>        Open the app-owned read index for a vault.
          --query <text>             Search query for the probe. Default: Smoke.
          --limit <count>            Result and sampled note limit. Default: 10.
          --iterations <count>       Measurement iterations. Default: 5.
          --output <path>            Write JSON report to a file.
        """
    }

    static func run(arguments: [String]) -> Int32 {
        do {
            let configuration = try parse(arguments: Array(arguments.dropFirst()))
            let report = try runSynchronously(configuration)
            let json = encodedReport(report)
            if let outputURL = configuration.outputURL {
                try FileManager.default.createDirectory(
                    at: outputURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try json.write(to: outputURL, atomically: true, encoding: .utf8)
            } else {
                print(json)
            }
            return report.hardCeilingPassed ? 0 : 2
        } catch {
            fputs("Granite read API UI probe: \(error)\n", stderr)
            return 2
        }
    }

    private static func parse(arguments: [String]) throws -> ReadApiUIProbeConfiguration {
        var fixture = false
        var vaultRoot: URL?
        var outputURL: URL?
        var query = "Smoke"
        var limit = 10
        var iterations = 5
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--read-api-ui-probe":
                index += 1
            case "--fixture":
                fixture = true
                index += 1
            case "--vault-root":
                vaultRoot = URL(fileURLWithPath: try value(after: argument, in: arguments, at: index))
                index += 2
            case "--output":
                outputURL = URL(fileURLWithPath: try value(after: argument, in: arguments, at: index))
                index += 2
            case "--query":
                query = try value(after: argument, in: arguments, at: index)
                index += 2
            case "--limit":
                limit = Int(try value(after: argument, in: arguments, at: index)) ?? 10
                index += 2
            case "--iterations":
                iterations = Int(try value(after: argument, in: arguments, at: index)) ?? 5
                index += 2
            default:
                throw ProbeError.unknownArgument(argument)
            }
        }

        if !fixture, vaultRoot == nil {
            throw ProbeError.missingVaultRoot
        }

        return ReadApiUIProbeConfiguration(
            fixture: fixture,
            vaultRoot: vaultRoot,
            outputURL: outputURL,
            query: query,
            limit: max(1, limit),
            iterations: max(1, iterations)
        )
    }

    private static func value(
        after argument: String,
        in arguments: [String],
        at index: Int
    ) throws -> String {
        guard arguments.indices.contains(index + 1) else {
            throw ProbeError.missingValue(argument)
        }
        return arguments[index + 1]
    }

    private static func runSynchronously(
        _ configuration: ReadApiUIProbeConfiguration
    ) throws -> ReadApiUIProbeReport {
        let box = ProbeResultBox()
        Task.detached {
            do {
                box.set(.success(try await runAsync(configuration)))
            } catch {
                box.set(.failure(error))
            }
        }

        while box.get() == nil {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        guard let result = box.get() else { throw ProbeError.missingResult }
        return try result.get()
    }

    private static func runAsync(
        _ configuration: ReadApiUIProbeConfiguration
    ) async throws -> ReadApiUIProbeReport {
        let reader = try makeReader(configuration)
        defer { reader.close() }

        let placeholderStart = DispatchTime.now().uptimeNanoseconds
        let placeholderLatency = milliseconds(since: placeholderStart)

        var stallSamples: [Double] = []
        let fileTreeMeasurement = try await measure(
            iterations: configuration.iterations,
            stallSamples: &stallSamples
        ) { _ in
            let snapshot = try await EngineFileTreeLoader(reader: reader).loadFileTree(
                requestID: 1,
                maxItems: configuration.limit
            )
            return (snapshot.items.count, snapshot.items)
        }
        let sampleFiles = (fileTreeMeasurement.lastValue ?? fixtureFiles())
            .prefix(configuration.limit)
            .map { $0 }
        let targetFiles = sampleFiles.isEmpty ? fixtureFiles() : sampleFiles

        let searchMeasurement = try await measure(
            iterations: configuration.iterations,
            stallSamples: &stallSamples
        ) { _ in
            let page = try await EngineVaultSearchLoader(reader: reader).search(
                query: configuration.query,
                mode: .fileName,
                page: SearchPageRequest(requestID: 2, offset: 0, limit: configuration.limit)
            )
            return (page.items.count, ())
        }

        let inspectorMeasurement = try await measure(
            iterations: max(1, min(configuration.iterations, targetFiles.count)),
            stallSamples: &stallSamples
        ) {
            let file = targetFiles[$0 % targetFiles.count]
            let payload = try await EngineInspectorPanelLoader(reader: reader).loadPanel(
                file: file,
                panel: .backlinks,
                requestID: UInt64(3 + $0),
                offset: 0,
                limit: configuration.limit
            )
            guard case .backlinks(let items) = payload else {
                return (0, ())
            }
            return (items.count, ())
        }

        let fileTreeMetric = metric(from: fileTreeMeasurement)
        let searchMetric = metric(from: searchMeasurement)
        let inspectorMetric = metric(from: inspectorMeasurement)
        let maxStall = stallSamples.max() ?? 0
        let mainThread = ReadApiUIProbeMainThreadReport(
            maxStallMilliseconds: maxStall.rounded(toPlaces: 3),
            stallCountOver50Milliseconds: stallSamples.filter { $0 > 50 }.count,
            sampleCount: stallSamples.count
        )
        let hardCeilingPassed = placeholderLatency <= 200
            && (inspectorMetric.p95Milliseconds ?? 0) <= 1_000
            && (inspectorMetric.p99Milliseconds ?? 0) <= 3_000

        return ReadApiUIProbeReport(
            schemaVersion: 1,
            mode: configuration.fixture ? "fixture" : "real-vault",
            hardCeilingPassed: hardCeilingPassed,
            placeholderLatencyMilliseconds: placeholderLatency.rounded(toPlaces: 3),
            fileTree: fileTreeMetric,
            search: searchMetric,
            inspectorBacklinks: inspectorMetric,
            mainThread: mainThread,
            notes: [
                "Placeholder timing measures the synchronous state transition before read calls.",
                "Main-thread stall is sampled through DispatchQueue.main latency around async read operations."
            ]
        )
    }

    private static func makeReader(
        _ configuration: ReadApiUIProbeConfiguration
    ) throws -> any EngineReading {
        if configuration.fixture {
            return FixtureReadClient()
        }
        guard let vaultRoot = configuration.vaultRoot else {
            throw ProbeError.missingVaultRoot
        }
        let location = try AppOwnedIndexDirectoryResolver()
            .prepareIndexLocation(forVaultAt: vaultRoot)
        return try EngineReadClient.open(
            metadataURL: location.metadataStoreFile,
            tantivyURL: location.tantivyIndexDirectory
        )
    }

    private static func measure<Value>(
        iterations: Int,
        stallSamples: inout [Double],
        _ operation: (Int) async throws -> (Int, Value)
    ) async throws -> ProbeMeasurement<Value> {
        var durations: [Double] = []
        var resultCounts: [Int] = []
        var lastValue: Value?

        for index in 0..<iterations {
            stallSamples.append(await mainThreadDispatchLatency())
            let start = DispatchTime.now().uptimeNanoseconds
            let (resultCount, value) = try await operation(index)
            durations.append(milliseconds(since: start).rounded(toPlaces: 3))
            resultCounts.append(resultCount)
            lastValue = value
            stallSamples.append(await mainThreadDispatchLatency())
        }

        return ProbeMeasurement(
            durations: durations,
            resultCounts: resultCounts,
            lastValue: lastValue
        )
    }

    private static func metric<Value>(from measurement: ProbeMeasurement<Value>) -> ReadApiUIProbeMetric {
        ReadApiUIProbeMetric(
            iterationCount: measurement.durations.count,
            resultCounts: measurement.resultCounts,
            p50Milliseconds: percentile(measurement.durations, fraction: 0.50),
            p95Milliseconds: percentile(measurement.durations, fraction: 0.95),
            p99Milliseconds: percentile(measurement.durations, fraction: 0.99)
        )
    }

    private static func mainThreadDispatchLatency() async -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume(returning: milliseconds(since: start).rounded(toPlaces: 3))
            }
        }
    }

    private static func encodedReport(_ report: ReadApiUIProbeReport) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try! encoder.encode(report)
        return String(decoding: data, as: UTF8.self)
    }

    private static func percentile(_ samples: [Double], fraction: Double) -> Double? {
        guard !samples.isEmpty else {
            return nil
        }
        let sorted = samples.sorted()
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded(.up)))
        return sorted[index]
    }

    private static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    fileprivate static func fixtureFiles() -> [FileTreeItem] {
        [
            FileTreeItem(relativePath: "Fixture/Alpha.md"),
            FileTreeItem(relativePath: "Fixture/Beta.md")
        ]
    }

    private enum ProbeError: Error, CustomStringConvertible {
        case missingVaultRoot
        case missingValue(String)
        case unknownArgument(String)
        case missingResult

        var description: String {
            switch self {
            case .missingVaultRoot:
                "--vault-root is required unless --fixture is used"
            case .missingValue(let argument):
                "missing value for \(argument)"
            case .unknownArgument(let argument):
                "unknown argument: \(argument)"
            case .missingResult:
                "probe did not return a result"
            }
        }
    }
}

private struct ProbeMeasurement<Value> {
    var durations: [Double]
    var resultCounts: [Int]
    var lastValue: Value?
}

private final class ProbeResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<ReadApiUIProbeReport, Error>?

    func set(_ result: Result<ReadApiUIProbeReport, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func get() -> Result<ReadApiUIProbeReport, Error>? {
        lock.lock()
        let result = result
        lock.unlock()
        return result
    }
}

private final class FixtureReadClient: EngineReading, @unchecked Sendable {
    func close() {}

    func fileTree(requestID: UInt64, offset: Int, limit: Int) async throws -> FileTreeSnapshot {
        FileTreeSnapshot(items: Array(ReadApiUIProbe.fixtureFiles().prefix(limit)), state: .complete)
    }

    func search(query: String, mode: SearchMode, page: SearchPageRequest) async throws -> SearchPage {
        SearchPage(
            requestID: page.requestID,
            items: [
                SearchHitItem(
                    file: FileTreeItem(relativePath: "Fixture/Alpha.md"),
                    title: "Alpha",
                    snippet: "Fixture search hit",
                    rank: 1
                )
            ],
            nextOffset: nil,
            state: .complete
        )
    }

    func inspectorPanel(
        file: FileTreeItem,
        panel: EngineReadInspectorPanel,
        requestID: UInt64,
        offset: Int,
        limit: Int
    ) async throws -> EngineReadInspectorPanelResult {
        switch panel {
        case .backlinks:
            return .backlinks([
                BacklinkItem(file: FileTreeItem(relativePath: "Fixture/Source.md"), snippet: "Fixture backlink")
            ])
        case .outgoing:
            return .outgoing([])
        case .tags:
            return .tags(["fixture"])
        case .properties:
            return .properties([PropertyItem(key: "fixture", value: "true")])
        case .attachments:
            return .attachments([])
        }
    }

    func localGraph(
        file: FileTreeItem,
        requestID: UInt64,
        request: LocalGraphRequest
    ) async throws -> LocalGraphSnapshot {
        LocalGraphSnapshot(
            centerNodeID: file.id,
            nodes: [LocalGraphNode(id: file.id, file: file, label: file.displayName, kind: .center)],
            edges: [],
            state: .complete
        )
    }

    func livePreviewMetadata(
        file: FileTreeItem,
        requestID: UInt64,
        contents: String
    ) async throws -> EngineLivePreviewMetadata {
        EngineLivePreviewMetadata(outgoingLinks: [], attachments: [])
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
