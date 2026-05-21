import Foundation
import Testing
@testable import NativeMarkdownCore

@Test
func engineReadConstantsMatchRustLayout() {
    #expect(EngineReadABI.version == 1)
    #expect(EngineReadABI.RowKind.fileTree == 10)
    #expect(EngineReadABI.RowKind.livePreviewMetadata == 19)
    #expect(EngineReadABI.State.indexUnavailable == 5)
    #expect(EngineReadABI.SearchMode.fileName == 1)
    #expect(EngineReadABI.SearchMode.body == 2)
    #expect(EngineReadABI.InspectorPanel.attachments == 5)
    #expect(EngineReadABI.GraphDepth.twoHop == 2)
}

@Test
func engineReadHeaderRejectsShortAndUnsupportedBuffers() {
    #expect(throws: EngineReadDecodeError.bufferTooShort(required: 72, actual: 3)) {
        try EngineReadBufferDecoder.decodeHeader(Data([1, 2, 3]))
    }

    let builder = ReadTestBufferBuilder(rowKind: EngineReadABI.RowKind.fileTree)
    let data = builder.finish(abiVersion: 99, rowStride: 40)
    #expect(throws: EngineReadDecodeError.unsupportedABIVersion(99)) {
        try EngineReadBufferDecoder.decodeHeader(data)
    }
}

@Test
func engineReadStringArenaRejectsInvalidRefsAndUTF8() {
    var invalidRef = ReadTestBufferBuilder(rowKind: EngineReadABI.RowKind.fileTree)
    let badRef = TestStringRef(offset: 9_999, length: 4)
    invalidRef.appendFileTree(relativePath: badRef, displayName: invalidRef.string("Home.md"))
    #expect(throws: EngineReadDecodeError.invalidStringRef) {
        _ = try EngineReadBufferDecoder.decodeFileTree(invalidRef.finish(rowStride: 40))
    }

    var invalidUTF8 = ReadTestBufferBuilder(rowKind: EngineReadABI.RowKind.fileTree)
    let raw = invalidUTF8.rawString([0xff])
    invalidUTF8.appendFileTree(relativePath: raw, displayName: invalidUTF8.string("Home.md"))
    #expect(throws: EngineReadDecodeError.invalidUTF8) {
        _ = try EngineReadBufferDecoder.decodeFileTree(invalidUTF8.finish(rowStride: 40))
    }
}

@Test
func engineReadRowsRejectWrongKindStrideAndTruncation() {
    var wrongKind = ReadTestBufferBuilder(rowKind: EngineReadABI.RowKind.searchHit)
    wrongKind.appendSearch(relativePath: "Home.md", title: "Home", snippet: "body", rank: 1)
    #expect(throws: EngineReadDecodeError.wrongRowKind(
        expected: EngineReadABI.RowKind.fileTree,
        actual: EngineReadABI.RowKind.searchHit
    )) {
        _ = try EngineReadBufferDecoder.decodeFileTree(wrongKind.finish(rowStride: 40))
    }

    var wrongStride = ReadTestBufferBuilder(rowKind: EngineReadABI.RowKind.fileTree)
    wrongStride.appendFileTree(relativePath: wrongStride.string("Home.md"), displayName: wrongStride.string("Home.md"))
    #expect(throws: EngineReadDecodeError.invalidRowStride(expected: 40, actual: 41)) {
        _ = try EngineReadBufferDecoder.decodeFileTree(wrongStride.finish(rowStride: 41))
    }

    var truncated = ReadTestBufferBuilder(rowKind: EngineReadABI.RowKind.fileTree)
    truncated.appendFileTree(relativePath: truncated.string("Home.md"), displayName: truncated.string("Home.md"))
    var data = truncated.finish(rowStride: 40)
    data.removeSubrange(72..<(72 + 40))
    #expect(throws: EngineReadDecodeError.truncatedRows) {
        _ = try EngineReadBufferDecoder.decodeFileTree(data)
    }
}

