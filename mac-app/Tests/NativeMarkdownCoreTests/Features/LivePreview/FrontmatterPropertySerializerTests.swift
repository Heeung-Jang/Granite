import Testing
@testable import NativeMarkdownCore

@Test
func frontmatterPropertySerializerSerializesScalarValues() {
    #expect(FrontmatterPropertySerializer.propertyText(key: "status", value: .text("draft")) == "status: draft\n")
    #expect(FrontmatterPropertySerializer.propertyText(key: "count", value: .number("42")) == "count: 42\n")
    #expect(FrontmatterPropertySerializer.propertyText(key: "published", value: .checkbox(true)) == "published: true\n")
    #expect(FrontmatterPropertySerializer.propertyText(key: "created", value: .date("2026-06-04")) == "created: 2026-06-04\n")
    #expect(FrontmatterPropertySerializer.propertyText(key: "seen", value: .dateTime("2026-06-04T10:30:00")) == "seen: 2026-06-04T10:30:00\n")
}

@Test
func frontmatterPropertySerializerSerializesListsAsBlockYaml() {
    #expect(FrontmatterPropertySerializer.propertyText(key: "aliases", value: .list(["Draft", "Home"])) == """
    aliases:
      - Draft
      - Home

    """)
}

@Test
func frontmatterPropertySerializerNormalizesTagsWithoutHashPrefix() {
    #expect(FrontmatterPropertySerializer.propertyText(key: "tags", value: .tags(["#granite", " work "])) == """
    tags:
      - granite
      - work

    """)
}

@Test
func frontmatterPropertySerializerQuotesYamlSensitiveScalars() {
    #expect(FrontmatterPropertySerializer.propertyText(key: "status", value: .text("needs: review")) == "status: \"needs: review\"\n")
}
