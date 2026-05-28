public enum LivePreviewMode: Equatable, Sendable {
    case livePreview
    case source
    case fallbackSource(reason: EditorDegradationReason)

    public var displayName: String {
        switch self {
        case .livePreview:
            return "Live Preview"
        case .source:
            return "Source"
        case .fallbackSource:
            return "Source"
        }
    }

    public var statusText: String? {
        switch self {
        case .livePreview:
            return nil
        case .source:
            return "Source mode"
        case .fallbackSource(let reason):
            return "Live Preview fallback: \(reason.displayText)"
        }
    }

    public var rendersSourceOnly: Bool {
        switch self {
        case .livePreview:
            return false
        case .source, .fallbackSource:
            return true
        }
    }
}

public struct LivePreviewFallbackController: Equatable, Sendable {
    public private(set) var mode: LivePreviewMode
    public private(set) var consecutiveTransientBreaches: Int
    public var requiredConsecutiveTransientBreaches: Int

    public init(
        mode: LivePreviewMode = .livePreview,
        consecutiveTransientBreaches: Int = 0,
        requiredConsecutiveTransientBreaches: Int = 2
    ) {
        self.mode = mode
        self.consecutiveTransientBreaches = consecutiveTransientBreaches
        self.requiredConsecutiveTransientBreaches = max(1, requiredConsecutiveTransientBreaches)
    }

    @discardableResult
    public mutating func observe(_ renderingMode: EditorRenderingMode) -> LivePreviewMode {
        switch renderingMode {
        case .decoratedSource:
            consecutiveTransientBreaches = 0
            return mode
        case .degradedSource(let reason):
            if reason.isTransient {
                consecutiveTransientBreaches += 1
                guard consecutiveTransientBreaches >= requiredConsecutiveTransientBreaches else {
                    return mode
                }
            } else {
                consecutiveTransientBreaches = 0
            }
            mode = .fallbackSource(reason: reason)
            return mode
        }
    }

    @discardableResult
    public mutating func selectSourceMode() -> LivePreviewMode {
        consecutiveTransientBreaches = 0
        mode = .source
        return mode
    }

    @discardableResult
    public mutating func retryLivePreview() -> LivePreviewMode {
        consecutiveTransientBreaches = 0
        mode = .livePreview
        return mode
    }

    @discardableResult
    public mutating func reopenInLivePreview() -> LivePreviewMode {
        retryLivePreview()
    }
}