@Test
func engineReadDecodesFileTreeAndSearchRows() throws {
    var fileTree = ReadTestBufferBuilder(rowKind: EngineReadABI.RowKind.fileTree, state: EngineReadABI.State.partial, nextOffset: 1)
    fileTree.appendFileTree(relativePath: fileTree.string("Folder/Home.md"), displayName: fileTree.string("Home.md"))

    let snapshot = try EngineReadBufferDecoder.decodeFileTree(fileTree.finish(rowStride: 40))
    #expect(snapshot.state == .partial)
    #expect(snapshot.items == [FileTreeItem(relativePath: "Folder/Home.md")])

    var search = ReadTestBufferBuilder(rowKind: EngineReadABI.RowKind.searchHit, requestID: 42, nextOffset: 3)
    search.appendSearch(relativePath: "Home.md", title: "Home", snippet: "matched body", rank: 2.5)

    let page = try EngineReadBufferDecoder.decodeSearch(search.finish(rowStride: 40))
    #expect(page.requestID == 42)
    #expect(page.nextOffset == 3)
    #expect(page.items.first?.title == "Home")
    #expect(page.items.first?.rank == 2.5)
}

@Test
func engineReadDecodesLinkTagPropertyAndAttachmentRows() throws {
    var backlinks = ReadTestBufferBuilder(rowKind: EngineReadABI.RowKind.backlink)
    backlinks.appendLink(
        sourcePath: "Source.md",
        targetPath: "Home.md",
        targetText: "Home",
        alias: "",
        resolution: 1
    )
    #expect(try EngineReadBufferDecoder.decodeBacklinks(backlinks.finish(rowStride: 64)) == [
        BacklinkItem(file: FileTreeItem(relativePath: "Source.md"), snippet: "Home")
    ])

    var outgoing = ReadTestBufferBuilder(rowKind: EngineReadABI.RowKind.outgoingLink)
    outgoing.appendLink(
        sourcePath: "Home.md",
        targetPath: "Target.md",
        targetText: "Target",
        alias: "Alias",
        resolution: 1
    )
    let links = try EngineReadBufferDecoder.decodeOutgoingLinks(outgoing.finish(rowStride: 64))
    #expect(links.first?.label == "Alias")
    #expect(links.first?.state == .resolved(FileTreeItem(relativePath: "Target.md")))

    var tags = ReadTestBufferBuilder(rowKind: EngineReadABI.RowKind.tag)
    tags.appendTag("project/native")
    #expect(try EngineReadBufferDecoder.decodeTags(tags.finish(rowStride: 20)) == ["project/native"])

    var properties = ReadTestBufferBuilder(rowKind: EngineReadABI.RowKind.property)
    properties.appendProperty(key: "flags", value: "swift, rust", valueKind: 3)
    #expect(try EngineReadBufferDecoder.decodeProperties(properties.finish(rowStride: 28)) == [
        PropertyItem(key: "flags", value: "swift, rust")
    ])

    var attachments = ReadTestBufferBuilder(rowKind: EngineReadABI.RowKind.attachment)
    attachments.appendAttachment(rawTarget: "image.png", resolvedPath: "assets/image.png", source: 1, state: 1)
    attachments.appendAttachment(rawTarget: "missing.png", resolvedPath: "", source: 2, state: 2)
    attachments.appendAttachment(rawTarget: "remote.png", resolvedPath: "", source: 3, state: 4)
    attachments.appendAttachment(rawTarget: "bad.png", resolvedPath: "", source: 2, state: 5)
    attachments.appendAttachment(rawTarget: "Other", resolvedPath: "", source: 1, state: 6)
    let decodedAttachments = try EngineReadBufferDecoder.decodeAttachments(attachments.finish(rowStride: 32))
    #expect(decodedAttachments.map(\.state) == [
        .resolved(FileTreeItem(relativePath: "assets/image.png")),
        .missing,
        .remote,
        .rejected(.urlScheme),
        .unsupported
    ])
}

