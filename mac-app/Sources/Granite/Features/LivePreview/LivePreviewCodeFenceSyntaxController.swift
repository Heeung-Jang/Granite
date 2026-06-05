import AppKit
import Foundation
import NativeMarkdownCore

struct LivePreviewCodeFenceSyntaxSnapshot {
    static let empty = LivePreviewCodeFenceSyntaxSnapshot(tokensByContentRange: [:])

    private let tokensByContentRange: [LivePreviewSourceRange: [LivePreviewCodeFenceToken]]

    init(tokensByContentRange: [LivePreviewSourceRange: [LivePreviewCodeFenceToken]]) {
        self.tokensByContentRange = tokensByContentRange
    }

    func tokens(for contentRange: LivePreviewSourceRange) -> [LivePreviewCodeFenceToken]? {
        tokensByContentRange[contentRange]
    }
}

@MainActor
final class LivePreviewCodeFenceSyntaxController {
    var onUpdate: (() -> Void)?

    private let client: EngineSyntaxHighlighting?
    private let maxCachedBlocks: Int
    private var nextRequestID: UInt64 = 1
    private var cachedTokens: [CacheKey: [LivePreviewCodeFenceToken]] = [:]
    private var lruKeys: [CacheKey] = []
    private var inFlight: Set<CacheKey> = []
    private var cacheGeneration: UInt64 = 0

    init(
        client: EngineSyntaxHighlighting? = try? EngineSyntaxHighlightClient.loadDefault(),
        maxCachedBlocks: Int = 96
    ) {
        self.client = client
        self.maxCachedBlocks = max(8, maxCachedBlocks)
    }

    func invalidate() {
        cacheGeneration &+= 1
        cachedTokens.removeAll(keepingCapacity: false)
        lruKeys.removeAll(keepingCapacity: false)
        inFlight.removeAll(keepingCapacity: false)
    }

    func snapshot(
        in textView: NSTextView,
        requestedRange: NSRange?,
        mode: LivePreviewMode
    ) -> LivePreviewCodeFenceSyntaxSnapshot {
        guard !mode.rendersSourceOnly,
              let client
        else {
            return .empty
        }

        let text = textView.string as NSString
        let visibleRange = LivePreviewTextViewRange.clamped(
            requestedRange ?? LivePreviewTextViewRange.inferredVisibleRange(in: textView),
            documentLength: text.length
        )
        guard visibleRange.length > 0 else {
            return .empty
        }

        let source = textView.string
        let requests = collectRequests(
            source: source,
            visibleRange: LivePreviewSourceRange(location: visibleRange.location, length: visibleRange.length)
        )
        guard !requests.isEmpty else {
            return .empty
        }

        var tokensByRange: [LivePreviewSourceRange: [LivePreviewCodeFenceToken]] = [:]
        for request in requests {
            if let tokens = cachedTokens[request.cacheKey] {
                tokensByRange[request.contentRange] = tokens
                touch(request.cacheKey)
            } else {
                schedule(request, client: client)
            }
        }
        return LivePreviewCodeFenceSyntaxSnapshot(tokensByContentRange: tokensByRange)
    }

    private func collectRequests(
        source: String,
        visibleRange: LivePreviewSourceRange
    ) -> [SyntaxRequest] {
        let parseWindow = LivePreviewVisibleParseWindow.window(
            in: source,
            visibleRange: visibleRange,
            paddingLines: 2,
            maxUTF16Length: max(visibleRange.length + 4_096, 8_192)
        )
        let parsed = LivePreviewParser.parse(source, in: parseWindow)
        var requests: [SyntaxRequest] = []
        for block in parsed.blocks {
            guard case .fencedCode(_, let info, _) = block.kind,
                  let contentRange = LivePreviewCodeFenceContentRange.contentRange(for: block, in: source)
            else {
                continue
            }
            let intersection = contentRange.intersection(visibleRange)
            guard intersection.length > 0,
                  let stringRange = LivePreviewRangeMapper.stringRange(for: contentRange, in: source)
            else {
                continue
            }
            let language = LivePreviewCodeFenceLanguage(info: info)
            guard Self.isTreeSitterBacked(language.highlightMode)
            else {
                continue
            }
            let code = String(source[stringRange])
            let visibleStartUTF16 = UInt32(max(0, intersection.location - contentRange.location))
            let visibleLengthUTF16 = UInt32(max(0, intersection.length))
            let key = CacheKey(
                language: language.highlightMode.rawValue,
                contentRange: contentRange,
                codeHash: Self.fnv1a64(code.utf8),
                visibleStartUTF16: visibleStartUTF16,
                visibleLengthUTF16: visibleLengthUTF16
            )
            requests.append(SyntaxRequest(
                cacheKey: key,
                language: language.highlightMode.rawValue,
                code: code,
                contentRange: contentRange,
                visibleStartUTF16: visibleStartUTF16,
                visibleLengthUTF16: visibleLengthUTF16
            ))
        }
        return requests
    }

