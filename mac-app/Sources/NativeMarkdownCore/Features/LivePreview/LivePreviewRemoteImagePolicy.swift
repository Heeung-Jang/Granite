import Foundation

public struct LivePreviewRemoteImagePolicy: Equatable, Sendable {
    public static let storageKey = "livePreview.remoteImagesEnabled"
    public static let defaultValue = LivePreviewRemoteImagePolicy(isEnabled: true)

    public var isEnabled: Bool

    public init(isEnabled: Bool = true) {
        self.isEnabled = isEnabled
    }

    public func allows(_ url: URL) -> Bool {
        guard isEnabled,
              let scheme = url.scheme?.lowercased()
        else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }
}

