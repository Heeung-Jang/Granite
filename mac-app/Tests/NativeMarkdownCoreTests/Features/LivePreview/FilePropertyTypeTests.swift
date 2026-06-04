import Testing
@testable import NativeMarkdownCore

@Test
func filePropertyTypeProvidesObsidianDefaults() {
    #expect(FilePropertyType.defaultType(for: "tags") == .tags)
    #expect(FilePropertyType.defaultType(for: "aliases") == .list)
    #expect(FilePropertyType.defaultType(for: "cssclasses") == .list)
    #expect(FilePropertyType.defaultType(for: "status") == nil)
}

@Test
func filePropertyTypeRawIdentifiersAreStable() {
    #expect(FilePropertyType.text.rawValue == "text")
    #expect(FilePropertyType.dateTime.rawValue == "dateTime")
    #expect(FilePropertyType.tags.label == "Tags")
}