@Test
func engineReadDecodesGraphRows() throws {
    var nodes = ReadTestBufferBuilder(rowKind: EngineReadABI.RowKind.graphNode)
    nodes.appendGraphNode(id: "file:home", filePath: "Home.md", label: "Home.md", kind: 1)
    nodes.appendGraphNode(id: "unresolved:missing", filePath: "", label: "Missing", kind: 3)

    var edges = ReadTestBufferBuilder(rowKind: EngineReadABI.RowKind.graphEdge, state: EngineReadABI.State.partial)
    edges.appendGraphEdge(source: "file:home", target: "unresolved:missing", targetText: "Missing", direction: 1, hop: 1)

    let graph = try EngineReadBufferDecoder.decodeGraph(
        nodes: nodes.finish(rowStride: 28),
        edges: edges.finish(rowStride: 36)
    )
    #expect(graph.centerNodeID == "file:home")
    #expect(graph.state == .partial)
    #expect(graph.nodes.map(\.kind) == [.center, .unresolved])
    #expect(graph.edges.first?.direction == .outgoing)
}

@Test
func engineReadLivePreviewMetadataBuildsMaps() throws {
    let source = "Text [[Target|Alias]]\n![[image.png]]\n"
    var live = ReadTestBufferBuilder(rowKind: EngineReadABI.RowKind.livePreviewMetadata)
    live.appendLivePreview(
        itemKind: 3,
        key: "wikilink",
        value: "Target",
        resolvedPath: "Target.md",
        alias: "Alias",
        state: 1,
        source: 2
    )
    live.appendLivePreview(
        itemKind: 4,
        key: "embed",
        value: "image.png",
        resolvedPath: "assets/image.png",
        alias: "",
        state: 1,
        source: 4
    )

    let metadata = try EngineReadBufferDecoder.decodeLivePreviewMetadata(live.finish(rowStride: 60))
    #expect(metadata.outgoingLinks.first?.state == .resolved(FileTreeItem(relativePath: "Target.md")))
    #expect(metadata.attachments.first?.state == .resolved(FileTreeItem(relativePath: "assets/image.png")))

    let linkSpan = try #require(LivePreviewParser.parse(source).blocks.flatMap(\.inlineSpans).first { $0.kind == .wikiLink })
    #expect(metadata.linkStyleMap(source: source).state(for: linkSpan) == .resolved)

    let block = try #require(LivePreviewParser.parse(source).blocks.first { $0.kind == .embed })
    let previewState = AttachmentPreviewState.blocked(.unsupportedType)
    let previewMap = metadata.embedPreviewMap(
        source: source,
        previewStatesByID: [metadata.attachments[0].id: previewState]
    )
    #expect(previewMap.preview(for: block)?.status == .nonImage)
}

private struct TestStringRef {
    var offset: UInt32
    var length: UInt32
}

private struct ReadTestBufferBuilder {
    var rowKind: UInt32
    var requestID: UInt64
    var generation: UInt64
    var state: UInt32
    var nextOffset: UInt64
    private var rows = Data()
    private var strings = Data()
    private var rowCount: UInt32 = 0

    init(
        rowKind: UInt32,
        requestID: UInt64 = 1,
        generation: UInt64 = 7,
        state: UInt32 = EngineReadABI.State.complete,
        nextOffset: UInt64 = EngineReadABI.noNextOffset
    ) {
        self.rowKind = rowKind
        self.requestID = requestID
        self.generation = generation
        self.state = state
        self.nextOffset = nextOffset
    }

    mutating func string(_ value: String) -> TestStringRef {
        rawString(Array(value.utf8))
    }

    mutating func rawString(_ bytes: [UInt8]) -> TestStringRef {
        let ref = TestStringRef(offset: UInt32(strings.count), length: UInt32(bytes.count))
        strings.append(contentsOf: bytes)
        return ref
    }

    mutating func appendFileTree(relativePath: TestStringRef, displayName: TestStringRef) {
        appendRef(relativePath)
        appendRef(displayName)
        appendUInt32(1)
        appendUInt32(3)
        appendUInt64(12)
        appendInt64(100)
        rowCount += 1
    }

    mutating func appendSearch(relativePath: String, title: String, snippet: String, rank: Double) {
        appendRef(string("file-id"))
        appendRef(string(relativePath))
        appendRef(string(title))
        appendRef(string(snippet))
        appendDouble(rank)
        rowCount += 1
    }

