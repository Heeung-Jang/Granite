import Foundation
import NativeMarkdownCore
import Testing

@Test
func markdownTaskCheckboxToggleChangesOnlyUncheckedToken() throws {
    let source = "- [ ] Task\n- [x] Done\n"
    let offset = try utf16Offset(of: "[ ]", in: source) + 1
    let edit = try #require(MarkdownTaskCheckboxToggle.edit(in: source, utf16Offset: offset))

    #expect(edit.tokenRange.nsRange == NSRange(location: 2, length: 3))
    #expect(edit.replacement == "[x]")
    #expect(toggledText(source, applying: edit) == "- [x] Task\n- [x] Done\n")
}

@Test
func markdownTaskCheckboxToggleChangesOnlyCheckedToken() throws {
    let source = "- [ ] Task\n- [X] Done\n"
    let offset = try utf16Offset(of: "[X]", in: source) + 1
    let edit = try #require(MarkdownTaskCheckboxToggle.edit(in: source, utf16Offset: offset))

    #expect(edit.replacement == "[ ]")
    #expect(toggledText(source, applying: edit) == "- [ ] Task\n- [ ] Done\n")
}

@Test
func markdownTaskCheckboxToggleIgnoresOffsetsOutsideToken() throws {
    let source = "- [ ] Task\n"

    #expect(MarkdownTaskCheckboxToggle.edit(in: source, utf16Offset: 0) == nil)
    #expect(MarkdownTaskCheckboxToggle.edit(in: source, utf16Offset: try utf16Offset(of: "Task", in: source)) == nil)
}

private func utf16Offset(of marker: String, in source: String) throws -> Int {
    let range = try #require(source.range(of: marker))
    return NSRange(range, in: source).location
}

private func toggledText(_ source: String, applying edit: MarkdownTaskCheckboxEdit) -> String {
    (source as NSString).replacingCharacters(in: edit.tokenRange.nsRange, with: edit.replacement)
}
