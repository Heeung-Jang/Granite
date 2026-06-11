import AppKit
import CryptoKit
import ImageIO
import NativeMarkdownCore

@MainActor
struct LivePreviewImageRenderEntry {
    var sourceRange: LivePreviewSourceRange
    var image: NSImage
    var displaySize: CGSize
    var isRemote: Bool
}

@MainActor
struct LivePreviewImageRenderSnapshot {
    static let empty = LivePreviewImageRenderSnapshot(entriesBySourceRange: [:])

    private var entriesBySourceRange: [LivePreviewSourceRange: LivePreviewImageRenderEntry]

    init(entries: [LivePreviewImageRenderEntry]) {
        self.entriesBySourceRange = Dictionary(uniqueKeysWithValues: entries.map { ($0.sourceRange, $0) })
    }

    private init(entriesBySourceRange: [LivePreviewSourceRange: LivePreviewImageRenderEntry]) {
        self.entriesBySourceRange = entriesBySourceRange
    }

    var count: Int {
        entriesBySourceRange.count
    }

    func entry(for sourceRange: LivePreviewSourceRange) -> LivePreviewImageRenderEntry? {
        entriesBySourceRange[sourceRange]
    }

    func entry(intersecting sourceRange: LivePreviewSourceRange) -> LivePreviewImageRenderEntry? {
        entriesBySourceRange.first { $0.key.intersects(sourceRange) }?.value
    }
}

struct LivePreviewImageCacheKey: Hashable {
    enum Source: Hashable {
        case local(path: String, byteSize: Int, modifiedAt: Int64)
        case remote(fingerprint: String)
    }

    var source: Source
    var requestedWidth: Int?
    var requestedHeight: Int?
    var scaleBucket: Int

    static func local(
        info: AttachmentPreviewInfo,
        requestedSize: LivePreviewEmbedSize?,
        scale: Double
    ) -> LivePreviewImageCacheKey {
        LivePreviewImageCacheKey(
            source: .local(
                path: info.file.relativePath,
                byteSize: info.byteSize,
                modifiedAt: modifiedAt(url: info.url)
            ),
            requestedWidth: requestedSize?.width,
            requestedHeight: requestedSize?.height,
            scaleBucket: scaleBucket(scale)
        )
    }

    static func remote(
        url: URL,
        requestedSize: LivePreviewEmbedSize?,
        scale: Double
    ) -> LivePreviewImageCacheKey {
        LivePreviewImageCacheKey(
            source: .remote(fingerprint: fingerprint(url.absoluteString)),
            requestedWidth: requestedSize?.width,
            requestedHeight: requestedSize?.height,
            scaleBucket: scaleBucket(scale)
        )
    }

    var isRemote: Bool {
        if case .remote = source {
            return true
        }
        return false
    }

    private static func modifiedAt(url: URL) -> Int64 {
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return Int64((modified ?? .distantPast).timeIntervalSince1970)
    }

    private static func scaleBucket(_ scale: Double) -> Int {
        Int((scale * 100).rounded())
    }

    private static func fingerprint(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class LivePreviewImageMemoryCache {
    struct CachedImage {
        var image: NSImage
        var displaySize: CGSize
        var cost: Int
        var isRemote: Bool
    }

    private struct StoredImage {
        var image: CachedImage
        var lastAccess: UInt64
    }

    private let totalCostLimit: Int
    private var totalCost = 0
    private var accessCounter: UInt64 = 0
    private var storage: [LivePreviewImageCacheKey: StoredImage] = [:]

    init(totalCostLimit: Int = 128 * 1024 * 1024) {
        self.totalCostLimit = max(1, totalCostLimit)
    }

    func image(for key: LivePreviewImageCacheKey) -> CachedImage? {
        guard var stored = storage[key] else {
            return nil
        }
        accessCounter += 1
        stored.lastAccess = accessCounter
        storage[key] = stored
        return stored.image
    }

    func insert(_ image: CachedImage, for key: LivePreviewImageCacheKey) {
        if let previous = storage[key] {
            totalCost -= previous.image.cost
        }
        accessCounter += 1
        storage[key] = StoredImage(image: image, lastAccess: accessCounter)
        totalCost += image.cost
        evictIfNeeded()
    }

    func clearAll() {
        storage.removeAll()
        totalCost = 0
    }

    func clearRemote() {
        let remoteKeys = storage.keys.filter(\.isRemote)
        for key in remoteKeys {
            if let removed = storage.removeValue(forKey: key) {
                totalCost -= removed.image.cost
            }
        }
        totalCost = max(0, totalCost)
    }

    private func evictIfNeeded() {
        while totalCost > totalCostLimit, let oldestKey = storage.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
            if let removed = storage.removeValue(forKey: oldestKey) {
                totalCost -= removed.image.cost
            }
        }
        totalCost = max(0, totalCost)
    }
}

struct LivePreviewLoadedImage: @unchecked Sendable {
    var image: NSImage
    var displaySize: CGSize
    var cost: Int
}

enum LivePreviewImageLoader {
    static func loadLocal(
        info: AttachmentPreviewInfo,
        requestedSize: LivePreviewEmbedSize?,
        maxWidth: CGFloat,
        scale: Double
    ) async -> LivePreviewLoadedImage? {
        await Task.detached(priority: .utility) {
            let displaySize = LivePreviewImageSizing.displaySize(
                pixelWidth: info.pixelWidth,
                pixelHeight: info.pixelHeight,
                requestedSize: requestedSize,
                maxWidth: Double(maxWidth)
            )
            let pixelWidth = max(1, Int((displaySize.width * scale).rounded(.up)))
            let pixelHeight = max(1, Int((displaySize.height * scale).rounded(.up)))
            guard let image = downsampledImage(url: info.url, maxPixelSize: max(pixelWidth, pixelHeight)) else {
                return nil
            }
            return LivePreviewLoadedImage(
                image: image,
                displaySize: CGSize(width: displaySize.width, height: displaySize.height),
                cost: pixelWidth * pixelHeight * 4
            )
        }.value
    }

