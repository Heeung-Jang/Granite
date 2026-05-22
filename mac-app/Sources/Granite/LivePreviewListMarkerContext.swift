import Foundation
import NativeMarkdownCore

struct LivePreviewListMarkerContext: Equatable {
    enum Kind: Equatable {
        case unordered
        case ordered
        case task
    }

    var kind: Kind
    var blockRange: NSRange
    var prefixRange: NSRange
    var markerRange: NSRange
    var leadingWhitespaceRange: NSRange?
    var leadingColumn: Int
    var depth: Int
    var clusterID: Int
    var contextIncomplete: Bool
}

struct LivePreviewListMarkerResolution: Equatable {
    var contextsByBlockRange: [LivePreviewSourceRange: LivePreviewListMarkerContext]
    var scannedLineCount: Int
    var scannedUTF16Length: Int
    var contextIncomplete: Bool

    static let empty = LivePreviewListMarkerResolution(
        contextsByBlockRange: [:],
        scannedLineCount: 0,
        scannedUTF16Length: 0,
        contextIncomplete: false
    )
}

enum LivePreviewListMarkerResolver {
    static let maxAncestorContextLines = 200
    static let maxAncestorContextUTF16 = 16 * 1024
    static let depthIndentTolerance = 1

    private static let unorderedPrefixRegex = regex(#"^\s*[-*+]\s"#)
    private static let orderedPrefixRegex = regex(#"^\s*\d+[.)]\s"#)
    private static let taskPrefixRegex = regex(#"^\s*[-*+]\s+\[[ xX]\]\s"#)
    private static let taskCheckboxRegex = regex(#"\[[ xX]\]"#)

    static func resolve(
        source: String,
        blocks: [LivePreviewBlockSpan],
        parseWindow: LivePreviewSourceRange? = nil
    ) -> LivePreviewListMarkerResolution {
        guard !blocks.isEmpty else {
            return .empty
        }

        var contexts: [LivePreviewSourceRange: LivePreviewListMarkerContext] = [:]
        var indentStack: [Int] = []
        var currentClusterID = 0
        var previousBlockWasList = false
        var contextIncomplete = false
        var scannedLineCount = 0
        var scannedUTF16Length = 0

        for block in blocks.sorted(by: { $0.sourceRange.location < $1.sourceRange.location }) {
            scannedLineCount += 1
            scannedUTF16Length += block.sourceRange.length
            guard var context = context(for: block, source: source) else {
                if previousBlockWasList {
                    currentClusterID += 1
                }
                previousBlockWasList = false
                indentStack.removeAll()
                continue
            }

            if indentStack.isEmpty {
                if let parseWindow,
                   parseWindow.location > 0,
                   context.leadingColumn > 0,
                   block.sourceRange.location <= parseWindow.location + parseWindow.length {
                    context.contextIncomplete = true
                    contextIncomplete = true
                }
                indentStack = [context.leadingColumn]
                context.depth = 0
            } else {
                context.depth = depth(for: context.leadingColumn, stack: &indentStack)
            }
            context.clusterID = currentClusterID
            previousBlockWasList = true
            contexts[block.sourceRange] = context
        }

        return LivePreviewListMarkerResolution(
            contextsByBlockRange: contexts,
            scannedLineCount: scannedLineCount,
            scannedUTF16Length: scannedUTF16Length,
            contextIncomplete: contextIncomplete
        )
    }

    static func context(for block: LivePreviewBlockSpan, source: String) -> LivePreviewListMarkerContext? {
        let blockRange = block.sourceRange.nsRange
        let prefix: (kind: LivePreviewListMarkerContext.Kind, range: NSRange, markerRange: NSRange)?
        switch block.kind {
        case .unorderedList:
            prefix = firstMatch(in: source, range: blockRange, regex: unorderedPrefixRegex).map {
                (.unordered, $0, markerBodyRange(in: $0, source: source))
            }
        case .orderedList:
            prefix = firstMatch(in: source, range: blockRange, regex: orderedPrefixRegex).map {
                (.ordered, $0, markerBodyRange(in: $0, source: source))
            }
        case .taskList:
            guard let prefixRange = firstMatch(in: source, range: blockRange, regex: taskPrefixRegex),
                  let checkboxRange = firstMatch(in: source, range: prefixRange, regex: taskCheckboxRegex)
            else {
                return nil
            }
            prefix = (.task, prefixRange, checkboxRange)
        default:
            prefix = nil
        }

        guard let prefix else {
            return nil
        }

        let leadingWhitespaceRange = leadingWhitespaceRange(in: prefix.range, source: source)
        return LivePreviewListMarkerContext(
            kind: prefix.kind,
            blockRange: blockRange,
            prefixRange: prefix.range,
            markerRange: prefix.markerRange,
            leadingWhitespaceRange: leadingWhitespaceRange,
            leadingColumn: leadingColumn(in: prefix.range, source: source),
            depth: 0,
            clusterID: 0,
            contextIncomplete: false
        )
    }

    private static func depth(for column: Int, stack: inout [Int]) -> Int {
        if let matchingIndex = stack.indices.last(where: { abs(stack[$0] - column) <= depthIndentTolerance }) {
            stack.removeSubrange(stack.index(after: matchingIndex)..<stack.endIndex)
            return matchingIndex
        }

        while let last = stack.last, column < last - depthIndentTolerance {
            stack.removeLast()
        }

        if let matchingIndex = stack.indices.last(where: { abs(stack[$0] - column) <= depthIndentTolerance }) {
            stack.removeSubrange(stack.index(after: matchingIndex)..<stack.endIndex)
            return matchingIndex
        }

        if let last = stack.last, column > last + depthIndentTolerance {
            stack.append(column)
            return stack.count - 1
        }

        if stack.isEmpty {
            stack = [column]
            return 0
        }
        stack[stack.count - 1] = column
        return max(0, stack.count - 1)
    }

    private static func leadingWhitespaceRange(in prefixRange: NSRange, source: String) -> NSRange? {
        let text = source as NSString
        var length = 0
        while length < prefixRange.length {
            let char = text.character(at: prefixRange.location + length)
            if char == 32 || char == 9 {
                length += 1
                continue
            }
            break
        }
        return length > 0 ? NSRange(location: prefixRange.location, length: length) : nil
    }

    private static func leadingColumn(in prefixRange: NSRange, source: String) -> Int {
        guard let whitespaceRange = leadingWhitespaceRange(in: prefixRange, source: source) else {
            return 0
        }
        let text = source as NSString
        var column = 0
        for offset in 0..<whitespaceRange.length {
            let char = text.character(at: whitespaceRange.location + offset)
            column += char == 9 ? 2 : 1
        }
        return column
    }

    private static func markerBodyRange(in prefixRange: NSRange, source: String) -> NSRange {
        let text = source as NSString
        var lower = prefixRange.location
        let upper = prefixRange.location + prefixRange.length
        while lower < upper {
            let char = text.character(at: lower)
            if char == 32 || char == 9 {
                lower += 1
                continue
            }
            break
        }
        var markerEnd = lower
        while markerEnd < upper {
            let char = text.character(at: markerEnd)
            if char == 32 || char == 9 || char == 10 || char == 13 {
                break
            }
            markerEnd += 1
        }
        return NSRange(location: lower, length: max(0, markerEnd - lower))
    }

    private static func firstMatch(
        in source: String,
        range: NSRange,
        regex: NSRegularExpression
    ) -> NSRange? {
        regex.firstMatch(in: source, range: range)?.range
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }
}
