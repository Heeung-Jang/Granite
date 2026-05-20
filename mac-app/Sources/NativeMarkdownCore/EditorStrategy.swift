import Foundation

public enum EditorTextSystemStrategy: String, Sendable {
    case textKit1Compatibility = "textkit1-compatibility"
}

public enum EditorRenderingMode: Equatable, Sendable {
    case decoratedSource
    case degradedSource(reason: EditorDegradationReason)
}

public enum EditorDegradationReason: String, CaseIterable, Sendable {
    case fileTooLarge
    case singleLineTooLong
    case tooManyEmbeds
    case tooManyWidgets
    case tooManyAttachments
    case tooManyTableCells
    case tooManySpans
    case visibleParseTooSlow
    case visibleRenderTooSlow
    case memoryDeltaTooHigh
    case decorationTooSlow
    case typingTooSlow

    public var displayText: String {
        switch self {
        case .fileTooLarge:
            return "file is over the safe size limit"
        case .singleLineTooLong:
            return "a line is over the safe length limit"
        case .tooManyEmbeds:
            return "embed count is over the safe limit"
        case .tooManyWidgets:
            return "widget count is over the safe limit"
        case .tooManyAttachments:
            return "attachment count is over the safe limit"
        case .tooManyTableCells:
            return "table cell count is over the safe limit"
        case .tooManySpans:
            return "render span count is over the safe limit"
        case .visibleParseTooSlow:
            return "visible Markdown parsing exceeded the latency budget"
        case .visibleRenderTooSlow:
            return "visible rendering exceeded the latency budget"
        case .memoryDeltaTooHigh:
            return "rendering memory growth exceeded the safe limit"
        case .decorationTooSlow:
            return "source decoration exceeded the latency budget"
        case .typingTooSlow:
            return "typing latency exceeded the budget"
        }
    }

    public var isTransient: Bool {
        switch self {
        case .visibleParseTooSlow, .visibleRenderTooSlow, .memoryDeltaTooHigh, .decorationTooSlow, .typingTooSlow:
            return true
        case .fileTooLarge, .singleLineTooLong, .tooManyEmbeds, .tooManyWidgets, .tooManyAttachments, .tooManyTableCells, .tooManySpans:
            return false
        }
    }
}

public struct EditorDegradationThresholds: Equatable, Sendable {
    public var maxDecoratedFileBytes: Int
    public var maxSingleLineCharacters: Int
    public var maxEmbedCount: Int
    public var maxWidgetCount: Int
    public var maxAttachmentCount: Int
    public var maxTableCellCount: Int
    public var maxSpanCount: Int
    public var maxVisibleParseP95Milliseconds: Double
    public var maxVisibleRenderP95Milliseconds: Double
    public var maxRenderMemoryDeltaBytes: Int
    public var maxVisibleDecorationP95Milliseconds: Double
    public var maxTypingP95Milliseconds: Double

    public init(
        maxDecoratedFileBytes: Int = 5 * 1024 * 1024,
        maxSingleLineCharacters: Int = 100_000,
        maxEmbedCount: Int = 100,
        maxWidgetCount: Int = 250,
        maxAttachmentCount: Int = 100,
        maxTableCellCount: Int = 10_000,
        maxSpanCount: Int = 50_000,
        maxVisibleParseP95Milliseconds: Double = 50,
        maxVisibleRenderP95Milliseconds: Double = 50,
        maxRenderMemoryDeltaBytes: Int = 64 * 1024 * 1024,
        maxVisibleDecorationP95Milliseconds: Double = 50,
        maxTypingP95Milliseconds: Double = 16
    ) {
        self.maxDecoratedFileBytes = maxDecoratedFileBytes
        self.maxSingleLineCharacters = maxSingleLineCharacters
        self.maxEmbedCount = maxEmbedCount
        self.maxWidgetCount = maxWidgetCount
        self.maxAttachmentCount = maxAttachmentCount
        self.maxTableCellCount = maxTableCellCount
        self.maxSpanCount = maxSpanCount
        self.maxVisibleParseP95Milliseconds = maxVisibleParseP95Milliseconds
        self.maxVisibleRenderP95Milliseconds = maxVisibleRenderP95Milliseconds
        self.maxRenderMemoryDeltaBytes = maxRenderMemoryDeltaBytes
        self.maxVisibleDecorationP95Milliseconds = maxVisibleDecorationP95Milliseconds
        self.maxTypingP95Milliseconds = maxTypingP95Milliseconds
    }
}

public struct EditorDocumentProfile: Equatable, Sendable {
    public var byteCount: Int
    public var longestLineCharacters: Int
    public var embedCount: Int
    public var widgetCount: Int
    public var attachmentCount: Int
    public var tableCellCount: Int
    public var spanCount: Int
    public var visibleParseP95Milliseconds: Double?
    public var visibleRenderP95Milliseconds: Double?
    public var renderMemoryDeltaBytes: Int?
    public var visibleDecorationP95Milliseconds: Double?
    public var typingP95Milliseconds: Double?

