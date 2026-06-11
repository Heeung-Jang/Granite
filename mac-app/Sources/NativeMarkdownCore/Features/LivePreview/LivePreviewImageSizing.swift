import Foundation

public struct LivePreviewImageDisplaySize: Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = max(1, width)
        self.height = max(1, height)
    }
}

public enum LivePreviewImageSizing {
    public static func displaySize(
        pixelWidth: Int,
        pixelHeight: Int,
        requestedSize: LivePreviewEmbedSize?,
        maxWidth: Double
    ) -> LivePreviewImageDisplaySize {
        let originalWidth = max(1, Double(pixelWidth))
        let originalHeight = max(1, Double(pixelHeight))
        let aspectRatio = originalHeight / originalWidth
        let clampedMaxWidth = max(1, maxWidth)

        if let requestedSize {
            let requestedWidth = min(Double(requestedSize.width), clampedMaxWidth)
            if let requestedHeight = requestedSize.height {
                return LivePreviewImageDisplaySize(
                    width: requestedWidth,
                    height: Double(requestedHeight)
                )
            }
            return LivePreviewImageDisplaySize(
                width: requestedWidth,
                height: requestedWidth * aspectRatio
            )
        }

        let width = min(originalWidth, clampedMaxWidth)
        return LivePreviewImageDisplaySize(width: width, height: width * aspectRatio)
    }
}

