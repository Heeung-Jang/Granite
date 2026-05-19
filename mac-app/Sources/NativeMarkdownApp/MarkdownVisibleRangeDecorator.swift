import AppKit
import Foundation
import NativeMarkdownCore

struct MarkdownDecorationResult: Codable, Equatable {
    var mode: String
    var reason: String?
    var rangeLength: Int
    var appliedRuns: Int
}

@MainActor
enum MarkdownVisibleRangeDecorator {
    @discardableResult
    static func decorateVisibleRange(
        in textView: NSTextView,
        range requestedRange: NSRange? = nil,
        documentProfile: EditorDocumentProfile? = nil,
        strategy: EditorStrategyDecision = EditorStrategyDecision()
    ) -> MarkdownDecorationResult {
        let profile = documentProfile ?? EditorDocumentProfile(
            byteCount: textView.string.utf8.count,
            longestLineCharacters: 0,
            embedCount: 0
        )
        if case .degradedSource(let reason) = strategy.renderingMode(for: profile) {
            return MarkdownDecorationResult(
                mode: "degraded-source",
                reason: reason.rawValue,
                rangeLength: 0,
                appliedRuns: 0
            )
        }

        let text = textView.string as NSString
        let visibleRange = clamped(requestedRange ?? inferredVisibleRange(in: textView), length: text.length)
        guard visibleRange.length > 0, let storage = textView.textStorage else {
            return MarkdownDecorationResult(
                mode: "decorated-source",
                reason: nil,
                rangeLength: 0,
                appliedRuns: 0
            )
        }

        let selection = textView.selectedRange()
        var appliedRuns = 0
        storage.beginEditing()
        storage.addAttributes(baseAttributes(), range: visibleRange)
        appliedRuns += apply(headingRegex, to: storage, in: visibleRange, attributes: headingAttributes())
        appliedRuns += apply(blockquoteRegex, to: storage, in: visibleRange, attributes: blockquoteAttributes())
        appliedRuns += apply(listRegex, to: storage, in: visibleRange, attributes: listAttributes())
        appliedRuns += apply(strongRegex, to: storage, in: visibleRange, attributes: strongAttributes())
        appliedRuns += apply(emphasisRegex, to: storage, in: visibleRange, attributes: emphasisAttributes())
        appliedRuns += apply(codeSpanRegex, to: storage, in: visibleRange, attributes: codeAttributes())
        appliedRuns += apply(wikiLinkRegex, to: storage, in: visibleRange, attributes: linkAttributes())
        appliedRuns += apply(tagRegex, to: storage, in: visibleRange, attributes: tagAttributes())
        storage.endEditing()
        textView.setSelectedRange(clamped(selection, length: text.length))

        return MarkdownDecorationResult(
            mode: "decorated-source",
            reason: nil,
            rangeLength: visibleRange.length,
            appliedRuns: appliedRuns
        )
    }

    private static func inferredVisibleRange(in textView: NSTextView) -> NSRange {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return NSRange(location: 0, length: (textView.string as NSString).length)
        }

        let glyphRange = layoutManager.glyphRange(
            forBoundingRect: textView.visibleRect,
            in: textContainer
        )
        return layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
    }

    private static func clamped(_ range: NSRange, length: Int) -> NSRange {
        let location = min(range.location, length)
        let maxLength = max(0, length - location)
        return NSRange(location: location, length: min(range.length, maxLength))
    }

    private static func apply(
        _ regex: NSRegularExpression,
        to storage: NSTextStorage,
        in range: NSRange,
        attributes: [NSAttributedString.Key: Any]
    ) -> Int {
        let text = storage.string as NSString
        let matches = regex.matches(in: storage.string, range: range)
        for match in matches {
            let matchRange = NSIntersectionRange(match.range, NSRange(location: 0, length: text.length))
            guard matchRange.length > 0 else {
                continue
            }
            storage.addAttributes(attributes, range: matchRange)
        }
        return matches.count
    }

    private static func baseAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ]
    }

    private static func headingAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: 16, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
    }

    private static func blockquoteAttributes() -> [NSAttributedString.Key: Any] {
        [.foregroundColor: NSColor.secondaryLabelColor]
    }

    private static func listAttributes() -> [NSAttributedString.Key: Any] {
        [.foregroundColor: NSColor.systemOrange]
    }

    private static func strongAttributes() -> [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .bold)]
    }

    private static func emphasisAttributes() -> [NSAttributedString.Key: Any] {
        [.obliqueness: 0.12]
    }

    private static func codeAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.systemBrown
        ]
    }

    private static func linkAttributes() -> [NSAttributedString.Key: Any] {
        [.foregroundColor: NSColor.linkColor]
    }

    private static func tagAttributes() -> [NSAttributedString.Key: Any] {
        [.foregroundColor: NSColor.systemPurple]
    }

    private static let headingRegex = regex("^(#{1,6})\\s.*$")
    private static let blockquoteRegex = regex("^\\s*>.*$")
    private static let listRegex = regex("^\\s*([-*+]|\\d+[.])\\s+")
    private static let strongRegex = regex("\\*\\*[^*]+\\*\\*|__[^_]+__")
    private static let emphasisRegex = regex("(?<!\\*)\\*[^*\\n]+\\*(?!\\*)|_[^_\\n]+_")
    private static let codeSpanRegex = regex("`[^`\\n]+`")
    private static let wikiLinkRegex = regex("!?\\[\\[[^\\]\\n]+\\]\\]")
    private static let tagRegex = regex("(^|\\s)#[\\p{L}\\p{N}_/-]+")

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }
}
