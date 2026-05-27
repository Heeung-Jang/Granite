import Foundation

public struct DocumentSummary: Equatable, Sendable {
    public let overview: String
    public let keyPoints: [String]
    public let actionItems: [String]
    public let metadata: SummaryMetadata

    public init(
        overview: String,
        keyPoints: [String],
        actionItems: [String],
        metadata: SummaryMetadata
    ) {
        self.overview = overview
        self.keyPoints = keyPoints
        self.actionItems = actionItems
        self.metadata = metadata
    }

    public static func empty(metadata: SummaryMetadata) -> DocumentSummary {
        DocumentSummary(
            overview: "요약할 본문이 없습니다.",
            keyPoints: [],
            actionItems: ["없음"],
            metadata: metadata
        )
    }
}

public enum SummaryStage: String, Equatable, Sendable {
    case fast
    case refined
}

public struct SummaryMetadata: Equatable, Sendable {
    public let sourceByteCount: Int
    public let chunkCount: Int
    public let elapsedMilliseconds: Double
    public let language: SummaryLanguage
    public let stage: SummaryStage

    public init(
        sourceByteCount: Int,
        chunkCount: Int,
        elapsedMilliseconds: Double,
        language: SummaryLanguage,
        stage: SummaryStage = .refined
    ) {
        self.sourceByteCount = sourceByteCount
        self.chunkCount = chunkCount
        self.elapsedMilliseconds = elapsedMilliseconds
        self.language = language
        self.stage = stage
    }
}

public enum SummaryLanguage: String, Equatable, Sendable {
    case korean
    case english
    case mixedKoreanEnglish
    case other

    public var instruction: String {
        switch self {
        case .korean, .mixedKoreanEnglish:
            return "한국어로 요약하세요."
        case .english:
            return "Summarize in English."
        case .other:
            return "Use the dominant language of the source document."
        }
    }
}

public enum SummaryUnavailableReason: String, Equatable, Sendable {
    case frameworkMissing
    case osUnsupported
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unavailable
}

public enum SummaryModelAvailability: Equatable, Sendable {
    case available
    case unavailable(SummaryUnavailableReason)
}

public enum SummaryProgressState: Equatable, Sendable {
    case idle
    case ready
    case unavailable(SummaryUnavailableReason)
    case editorNotReady
    case tooLarge(sourceByteCount: Int, maxSourceBytes: Int)
    case analyzing
    case summarizingChunk(current: Int, total: Int)
    case finalizing
    case complete
    case cancelled
    case failed(SummaryFailureReason)
}

public enum SummaryFailureReason: String, Equatable, Sendable {
    case contextWindowExceeded
    case rateLimited
    case unsupportedLanguageOrLocale
    case malformedResponse
    case unavailable
    case cancelled
    case unknown
}

public enum SummaryGenerationError: Error, Equatable, Sendable {
    case contextWindowExceeded
    case rateLimited
    case unsupportedLanguageOrLocale
    case malformedResponse
    case unavailable(SummaryUnavailableReason)
    case cancelled
    case tooLarge(sourceByteCount: Int, maxSourceBytes: Int)
    case editorNotReady
    case staleRequest
    case unknown

    public var failureReason: SummaryFailureReason {
        switch self {
        case .contextWindowExceeded:
            return .contextWindowExceeded
        case .rateLimited:
            return .rateLimited
        case .unsupportedLanguageOrLocale:
            return .unsupportedLanguageOrLocale
        case .malformedResponse:
            return .malformedResponse
        case .unavailable:
            return .unavailable
        case .cancelled:
            return .cancelled
        case .tooLarge, .editorNotReady, .staleRequest, .unknown:
            return .unknown
        }
    }
}
