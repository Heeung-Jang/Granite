import Foundation
import ImageIO

public struct AttachmentPreviewPolicy: Equatable, Sendable {
    public static let `default` = AttachmentPreviewPolicy()

    public let maxFileSizeBytes: Int
    public let maxDimensionPixels: Int
    public let maxPixelCount: Int
    public let allowedExtensions: Set<String>

    public init(
        maxFileSizeBytes: Int = 5_000_000,
        maxDimensionPixels: Int = 8_000,
        maxPixelCount: Int = 20_000_000,
        allowedExtensions: Set<String> = ["bmp", "gif", "jpeg", "jpg", "png", "tif", "tiff", "webp"]
    ) {
        self.maxFileSizeBytes = maxFileSizeBytes
        self.maxDimensionPixels = maxDimensionPixels
        self.maxPixelCount = maxPixelCount
        self.allowedExtensions = allowedExtensions
    }
}

public struct AttachmentPreviewInfo: Equatable, Sendable {
    public let file: FileTreeItem
    public let url: URL
    public let byteSize: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
}

public enum AttachmentPreviewBlockReason: Equatable, Sendable {
    case missing
    case unreadable
    case duplicate
    case remote
    case rejected
    case unsupportedResolution
    case unsupportedType
    case outsideVault
    case fileMissing
    case fileTooLarge
    case invalidImage
    case dimensionsTooLarge
}

public enum AttachmentPreviewState: Equatable, Sendable {
    case eligible(AttachmentPreviewInfo)
    case blocked(AttachmentPreviewBlockReason)
}

public struct FileSystemAttachmentPreviewGate: Sendable {
    public init() {}

    public func previewState(
        vaultURL: URL,
        reference: AttachmentReferenceItem,
        policy: AttachmentPreviewPolicy = .default
    ) -> AttachmentPreviewState {
        guard case .resolved(let file) = reference.state else {
            return .blocked(blockReason(for: reference.state))
        }

        guard policy.allowedExtensions.contains((file.relativePath as NSString).pathExtension.lowercased()) else {
            return .blocked(.unsupportedType)
        }

        let rootURL = vaultURL.standardizedFileURL.resolvingSymlinksInPath()
        let fileURL = rootURL
            .appendingPathComponent(file.relativePath, isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        guard isInsideVault(fileURL, rootURL: rootURL) else {
            return .blocked(.outsideVault)
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .blocked(.fileMissing)
        }
        guard FileManager.default.isReadableFile(atPath: fileURL.path) else {
            return .blocked(.unreadable)
        }

        let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard resourceValues?.isRegularFile == true else {
            return .blocked(.unsupportedType)
        }

        let byteSize = resourceValues?.fileSize ?? 0
        guard byteSize <= policy.maxFileSizeBytes else {
            return .blocked(.fileTooLarge)
        }

        guard let dimensions = imageDimensions(fileURL) else {
            return .blocked(.invalidImage)
        }

        guard dimensions.width <= policy.maxDimensionPixels,
              dimensions.height <= policy.maxDimensionPixels,
              dimensions.width * dimensions.height <= policy.maxPixelCount
        else {
            return .blocked(.dimensionsTooLarge)
        }

        return .eligible(
            AttachmentPreviewInfo(
                file: file,
                url: fileURL,
                byteSize: byteSize,
                pixelWidth: dimensions.width,
                pixelHeight: dimensions.height
            )
        )
    }

    private func blockReason(for state: AttachmentResolutionState) -> AttachmentPreviewBlockReason {
        switch state {
        case .resolved:
            .unsupportedResolution
        case .missing:
            .missing
        case .unreadable:
            .unreadable
        case .duplicate:
            .duplicate
        case .remote:
            .remote
        case .rejected:
            .rejected
        case .unsupported:
            .unsupportedResolution
        }
    }

    private func isInsideVault(_ fileURL: URL, rootURL: URL) -> Bool {
        let rootPath = rootURL.path
        let filePath = fileURL.path
        return filePath.hasPrefix("\(rootPath)/")
    }

    private func imageDimensions(_ url: URL) -> (width: Int, height: Int)? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0
        else {
            return nil
        }
        return (width, height)
    }
}
