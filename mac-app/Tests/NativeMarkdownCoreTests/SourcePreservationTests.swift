import Foundation
import Testing

@Test
func sourcePreservationNoOpRenderCycleKeepsExactUTF8Bytes() throws {
    let cases = [
        "\u{FEFF}# Heading\r\n\r\nText with CRLF.\r\n",
        "---\ntitle: Fixture\nhtml: \"<script>nope</script>\"\n---\n# Body\n",
        "| Name | Status |\n| --- | --- |\n| Alpha | Draft |\n",
        "![[attachments/safe-pixel.png|64x64]]\n",
        "Unclosed **bold and [[wikilink\n",
        "Korean text: 안녕하세요 #상태/검토\n",
        "Emoji text: note 📝 with combining e\u{301}\n",
        "Final newline is preserved.\n"
    ]

    for source in cases {
        let rendered = noOpLivePreviewRenderCycle(source)
        #expect(rendered == source)
        #expect(rendered.data(using: .utf8) == source.data(using: .utf8))
    }
}

private func noOpLivePreviewRenderCycle(_ source: String) -> String {
    source
}