    static func loadRemote(
        url: URL,
        requestedSize: LivePreviewEmbedSize?,
        maxWidth: CGFloat,
        scale: Double,
        maxBytes: Int = AttachmentPreviewPolicy.default.maxFileSizeBytes
    ) async -> LivePreviewLoadedImage? {
        guard LivePreviewRemoteImagePolicy(isEnabled: true).allows(url) else {
            return nil
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)

        do {
            let (data, response) = try await session.data(from: url)
            session.finishTasksAndInvalidate()
            guard data.count <= maxBytes,
                  let finalURL = response.url,
                  LivePreviewRemoteImagePolicy(isEnabled: true).allows(finalURL),
                  isImageResponse(response),
                  let dimensions = imageDimensions(data: data)
            else {
                return nil
            }
            return await Task.detached(priority: .utility) {
                let displaySize = LivePreviewImageSizing.displaySize(
                    pixelWidth: dimensions.width,
                    pixelHeight: dimensions.height,
                    requestedSize: requestedSize,
                    maxWidth: Double(maxWidth)
                )
                let pixelWidth = max(1, Int((displaySize.width * scale).rounded(.up)))
                let pixelHeight = max(1, Int((displaySize.height * scale).rounded(.up)))
                guard let image = downsampledImage(data: data, maxPixelSize: max(pixelWidth, pixelHeight)) else {
                    return nil
                }
                return LivePreviewLoadedImage(
                    image: image,
                    displaySize: CGSize(width: displaySize.width, height: displaySize.height),
                    cost: pixelWidth * pixelHeight * 4
                )
            }.value
        } catch {
            session.finishTasksAndInvalidate()
            return nil
        }
    }

    private static func isImageResponse(_ response: URLResponse) -> Bool {
        guard let mimeType = response.mimeType?.lowercased(), !mimeType.isEmpty else {
            return true
        }
        return mimeType.hasPrefix("image/")
    }

    private static func imageDimensions(data: Data) -> (width: Int, height: Int)? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
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

    private static func downsampledImage(url: URL, maxPixelSize: Int) -> NSImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }
        return downsampledImage(source: source, maxPixelSize: maxPixelSize)
    }

    private static func downsampledImage(data: Data, maxPixelSize: Int) -> NSImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        return downsampledImage(source: source, maxPixelSize: maxPixelSize)
    }

    private static func downsampledImage(source: CGImageSource, maxPixelSize: Int) -> NSImage? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize)
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

@MainActor
final class LivePreviewImageController {
    private let cache = LivePreviewImageMemoryCache()
    private var inFlight: [LivePreviewImageCacheKey: Task<Void, Never>] = [:]
    private var lastVaultPath: String?
    private var lastRemotePolicyEnabled = true

