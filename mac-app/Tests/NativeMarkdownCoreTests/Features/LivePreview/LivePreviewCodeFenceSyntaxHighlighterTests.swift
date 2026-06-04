import Foundation
import Testing
@testable import NativeMarkdownCore

@Test
func codeFenceSyntaxHighlighterKeepsTokensInsideCodeBody() throws {
    let source = "```swift\nlet value = \"Granite\"\n```\n"
    let block = try firstFence(in: source)
    let visibleRange = LivePreviewSourceRange(location: 0, length: (source as NSString).length)
    let result = LivePreviewCodeFenceSyntaxHighlighter.highlight(source: source, block: block, visibleRange: visibleRange)
    let bodyRange = try #require(LivePreviewCodeFenceContentRange.contentRange(for: block, in: source))

    #expect(!result.tokens.isEmpty)
    #expect(result.tokens.allSatisfy { bodyRange.intersects($0.sourceRange) })
    #expect(result.tokens.allSatisfy { text(in: $0.sourceRange, source: source) != "```" })
    #expect(result.scannedUTF16Length == bodyRange.length)
}

@Test
func codeFenceSyntaxHighlighterReturnsNoTokensForUnsupportedLanguage() throws {
    let source = "```unknown\nlet value = \"Granite\"\n```\n"
    let block = try firstFence(in: source)
    let visibleRange = LivePreviewSourceRange(location: 0, length: (source as NSString).length)
    let result = LivePreviewCodeFenceSyntaxHighlighter.highlight(source: source, block: block, visibleRange: visibleRange)

    #expect(result.tokens.isEmpty)
}

@Test
func codeFenceSyntaxHighlighterSupportsStarterLanguages() throws {
    try expectTokens("```yaml\nkey: \"value\"\n# comment\n```\n", [.propertyKey, .string, .comment])
    try expectTokens("```json\n{\"name\":\"Granite\",\"count\":3}\n```\n", [.string, .number, .operatorToken])
    try expectTokens("```java\npublic class Example { // comment\nString name = \"Granite\";\n}\n```\n", [.keyword, .comment, .string])
    try expectTokens("```swift\nstruct Example { let name = \"Granite\" }\n```\n", [.keyword, .string])
    try expectTokens("```rust\nfn main() { let value = \"Granite\"; }\n```\n", [.keyword, .string])
    try expectTokens("```bash\nif [ -n \"$HOME\" ]; then echo \"Granite\"; fi\n```\n", [.keyword, .propertyKey, .string])
    try expectTokens("```sql\nselect * from notes where id = 42; -- comment\n```\n", [.keyword, .number, .comment])
}

@Test
func codeFenceSyntaxHighlighterScansOnlyVisibleIntersection() throws {
    let source = "```rust\nlet first = 1;\nlet second = 2;\n```\n"
    let block = try firstFence(in: source)
    let secondRange = try #require(source.range(of: "let second"))
    let visibleRange = LivePreviewRangeMapper.sourceRange(for: secondRange, in: source)
    let result = LivePreviewCodeFenceSyntaxHighlighter.highlight(source: source, block: block, visibleRange: visibleRange)

    #expect(result.scannedUTF16Length == visibleRange.length)
    #expect(result.tokens.allSatisfy { $0.sourceRange.intersects(visibleRange) })
}

private func expectTokens(
    _ source: String,
    _ expectedKinds: Set<LivePreviewCodeFenceToken.Kind>
) throws {
    let block = try firstFence(in: source)
    let visibleRange = LivePreviewSourceRange(location: 0, length: (source as NSString).length)
    let result = LivePreviewCodeFenceSyntaxHighlighter.highlight(source: source, block: block, visibleRange: visibleRange)
    let kinds = Set(result.tokens.map { $0.kind })

    for expectedKind in expectedKinds {
        #expect(kinds.contains(expectedKind))
    }
    #expect(result.tokens.allSatisfy { LivePreviewRangeMapper.stringRange(for: $0.sourceRange, in: source) != nil })
}

private func firstFence(in source: String) throws -> LivePreviewBlockSpan {
    try #require(LivePreviewParser.parse(source).blocks.first {
        if case .fencedCode = $0.kind {
            true
        } else {
            false
        }
    })
}

private func text(in range: LivePreviewSourceRange, source: String) -> String {
    guard let stringRange = LivePreviewRangeMapper.stringRange(for: range, in: source) else {
        return ""
    }
    return String(source[stringRange])
}
