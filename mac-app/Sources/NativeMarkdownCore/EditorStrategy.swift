import Foundation

public enum EditorTextSystemStrategy: String, Sendable {
    case textKit1Compatibility = "textkit1-compatibility"
}

public enum EditorRenderingMode: Equatable, Sendable {
    case decoratedSource
    case degradedSource(reason: EditorDegradationReason)
}

public enum EditorDegradationReason: String, Sendable {
    case fileTooLarge
    case singleLineTooLong
    case tooManyEmbeds
    case decorationTooSlow
    case typingTooSlow
}

public struct EditorDegradationThresholds: Equatable, Sendable {
    public var maxDecoratedFileBytes: Int
    public var maxSingleLineCharacters: Int
    public var maxEmbedCount: Int
    public var maxVisibleDecorationP95Milliseconds: Double
    public var maxTypingP95Milliseconds: Double

    public init(
        maxDecoratedFileBytes: Int = 5 * 1024 * 1024,
        maxSingleLineCharacters: Int = 100_000,
        maxEmbedCount: Int = 100,
        maxVisibleDecorationP95Milliseconds: Double = 50,
        maxTypingP95Milliseconds: Double = 16
    ) {
        self.maxDecoratedFileBytes = maxDecoratedFileBytes
        self.maxSingleLineCharacters = maxSingleLineCharacters
        self.maxEmbedCount = maxEmbedCount
        self.maxVisibleDecorationP95Milliseconds = maxVisibleDecorationP95Milliseconds
        self.maxTypingP95Milliseconds = maxTypingP95Milliseconds
    }
}

public struct EditorDocumentProfile: Equatable, Sendable {
    public var byteCount: Int
    public var longestLineCharacters: Int
    public var embedCount: Int
    public var visibleDecorationP95Milliseconds: Double?
    public var typingP95Milliseconds: Double?

    public init(
        byteCount: Int,
        longestLineCharacters: Int,
        embedCount: Int,
        visibleDecorationP95Milliseconds: Double? = nil,
        typingP95Milliseconds: Double? = nil
    ) {
        self.byteCount = byteCount
        self.longestLineCharacters = longestLineCharacters
        self.embedCount = embedCount
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