    mutating func appendLink(
        sourcePath: String,
        targetPath: String,
        targetText: String,
        alias: String,
        resolution: UInt32
    ) {
        appendRef(string("source-id"))
        appendRef(string(sourcePath))
        appendRef(string(targetPath.isEmpty ? "" : "target-id"))
        appendRef(string(targetPath))
        appendRef(string(targetText))
        appendRef(string(""))
        appendRef(string(alias))
        appendUInt32(resolution)
        appendUInt32(0)
        rowCount += 1
    }

    mutating func appendTag(_ tag: String) {
        appendRef(string("file-id"))
        appendRef(string(tag))
        appendUInt32(1)
        rowCount += 1
    }

    mutating func appendProperty(key: String, value: String, valueKind: UInt32) {
        appendRef(string("file-id"))
        appendRef(string(key))
        appendRef(string(value))
        appendUInt32(valueKind)
        rowCount += 1
    }

    mutating func appendAttachment(rawTarget: String, resolvedPath: String, source: UInt32, state: UInt32) {
        appendRef(string("file-id"))
        appendRef(string(rawTarget))
        appendRef(string(resolvedPath))
        appendUInt32(source)
        appendUInt32(state)
        rowCount += 1
    }

    mutating func appendGraphNode(id: String, filePath: String, label: String, kind: UInt32) {
        appendRef(string(id))
        appendRef(string(filePath))
        appendRef(string(label))
        appendUInt32(kind)
        rowCount += 1
    }

    mutating func appendGraphEdge(source: String, target: String, targetText: String, direction: UInt32, hop: UInt32) {
        appendRef(string(source))
        appendRef(string(target))
        appendRef(string(targetText))
        appendUInt32(direction)
        appendUInt32(0)
        appendUInt32(hop)
        rowCount += 1
    }

    mutating func appendLivePreview(
        itemKind: UInt32,
        key: String,
        value: String,
        resolvedPath: String,
        alias: String,
        state: UInt32,
        source: UInt32
    ) {
        appendUInt32(itemKind)
        appendRef(string(key))
        appendRef(string(value))
        appendRef(string(resolvedPath.isEmpty ? "" : "file-id"))
        appendRef(string(resolvedPath))
        appendRef(string(""))
        appendRef(string(alias))
        appendUInt32(state)
        appendUInt32(source)
        rowCount += 1
    }

    func finish(abiVersion: UInt32 = EngineReadABI.version, rowStride: UInt32) -> Data {
        var data = Data()
        writeUInt32(abiVersion, to: &data)
        writeUInt32(rowKind, to: &data)
        writeUInt64(requestID, to: &data)
        writeUInt64(generation, to: &data)
        writeUInt32(state, to: &data)
        writeUInt32(rowCount, to: &data)
        writeUInt32(rowStride, to: &data)
        writeUInt32(72, to: &data)
        writeUInt32(UInt32(72 + rows.count), to: &data)
        writeUInt32(UInt32(strings.count), to: &data)
        writeUInt64(nextOffset, to: &data)
        writeRef(TestStringRef(offset: 0, length: 0), to: &data)
        writeRef(TestStringRef(offset: 0, length: 0), to: &data)
        data.append(rows)
        data.append(strings)
        return data
    }

    private mutating func appendRef(_ ref: TestStringRef) {
        writeRef(ref, to: &rows)
    }

    private mutating func appendUInt32(_ value: UInt32) {
        writeUInt32(value, to: &rows)
    }

    private mutating func appendUInt64(_ value: UInt64) {
        writeUInt64(value, to: &rows)
    }

    private mutating func appendInt64(_ value: Int64) {
        writeUInt64(UInt64(bitPattern: value), to: &rows)
    }

    private mutating func appendDouble(_ value: Double) {
        writeUInt64(value.bitPattern, to: &rows)
    }
}

private func writeRef(_ ref: TestStringRef, to data: inout Data) {
    writeUInt32(ref.offset, to: &data)
    writeUInt32(ref.length, to: &data)
}

private func writeUInt32(_ value: UInt32, to data: inout Data) {
    var value = value.littleEndian
    withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
}

private func writeUInt64(_ value: UInt64, to data: inout Data) {
    var value = value.littleEndian
    withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
}
