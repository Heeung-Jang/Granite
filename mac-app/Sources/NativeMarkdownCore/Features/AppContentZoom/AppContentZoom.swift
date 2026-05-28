import Foundation

public struct AppContentZoom: Equatable, Sendable {
    public static let defaultScale = 1.0
    public static let minimumScale = 0.75
    public static let maximumScale = 1.75
    public static let step = 0.10
    public static let storageKey = "appContentZoomScale"

    public let scale: Double

    public init(rawScale: Double = Self.defaultScale) {
        self.scale = Self.normalized(rawScale)
    }

    public func zoomedIn() -> AppContentZoom {
        AppContentZoom(rawScale: scale + Self.step)
    }

    public func zoomedOut() -> AppContentZoom {
        AppContentZoom(rawScale: scale - Self.step)
    }

    public static var actualSize: AppContentZoom {
        AppContentZoom(rawScale: defaultScale)
    }

    public static func normalized(_ rawScale: Double) -> Double {
        guard rawScale.isFinite else {
            return defaultScale
        }
        let clamped = min(max(rawScale, minimumScale), maximumScale)
        return (clamped * 100).rounded() / 100
    }
}