    public init(
        byteCount: Int,
        longestLineCharacters: Int,
        embedCount: Int,
        widgetCount: Int = 0,
        attachmentCount: Int = 0,
        tableCellCount: Int = 0,
        spanCount: Int = 0,
        visibleParseP95Milliseconds: Double? = nil,
        visibleRenderP95Milliseconds: Double? = nil,
        renderMemoryDeltaBytes: Int? = nil,
        visibleDecorationP95Milliseconds: Double? = nil,
        typingP95Milliseconds: Double? = nil
    ) {
        self.byteCount = byteCount
        self.longestLineCharacters = longestLineCharacters
        self.embedCount = embedCount
        self.widgetCount = widgetCount
        self.attachmentCount = attachmentCount
        self.tableCellCount = tableCellCount
        self.spanCount = spanCount
        self.visibleParseP95Milliseconds = visibleParseP95Milliseconds
        self.visibleRenderP95Milliseconds = visibleRenderP95Milliseconds
        self.renderMemoryDeltaBytes = renderMemoryDeltaBytes
        self.visibleDecorationP95Milliseconds = visibleDecorationP95Milliseconds
        self.typingP95Milliseconds = typingP95Milliseconds
    }
}

public struct EditorStrategyDecision: Equatable, Sendable {
    public var textSystem: EditorTextSystemStrategy
    public var thresholds: EditorDegradationThresholds

    public init(
        textSystem: EditorTextSystemStrategy = .textKit1Compatibility,
        thresholds: EditorDegradationThresholds = EditorDegradationThresholds()
    ) {
        self.textSystem = textSystem
        self.thresholds = thresholds
    }

    public func renderingMode(for profile: EditorDocumentProfile) -> EditorRenderingMode {
        if profile.byteCount > thresholds.maxDecoratedFileBytes {
            return .degradedSource(reason: .fileTooLarge)
        }
        if profile.longestLineCharacters > thresholds.maxSingleLineCharacters {
            return .degradedSource(reason: .singleLineTooLong)
        }
        if profile.embedCount > thresholds.maxEmbedCount {
            return .degradedSource(reason: .tooManyEmbeds)
        }
        if profile.widgetCount > thresholds.maxWidgetCount {
            return .degradedSource(reason: .tooManyWidgets)
        }
        if profile.attachmentCount > thresholds.maxAttachmentCount {
            return .degradedSource(reason: .tooManyAttachments)
        }
        if profile.tableCellCount > thresholds.maxTableCellCount {
            return .degradedSource(reason: .tooManyTableCells)
        }
        if profile.spanCount > thresholds.maxSpanCount {
            return .degradedSource(reason: .tooManySpans)
        }
        if let p95 = profile.visibleParseP95Milliseconds,
           p95 > thresholds.maxVisibleParseP95Milliseconds {
            return .degradedSource(reason: .visibleParseTooSlow)
        }
        if let p95 = profile.visibleRenderP95Milliseconds,
           p95 > thresholds.maxVisibleRenderP95Milliseconds {
            return .degradedSource(reason: .visibleRenderTooSlow)
        }
        if let bytes = profile.renderMemoryDeltaBytes,
           bytes > thresholds.maxRenderMemoryDeltaBytes {
            return .degradedSource(reason: .memoryDeltaTooHigh)
        }
        if let p95 = profile.visibleDecorationP95Milliseconds,
           p95 > thresholds.maxVisibleDecorationP95Milliseconds {
            return .degradedSource(reason: .decorationTooSlow)
        }
        if let p95 = profile.typingP95Milliseconds,
           p95 > thresholds.maxTypingP95Milliseconds {
            return .degradedSource(reason: .typingTooSlow)
        }
        return .decoratedSource
    }
}

public enum EditorDocumentProfiler {
    public static func profile(
        _ text: String,
        visibleDecorationP95Milliseconds: Double? = nil,
        typingP95Milliseconds: Double? = nil
    ) -> EditorDocumentProfile {
        var longestLineCharacters = 0
        var currentLineCharacters = 0

        for character in text {
            if character == "\n" {
                longestLineCharacters = max(longestLineCharacters, currentLineCharacters)
                currentLineCharacters = 0
            } else {
                currentLineCharacters += 1
            }
        }
        longestLineCharacters = max(longestLineCharacters, currentLineCharacters)

        return EditorDocumentProfile(
            byteCount: text.utf8.count,
            longestLineCharacters: longestLineCharacters,
            embedCount: countOccurrences(of: "![", in: text),
            attachmentCount: countOccurrences(of: "![", in: text),
            visibleDecorationP95Milliseconds: visibleDecorationP95Milliseconds,
            typingP95Milliseconds: typingP95Milliseconds
        )
    }

    private static func countOccurrences(of needle: String, in text: String) -> Int {
        var count = 0
        var searchRange = text.startIndex..<text.endIndex

        while let range = text.range(of: needle, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<text.endIndex
        }

        return count
    }
}