    func update(
        textView: MarkdownInteractionTextView,
        embedPreviewMap: LivePreviewEmbedPreviewMap,
        vaultURL: URL?,
        remotePolicy: LivePreviewRemoteImagePolicy,
        livePreviewMode: LivePreviewMode,
        scale: Double,
        onUpdate: @escaping @MainActor () -> Void
    ) {
        guard livePreviewMode == .livePreview else {
            textView.livePreviewImageSnapshot = .empty
            cancelAll()
            return
        }
        let visibleRange = LivePreviewTextViewRange.inferredVisibleRange(in: textView)
        guard visibleRange.length > 0 else {
            textView.livePreviewImageSnapshot = .empty
            return
        }

        clearIfContextChanged(vaultURL: vaultURL, remotePolicy: remotePolicy)

        let containerWidth = textView.textContainer?.containerSize.width ?? textView.bounds.width
        let maxWidth = max(1, containerWidth - textView.textContainerInset.width * 2)
        let previews = embedPreviewMap.previews(intersecting: visibleRange)
        var entries: [LivePreviewImageRenderEntry] = []

        for preview in previews {
            guard let candidate = candidate(
                for: preview,
                remotePolicy: remotePolicy,
                maxWidth: maxWidth,
                scale: scale
            ) else {
                continue
            }
            if let cached = cache.image(for: candidate.key) {
                entries.append(LivePreviewImageRenderEntry(
                    sourceRange: preview.span.sourceRange,
                    image: cached.image,
                    displaySize: cached.displaySize,
                    isRemote: cached.isRemote
                ))
            } else {
                startLoading(candidate, onUpdate: onUpdate)
            }
        }

        textView.livePreviewImageSnapshot = LivePreviewImageRenderSnapshot(entries: entries)
    }

    func cancelAll() {
        for task in inFlight.values {
            task.cancel()
        }
        inFlight.removeAll()
    }

    private struct Candidate {
        var key: LivePreviewImageCacheKey
        var preview: LivePreviewEmbedPreview
        var localInfo: AttachmentPreviewInfo?
        var remoteURL: URL?
        var maxWidth: CGFloat
        var scale: Double
    }

    private func candidate(
        for preview: LivePreviewEmbedPreview,
        remotePolicy: LivePreviewRemoteImagePolicy,
        maxWidth: CGFloat,
        scale: Double
    ) -> Candidate? {
        if case .imageReady = preview.status, let info = preview.previewInfo {
            return Candidate(
                key: .local(info: info, requestedSize: preview.span.requestedSize, scale: scale),
                preview: preview,
                localInfo: info,
                remoteURL: nil,
                maxWidth: maxWidth,
                scale: scale
            )
        }

        guard let url = URL(string: preview.span.rawTarget),
              remotePolicy.allows(url)
        else {
            return nil
        }
        return Candidate(
            key: .remote(url: url, requestedSize: preview.span.requestedSize, scale: scale),
            preview: preview,
            localInfo: nil,
            remoteURL: url,
            maxWidth: maxWidth,
            scale: scale
        )
    }

    private func startLoading(
        _ candidate: Candidate,
        onUpdate: @escaping @MainActor () -> Void
    ) {
        guard inFlight[candidate.key] == nil else {
            return
        }

        let key = candidate.key
        let requestedSize = candidate.preview.span.requestedSize
        let maxWidth = candidate.maxWidth
        let scale = candidate.scale
        let task = Task { [weak self] in
            let loaded: LivePreviewLoadedImage?
            if let info = candidate.localInfo {
                loaded = await LivePreviewImageLoader.loadLocal(
                    info: info,
                    requestedSize: requestedSize,
                    maxWidth: maxWidth,
                    scale: scale
                )
            } else if let url = candidate.remoteURL {
                loaded = await LivePreviewImageLoader.loadRemote(
                    url: url,
                    requestedSize: requestedSize,
                    maxWidth: maxWidth,
                    scale: scale
                )
            } else {
                loaded = nil
            }

            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                guard let self else {
                    return
                }
                self.inFlight[key] = nil
                if let loaded {
                    self.cache.insert(
                        LivePreviewImageMemoryCache.CachedImage(
                            image: loaded.image,
                            displaySize: loaded.displaySize,
                            cost: loaded.cost,
                            isRemote: key.isRemote
                        ),
                        for: key
                    )
                    onUpdate()
                }
            }
        }
        inFlight[key] = task
    }

    private func clearIfContextChanged(vaultURL: URL?, remotePolicy: LivePreviewRemoteImagePolicy) {
        let vaultPath = vaultURL?.standardizedFileURL.path
        if lastVaultPath != vaultPath {
            cache.clearAll()
            cancelAll()
            lastVaultPath = vaultPath
        }
        if lastRemotePolicyEnabled != remotePolicy.isEnabled {
            if !remotePolicy.isEnabled {
                cache.clearRemote()
            }
            lastRemotePolicyEnabled = remotePolicy.isEnabled
        }
    }
}
