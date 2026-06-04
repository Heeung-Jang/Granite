import Foundation

public enum LivePreviewCodeFenceContentRange {
    public static func contentRange(
        for block: LivePreviewBlockSpan,
        in source: String
    ) -> LivePreviewSourceRange? {
        guard case .fencedCode(_, _, let isClosed) = block.kind,
              let blockRange = LivePreviewRangeMapper.stringRange(for: block.sourceRange, in: source)
        else {
            return nil
        }

        let openingLine = source.lineRange(for: blockRange.lowerBound..<blockRange.lowerBound)
        let lower = openingLine.upperBound
        var upper = blockRange.upperBound

        if isClosed, lower < upper {
            let beforeEnd = source.index(before: upper)
            let closingLine = source.lineRange(for: beforeEnd..<beforeEnd)
            upper = maxIndex(closingLine.lowerBound, lower)
        }

        if upper < lower {
            upper = lower
        }
        return LivePreviewRangeMapper.sourceRange(for: lower..<upper, in: source)
    }

    private static func maxIndex(_ lhs: String.Index, _ rhs: String.Index) -> String.Index {
        lhs < rhs ? rhs : lhs
    }
}
