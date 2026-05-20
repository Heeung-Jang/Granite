import Foundation

public struct LivePreviewSourceRange: Equatable, Hashable, Sendable {
    public var location: Int
    public var length: Int

    public init(location: Int, length: Int) {
        self.location = max(0, location)
        self.length = max(0, length)
    }

    public var endLocation: Int {
        location + length
    }

    public var nsRange: NSRange {
        NSRange(location: location, length: length)
    }

    public func intersects(_ other: LivePreviewSourceRange) -> Bool {
        location < other.endLocation && other.location < endLocation
    }

    public func expanded(by utf16Units: Int, limit: Int) -> LivePreviewSourceRange {
        let lower = max(0, location - max(0, utf16Units))
        let upper = min(limit, endLocation + max(0, utf16Units))
        return LivePreviewSourceRange(location: lower, length: max(0, upper - lower))
    }
}

public enum LivePreviewRangeMapper {
    public static func sourceRange(
        for range: Range<String.Index>,
        in source: String
    ) -> LivePreviewSourceRange {
        let nsRange = NSRange(range, in: source)
        return LivePreviewSourceRange(location: nsRange.location, length: nsRange.length)
    }

    public static func stringRange(
        for sourceRange: LivePreviewSourceRange,
        in source: String
    ) -> Range<String.Index>? {
        Range(sourceRange.nsRange, in: source)
    }

    public static func clamped(
        _ sourceRange: LivePreviewSourceRange,
        in source: String
    ) -> LivePreviewSourceRange {
        let length = (source as NSString).length
        let location = min(sourceRange.location, length)
        let maxLength = max(0, length - location)
        return LivePreviewSourceRange(
            location: location,
            length: min(sourceRange.length, maxLength)
        )
    }
}
