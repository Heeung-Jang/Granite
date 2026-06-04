import Foundation
import Testing
@testable import NativeMarkdownCore

@Test
func codeFenceContentRangeExcludesClosedBacktickFenceLines() throws {
    let source = "Before\n```swift\nlet value = 1\n```\nAfter\n"
    let block = try firstFence(in: source)
    let range = try #require(LivePreviewCodeFenceContentRange.contentRange(for: block, in: source))

    #expect(text(in: range, source: source) == "let value = 1\n")
    #expect(!text(in: range, source: source).contains("```"))
}

@Test
func codeFenceContentRangeExcludesClosedTildeFenceLines() throws {
    let source = "~~~yaml\nkey: value\n~~~\n"
    let block = try firstFence(in: source)
    let range = try #require(LivePreviewCodeFenceContentRange.contentRange(for: block, in: source))

    #expect(text(in: range, source: source) == "key: value\n")
}

@Test
func codeFenceContentRangeIncludesUnclosedBodyThroughEOF() throws {
    let source = "```rust\nfn main() {}\n"
    let block = try firstFence(in: source)
    let range = try #require(LivePreviewCodeFenceContentRange.contentRange(for: block, in: source))

    #expect(text(in: range, source: source) == "fn main() {}\n")
}

@Test
func codeFenceContentRangeHandlesEmptyBody() throws {
    let source = "```text\n```\n"
    let block = try firstFence(in: source)
    let range = try #require(LivePreviewCodeFenceContentRange.contentRange(for: block, in: source))

    #expect(range.length == 0)
}

@Test
func codeFenceContentRangeMapsUTF16BodyRanges() throws {
    let source = "```yaml\nmessage: \"안녕하세요 🙂\"\n```\n"
    let block = try firstFence(in: source)
    let range = try #require(LivePreviewCodeFenceContentRange.contentRange(for: block, in: source))

    #expect(text(in: range, source: source) == "message: \"안녕하세요 🙂\"\n")
    #expect(LivePreviewRangeMapper.stringRange(for: range, in: source) != nil)
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