    private func schedule(_ request: SyntaxRequest, client: EngineSyntaxHighlighting) {
        guard !inFlight.contains(request.cacheKey) else {
            return
        }
        inFlight.insert(request.cacheKey)
        let requestID = nextRequestID
        let generation = cacheGeneration
        nextRequestID &+= 1

        Task { [weak self, client, request, requestID, generation] in
            do {
                let result = try await client.highlight(
                    requestID: requestID,
                    language: request.language,
                    code: request.code,
                    visibleStartUTF16: request.visibleStartUTF16,
                    visibleLengthUTF16: request.visibleLengthUTF16
                )
                await MainActor.run {
                    self?.store(
                        result: result,
                        for: request,
                        requestID: requestID,
                        generation: generation
                    )
                }
            } catch {
                await MainActor.run {
                    _ = self?.inFlight.remove(request.cacheKey)
                }
            }
        }
    }

    private func store(
        result: EngineSyntaxHighlightResult,
        for request: SyntaxRequest,
        requestID: UInt64,
        generation: UInt64
    ) {
        inFlight.remove(request.cacheKey)
        guard result.requestID == requestID,
              generation == cacheGeneration
        else {
            return
        }
        cachedTokens[request.cacheKey] = result.tokens.map { token in
            LivePreviewCodeFenceToken(
                kind: token.kind,
                sourceRange: LivePreviewSourceRange(
                    location: request.contentRange.location + token.sourceRange.location,
                    length: token.sourceRange.length
                )
            )
        }
        touch(request.cacheKey)
        trimCache()
        onUpdate?()
    }

    private func touch(_ key: CacheKey) {
        lruKeys.removeAll { $0 == key }
        lruKeys.append(key)
    }

    private func trimCache() {
        while lruKeys.count > maxCachedBlocks {
            let key = lruKeys.removeFirst()
            cachedTokens.removeValue(forKey: key)
        }
    }

    private static func fnv1a64(_ bytes: String.UTF8View) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }

    private static func isTreeSitterBacked(_ mode: LivePreviewCodeFenceLanguage.HighlightMode) -> Bool {
        switch mode {
        case .yaml, .json, .java, .swift, .rust, .bash, .javascript, .typescript, .python, .html, .css:
            return true
        case .sql, .markdown, .text, .unsupported:
            return false
        }
    }
}

private struct SyntaxRequest: Sendable {
    let cacheKey: CacheKey
    let language: String
    let code: String
    let contentRange: LivePreviewSourceRange
    let visibleStartUTF16: UInt32
    let visibleLengthUTF16: UInt32
}

private struct CacheKey: Hashable, Sendable {
    let language: String
    let contentRange: LivePreviewSourceRange
    let codeHash: UInt64
    let visibleStartUTF16: UInt32
    let visibleLengthUTF16: UInt32
}

private extension LivePreviewSourceRange {
    func intersection(_ other: LivePreviewSourceRange) -> LivePreviewSourceRange {
        let lower = max(location, other.location)
        let upper = min(endLocation, other.endLocation)
        return LivePreviewSourceRange(location: lower, length: max(0, upper - lower))
    }
}
