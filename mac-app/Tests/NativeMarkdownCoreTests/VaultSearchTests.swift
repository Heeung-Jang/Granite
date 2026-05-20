import Foundation
import Testing
@testable import NativeMarkdownCore

@Test
func vaultSearchFindsFilesByName() throws {
    let vaultURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try write("", to: vaultURL.appendingPathComponent("Home.md"))
    try write("", to: vaultURL.appendingPathComponent("Projects/Home Plan.md"))
    try write("", to: vaultURL.appendingPathComponent("Projects/Other.md"))

    let page = try FileSystemVaultSearchLoader().search(
        at: vaultURL,
        query: "home",
        mode: .fileName,
        page: SearchPageRequest(requestID: 7, offset: 0, limit: 10)
    )

    #expect(page.requestID == 7)
    #expect(page.state == .complete)
    #expect(page.items.map(\.file.relativePath).contains("Home.md"))
    #expect(page.items.map(\.file.relativePath).contains("Projects/Home Plan.md"))
    #expect(!page.items.map(\.file.relativePath).contains("Projects/Other.md"))
}

@Test
func vaultSearchFindsBodyTextWithSnippet() throws {
    let vaultURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try write("Alpha beta gamma native search delta.\n", to: vaultURL.appendingPathComponent("Body.md"))

    let page = try FileSystemVaultSearchLoader().search(
        at: vaultURL,
        query: "native search",
        mode: .body,
        page: SearchPageRequest(requestID: 8, offset: 0, limit: 10)
    )

    #expect(page.state == .complete)
    #expect(page.items.count == 1)
    #expect(page.items[0].file.relativePath == "Body.md")
    #expect(page.items[0].snippet.contains("native search"))
}

@Test
func vaultSearchPaginatesResults() throws {
    let vaultURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try write("", to: vaultURL.appendingPathComponent("One.md"))
    try write("", to: vaultURL.appendingPathComponent("Two.md"))

    let first = try FileSystemVaultSearchLoader().search(
        at: vaultURL,
        query: ".md",
        mode: .fileName,
        page: SearchPageRequest(requestID: 9, offset: 0, limit: 1)
    )
    let second = try FileSystemVaultSearchLoader().search(
        at: vaultURL,
        query: ".md",
        mode: .fileName,
        page: SearchPageRequest(requestID: 10, offset: first.nextOffset ?? 0, limit: 1)
    )

    #expect(first.state == .partial)
    #expect(first.items.count == 1)
    #expect(first.nextOffset == 1)
    #expect(second.state == .complete)
    #expect(second.items.count == 1)
    #expect(second.nextOffset == nil)
}

@Test
func vaultSearchReportsNoMatchesAsCompleteEmptyPage() throws {
    let vaultURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try write("", to: vaultURL.appendingPathComponent("Home.md"))

    let page = try FileSystemVaultSearchLoader().search(
        at: vaultURL,
        query: "missing",
        mode: .fileName,
        page: SearchPageRequest(requestID: 11, offset: 0, limit: 10)
    )

    #expect(page.state == .complete)
    #expect(page.items.isEmpty)
    #expect(page.nextOffset == nil)
}

@Test
func vaultSearchSkipsVaultMetadataDirectories() throws {
    let vaultURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try write("", to: vaultURL.appendingPathComponent(".obsidian/Hidden.md"))
    try write("", to: vaultURL.appendingPathComponent(".git/Hidden.md"))
    try write("", to: vaultURL.appendingPathComponent("Visible.md"))

    let page = try FileSystemVaultSearchLoader().search(
        at: vaultURL,
        query: "Hidden",
        mode: .fileName,
        page: SearchPageRequest(requestID: 12, offset: 0, limit: 10)
    )

    #expect(page.items.isEmpty)
}

@Test
func vaultSearchSkipsObsidianPluginAndSnippetPayloads() throws {
    let vaultURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try write("eval('private-plugin-token')", to: vaultURL.appendingPathComponent(".obsidian/plugins/fake-plugin/main.js"))
    try write(".unsafe { background: url(https://example.com/track) }", to: vaultURL.appendingPathComponent(".obsidian/snippets/unsafe.css"))
    try write("Visible text", to: vaultURL.appendingPathComponent("Visible.md"))

    let pluginPage = try FileSystemVaultSearchLoader().search(
        at: vaultURL,
        query: "private-plugin-token",
        mode: .body,
        page: SearchPageRequest(requestID: 14, offset: 0, limit: 10)
    )
    let snippetPage = try FileSystemVaultSearchLoader().search(
        at: vaultURL,
        query: "https://example.com/track",
        mode: .body,
        page: SearchPageRequest(requestID: 15, offset: 0, limit: 10)
    )

    #expect(pluginPage.items.isEmpty)
    #expect(snippetPage.items.isEmpty)
}

@Test
func vaultSearchRejectsEmptyQuery() throws {
    let vaultURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)

    #expect(throws: VaultSearchError.emptyQuery) {
        try FileSystemVaultSearchLoader().search(
            at: vaultURL,
            query: "  ",
            mode: .body,
            page: SearchPageRequest(requestID: 13, offset: 0, limit: 10)
        )
    }
}

private func write(_ contents: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try contents.write(to: url, atomically: true, encoding: .utf8)
}
