import Foundation

public struct MarkdownTaskCheckboxEdit: Equatable, Sendable {
    public let tokenRange: LivePreviewSourceRange
    public let replacement: String

    public init(tokenRange: LivePreviewSourceRange, replacement: String) {
        self.tokenRange = tokenRange
        self.replacement = replacement
    }
}

public enum MarkdownTaskCheckboxToggle {
    public static func edit(in text: String, utf16Offset: Int) -> MarkdownTaskCheckboxEdit? {
        let nsText = text as NSString
        guard nsText.length > 0, utf16Offset >= 0, utf16Offset < nsText.length else {
            return nil
        }

        let lineRange = nsText.lineRange(for: NSRange(location: utf16Offset, length: 0))
        guard let match = taskMarkerRegex.firstMatch(in: text, range: lineRange) else {
            return nil
        }

        let tokenRange = match.range(at: 2)
        guard tokenRange.contains(utf16Offset) else {
            return nil
        }

        let token = nsText.substring(with: tokenRange).lowercased()
        let replacement = token == "[x]" ? "[ ]" : "[x]"
        return MarkdownTaskCheckboxEdit(
            tokenRange: LivePreviewSourceRange(location: tokenRange.location, length: tokenRange.length),
            replacement: replacement
        )
    }

    private static let taskMarkerRegex = try! NSRegularExpression(
        pattern: #"^(\s*[-*+]\s+)(\[[ xX]\])"#,
        options: [.anchorsMatchLines]
    )
}

private extension NSRange {
    func contains(_ offset: Int) -> Bool {
        offset >= location && offset < location + length
    }
}
