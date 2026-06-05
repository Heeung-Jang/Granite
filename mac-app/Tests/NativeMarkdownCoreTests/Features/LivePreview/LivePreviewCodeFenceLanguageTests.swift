import Testing
@testable import NativeMarkdownCore

@Test
func codeFenceLanguageNormalizesSupportedAliases() {
    #expect(LivePreviewCodeFenceLanguage(info: "yaml").highlightMode == .yaml)
    #expect(LivePreviewCodeFenceLanguage(info: "yml").displayName == "YAML")
    #expect(LivePreviewCodeFenceLanguage(info: "rust").highlightMode == .rust)
    #expect(LivePreviewCodeFenceLanguage(info: "rs").displayName == "Rust")
    #expect(LivePreviewCodeFenceLanguage(info: "bash").highlightMode == .bash)
    #expect(LivePreviewCodeFenceLanguage(info: "sh").highlightMode == .bash)
    #expect(LivePreviewCodeFenceLanguage(info: "shell").displayName == "Bash")
    #expect(LivePreviewCodeFenceLanguage(info: "java").displayName == "Java")
    #expect(LivePreviewCodeFenceLanguage(info: "swift").displayName == "Swift")
    #expect(LivePreviewCodeFenceLanguage(info: "json").displayName == "JSON")
    #expect(LivePreviewCodeFenceLanguage(info: "sql").displayName == "SQL")
    #expect(LivePreviewCodeFenceLanguage(info: "javascript").highlightMode == .javascript)
    #expect(LivePreviewCodeFenceLanguage(info: "js").displayName == "JavaScript")
    #expect(LivePreviewCodeFenceLanguage(info: "typescript").highlightMode == .typescript)
    #expect(LivePreviewCodeFenceLanguage(info: "ts").displayName == "TypeScript")
    #expect(LivePreviewCodeFenceLanguage(info: "python").highlightMode == .python)
    #expect(LivePreviewCodeFenceLanguage(info: "py").displayName == "Python")
    #expect(LivePreviewCodeFenceLanguage(info: "html").displayName == "HTML")
    #expect(LivePreviewCodeFenceLanguage(info: "css").displayName == "CSS")
    #expect(LivePreviewCodeFenceLanguage(info: "md").displayName == "Markdown")
}

@Test
func codeFenceLanguageTreatsEmptyAndTextAsPlainWithoutBadge() {
    #expect(LivePreviewCodeFenceLanguage(info: nil).highlightMode == .text)
    #expect(LivePreviewCodeFenceLanguage(info: "   ").displayName == nil)
    #expect(LivePreviewCodeFenceLanguage(info: "text").highlightMode == .text)
    #expect(LivePreviewCodeFenceLanguage(info: "plain").displayName == nil)
}

@Test
func codeFenceLanguageUsesFirstInfoTokenAndCapsUnknownLabels() {
    let rust = LivePreviewCodeFenceLanguage(info: " RUST extra metadata ")
    #expect(rust.highlightMode == .rust)
    #expect(rust.displayName == "Rust")

    let unknown = LivePreviewCodeFenceLanguage(info: "unknown-language-with-a-very-long-label extra")
    #expect(unknown.highlightMode == .unsupported)
    #expect(unknown.displayName?.hasSuffix("…") == true)
    #expect((unknown.displayName?.count ?? 0) <= LivePreviewCodeFenceLanguage.maxDisplayLabelLength)
}
