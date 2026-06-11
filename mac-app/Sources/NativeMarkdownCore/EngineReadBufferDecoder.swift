import Foundation

public enum EngineReadABI {
    public static let version: UInt32 = 1
    public static let noNextOffset = UInt64.max

    public enum RowKind {
        public static let openStatus: UInt32 = 1
        public static let fileTree: UInt32 = 10
        public static let searchHit: UInt32 = 11
        public static let backlink: UInt32 = 12
        public static let outgoingLink: UInt32 = 13
        public static let tag: UInt32 = 14
        public static let property: UInt32 = 15
        public static let attachment: UInt32 = 16
        public static let graphNode: UInt32 = 17
        public static let graphEdge: UInt32 = 18
        public static let livePreviewMetadata: UInt32 = 19
        public static let syntaxToken: UInt32 = 20
        public static let indexFreshness: UInt32 = 21
    }

    public enum State {
        public static let complete: UInt32 = 0
        public static let partial: UInt32 = 1
        public static let stale: UInt32 = 2
        public static let cancelled: UInt32 = 3
        public static let error: UInt32 = 4
        public static let indexUnavailable: UInt32 = 5
    }

    public enum SearchMode {
        public static let fileName: UInt32 = 1
        public static let body: UInt32 = 2
    }

    public enum InspectorPanel {
        public static let backlinks: UInt32 = 1
        public static let outgoing: UInt32 = 2
        public static let tags: UInt32 = 3
        public static let properties: UInt32 = 4
        public static let attachments: UInt32 = 5
    }

    public enum GraphDepth {
        public static let oneHop: UInt32 = 1
        public static let twoHop: UInt32 = 2
    }
}

public enum EngineReadDecodeError: Error, Equatable, Sendable {
    case bufferTooShort(required: Int, actual: Int)
    case unsupportedABIVersion(UInt32)
    case wrongRowKind(expected: UInt32, actual: UInt32)
    case invalidRowStride(expected: UInt32, actual: UInt32)
    case truncatedRows
    case invalidStringRef
    case invalidUTF8
    case unknownState(UInt32)
    case unknownGraphNodeKind(UInt32)
    case unknownGraphEdgeDirection(UInt32)
    case unknownSyntaxTokenKind(UInt32)
}

public struct EngineReadStringRef: Equatable, Sendable {
    public let offset: UInt32
    public let length: UInt32
}

public struct EngineReadResultHeader: Equatable, Sendable {
    public let abiVersion: UInt32
    public let rowKind: UInt32
    public let requestID: UInt64
    public let generation: UInt64
    public let state: UInt32
    public let rowCount: UInt32
    public let rowStride: UInt32
    public let rowsOffset: UInt32
    public let stringArenaOffset: UInt32
    public let stringArenaLength: UInt32
    public let nextOffset: UInt64
    public let errorCode: EngineReadStringRef
    public let errorMessage: EngineReadStringRef
}

public struct EngineReadErrorPayload: Equatable, Sendable {
    public let code: String
    public let message: String
    public let state: UInt32

    public init(code: String, message: String, state: UInt32) {
        self.code = code
        self.message = message
        self.state = state
    }
}

public struct EngineLivePreviewMetadata: Equatable, Sendable {
    public let outgoingLinks: [OutgoingLinkItem]
    public let attachments: [AttachmentReferenceItem]

    public init(outgoingLinks: [OutgoingLinkItem], attachments: [AttachmentReferenceItem]) {
        self.outgoingLinks = outgoingLinks
        self.attachments = attachments
    }

    public func linkStyleMap(source: String) -> LivePreviewLinkStyleMap {
        LivePreviewLinkStyleMap(source: source, outgoingLinks: outgoingLinks)
    }

    public func embedPreviewMap(
        source: String,
        previewStatesByID: [String: AttachmentPreviewState]
    ) -> LivePreviewEmbedPreviewMap {
        LivePreviewEmbedPreviewMap(
            source: source,
            references: attachments,
            previewStatesByID: previewStatesByID
        )
    }
}

public struct EngineSyntaxHighlightResult: Equatable, Sendable {
    public let requestID: UInt64
    public let tokens: [LivePreviewCodeFenceToken]

    public init(requestID: UInt64, tokens: [LivePreviewCodeFenceToken]) {
        self.requestID = requestID
        self.tokens = tokens
    }
}

public struct EngineIndexFreshnessReport: Equatable, Sendable {
    public let stale: Bool
    public let unchanged: UInt64
    public let created: UInt64
    public let modified: UInt64
    public let deleted: UInt64
    public let incomplete: UInt64
    public let currentMarkdownFiles: UInt64
    public let indexedMarkdownFiles: UInt64
    public let currentRowsScanned: UInt64
    public let storedRowsRead: UInt64
    public let scanMicros: UInt64
    public let sqliteReadMicros: UInt64
    public let compareMicros: UInt64
    public let elapsedMicros: UInt64
    public let rebuildScheduled: Bool

    public init(
        stale: Bool,
        unchanged: UInt64,
        created: UInt64,
        modified: UInt64,
        deleted: UInt64,
        incomplete: UInt64,
        currentMarkdownFiles: UInt64,
        indexedMarkdownFiles: UInt64,
        currentRowsScanned: UInt64,
        storedRowsRead: UInt64,
        scanMicros: UInt64,
        sqliteReadMicros: UInt64,
        compareMicros: UInt64,
        elapsedMicros: UInt64,
        rebuildScheduled: Bool
    ) {
        self.stale = stale
        self.unchanged = unchanged
        self.created = created
        self.modified = modified
        self.deleted = deleted
        self.incomplete = incomplete
        self.currentMarkdownFiles = currentMarkdownFiles
        self.indexedMarkdownFiles = indexedMarkdownFiles
        self.currentRowsScanned = currentRowsScanned
        self.storedRowsRead = storedRowsRead
        self.scanMicros = scanMicros
        self.sqliteReadMicros = sqliteReadMicros
        self.compareMicros = compareMicros
        self.elapsedMicros = elapsedMicros
        self.rebuildScheduled = rebuildScheduled
    }
}

public enum EngineReadBufferDecoder {
    public static func decodeHeader(_ data: Data) throws -> EngineReadResultHeader {
        try data.withUnsafeBytes { try decodeHeader($0) }
    }

    public static func decodeHeader(_ buffer: UnsafeRawBufferPointer) throws -> EngineReadResultHeader {
        try EngineReadBinaryDecoder(buffer: buffer).decodeHeader()
    }

    public static func decodeErrorPayload(_ data: Data) throws -> EngineReadErrorPayload? {
        try data.withUnsafeBytes { try decodeErrorPayload($0) }
    }

    public static func decodeErrorPayload(_ buffer: UnsafeRawBufferPointer) throws -> EngineReadErrorPayload? {
        try EngineReadBinaryDecoder(buffer: buffer).decodeErrorPayload()
    }

    public static func decodeFileTree(_ data: Data) throws -> FileTreeSnapshot {
        try data.withUnsafeBytes { try decodeFileTree($0) }
    }

    public static func decodeFileTree(_ buffer: UnsafeRawBufferPointer) throws -> FileTreeSnapshot {
        try EngineReadBinaryDecoder(buffer: buffer).decodeFileTree()
    }

    public static func decodeSearch(_ data: Data) throws -> SearchPage {
        try data.withUnsafeBytes { try decodeSearch($0) }
    }

    public static func decodeSearch(_ buffer: UnsafeRawBufferPointer) throws -> SearchPage {
        try EngineReadBinaryDecoder(buffer: buffer).decodeSearch()
    }

    public static func decodeBacklinks(_ data: Data) throws -> [BacklinkItem] {
        try data.withUnsafeBytes { try decodeBacklinks($0) }
    }

    public static func decodeBacklinks(_ buffer: UnsafeRawBufferPointer) throws -> [BacklinkItem] {
        try EngineReadBinaryDecoder(buffer: buffer).decodeBacklinks()
    }

    public static func decodeOutgoingLinks(_ data: Data) throws -> [OutgoingLinkItem] {
        try data.withUnsafeBytes { try decodeOutgoingLinks($0) }
    }

    public static func decodeOutgoingLinks(_ buffer: UnsafeRawBufferPointer) throws -> [OutgoingLinkItem] {
        try EngineReadBinaryDecoder(buffer: buffer).decodeOutgoingLinks()
    }

    public static func decodeTags(_ data: Data) throws -> [String] {
        try data.withUnsafeBytes { try decodeTags($0) }
    }

    public static func decodeTags(_ buffer: UnsafeRawBufferPointer) throws -> [String] {
        try EngineReadBinaryDecoder(buffer: buffer).decodeTags()
    }

    public static func decodeProperties(_ data: Data) throws -> [PropertyItem] {
        try data.withUnsafeBytes { try decodeProperties($0) }
    }

    public static func decodeProperties(_ buffer: UnsafeRawBufferPointer) throws -> [PropertyItem] {
        try EngineReadBinaryDecoder(buffer: buffer).decodeProperties()
    }

    public static func decodeAttachments(_ data: Data) throws -> [AttachmentReferenceItem] {
        try data.withUnsafeBytes { try decodeAttachments($0) }
    }

    public static func decodeAttachments(_ buffer: UnsafeRawBufferPointer) throws -> [AttachmentReferenceItem] {
        try EngineReadBinaryDecoder(buffer: buffer).decodeAttachments()
    }

    public static func decodeGraph(nodes: Data, edges: Data) throws -> LocalGraphSnapshot {
        try nodes.withUnsafeBytes { nodeBytes in
            try edges.withUnsafeBytes { edgeBytes in
                try decodeGraph(nodes: nodeBytes, edges: edgeBytes)
            }
        }
    }

    public static func decodeGraph(
        nodes: UnsafeRawBufferPointer,
        edges: UnsafeRawBufferPointer
    ) throws -> LocalGraphSnapshot {
        let nodeDecoder = EngineReadBinaryDecoder(buffer: nodes)
        let edgeDecoder = EngineReadBinaryDecoder(buffer: edges)
        return try nodeDecoder.decodeGraph(edgeDecoder: edgeDecoder)
    }

    public static func decodeLivePreviewMetadata(_ data: Data) throws -> EngineLivePreviewMetadata {
        try data.withUnsafeBytes { try decodeLivePreviewMetadata($0) }
    }

    public static func decodeLivePreviewMetadata(
        _ buffer: UnsafeRawBufferPointer
    ) throws -> EngineLivePreviewMetadata {
        try EngineReadBinaryDecoder(buffer: buffer).decodeLivePreviewMetadata()
    }

    public static func decodeSyntaxHighlight(_ data: Data) throws -> EngineSyntaxHighlightResult {
        try data.withUnsafeBytes { try decodeSyntaxHighlight($0) }
    }

    public static func decodeSyntaxHighlight(
        _ buffer: UnsafeRawBufferPointer
    ) throws -> EngineSyntaxHighlightResult {
        try EngineReadBinaryDecoder(buffer: buffer).decodeSyntaxHighlight()
    }

    public static func decodeIndexFreshness(_ data: Data) throws -> EngineIndexFreshnessReport {
        try data.withUnsafeBytes { try decodeIndexFreshness($0) }
    }

    public static func decodeIndexFreshness(
        _ buffer: UnsafeRawBufferPointer
    ) throws -> EngineIndexFreshnessReport {
        try EngineReadBinaryDecoder(buffer: buffer).decodeIndexFreshness()
    }
}

private struct EngineReadBinaryDecoder {
    let buffer: UnsafeRawBufferPointer

    func decodeHeader() throws -> EngineReadResultHeader {
        try require(72)
        let header = EngineReadResultHeader(
            abiVersion: try uint32(at: 0),
            rowKind: try uint32(at: 4),
            requestID: try uint64(at: 8),
            generation: try uint64(at: 16),
            state: try uint32(at: 24),
            rowCount: try uint32(at: 28),
            rowStride: try uint32(at: 32),
            rowsOffset: try uint32(at: 36),
            stringArenaOffset: try uint32(at: 40),
            stringArenaLength: try uint32(at: 44),
            nextOffset: try uint64(at: 48),
            errorCode: try stringRef(at: 56),
            errorMessage: try stringRef(at: 64)
        )
        guard header.abiVersion == EngineReadABI.version else {
            throw EngineReadDecodeError.unsupportedABIVersion(header.abiVersion)
        }
        return header
    }

    func decodeErrorPayload() throws -> EngineReadErrorPayload? {
        let header = try decodeHeader()
        guard header.state == EngineReadABI.State.error ||
            header.state == EngineReadABI.State.indexUnavailable
        else {
            return nil
        }
        return EngineReadErrorPayload(
            code: try string(header.errorCode, header: header),
            message: try string(header.errorMessage, header: header),
            state: header.state
        )
    }

    func decodeFileTree() throws -> FileTreeSnapshot {
        let header = try validatedHeader(rowKind: EngineReadABI.RowKind.fileTree, rowSize: 40)
        let items = try rows(header: header, rowSize: 40).map { offset in
            FileTreeItem(relativePath: try string(try stringRef(at: offset), header: header))
        }
        return FileTreeSnapshot(items: items, state: try fileTreeState(header.state))
    }

    func decodeSearch() throws -> SearchPage {
        let header = try validatedHeader(rowKind: EngineReadABI.RowKind.searchHit, rowSize: 40)
        let items = try rows(header: header, rowSize: 40).map { offset in
            SearchHitItem(
                file: FileTreeItem(relativePath: try string(try stringRef(at: offset + 8), header: header)),
                title: try string(try stringRef(at: offset + 16), header: header),
                snippet: try string(try stringRef(at: offset + 24), header: header),
                rank: try double(at: offset + 32)
            )
        }
        return SearchPage(
            requestID: header.requestID,
            items: items,
            nextOffset: try nextOffset(header.nextOffset),
            state: try searchState(header.state)
        )
    }

    func decodeBacklinks() throws -> [BacklinkItem] {
        let header = try validatedHeader(rowKind: EngineReadABI.RowKind.backlink, rowSize: 64)
        return try rows(header: header, rowSize: 64).map { offset in
            let path = try string(try stringRef(at: offset + 8), header: header)
            let targetText = try string(try stringRef(at: offset + 32), header: header)
            return BacklinkItem(file: FileTreeItem(relativePath: path), snippet: targetText)
        }
    }

    func decodeOutgoingLinks() throws -> [OutgoingLinkItem] {
        let header = try validatedHeader(rowKind: EngineReadABI.RowKind.outgoingLink, rowSize: 64)
        return try rows(header: header, rowSize: 64).enumerated().map { index, offset in
            let targetPath = try string(try stringRef(at: offset + 24), header: header)
            let targetText = try string(try stringRef(at: offset + 32), header: header)
            let heading = try optionalString(try stringRef(at: offset + 40), header: header)
            let alias = try optionalString(try stringRef(at: offset + 48), header: header)
            let resolution = try uint32(at: offset + 56)
            let state: LinkResolutionState = resolution == 1 && !targetPath.isEmpty
                ? .resolved(FileTreeItem(relativePath: targetPath))
                : .missing
            return OutgoingLinkItem(
                id: "\(index)-\(targetText)",
                label: alias ?? targetText,
                target: targetPath.isEmpty ? targetText : targetPath,
                heading: heading,
                state: state
            )
        }
    }

    func decodeTags() throws -> [String] {
        let header = try validatedHeader(rowKind: EngineReadABI.RowKind.tag, rowSize: 20)
        return try rows(header: header, rowSize: 20).map { offset in
            try string(try stringRef(at: offset + 8), header: header)
        }
    }

    func decodeProperties() throws -> [PropertyItem] {
        let header = try validatedHeader(rowKind: EngineReadABI.RowKind.property, rowSize: 28)
        return try rows(header: header, rowSize: 28).map { offset in
            PropertyItem(
                key: try string(try stringRef(at: offset + 8), header: header),
                value: try string(try stringRef(at: offset + 16), header: header)
            )
        }
    }

    func decodeAttachments() throws -> [AttachmentReferenceItem] {
        let header = try validatedHeader(rowKind: EngineReadABI.RowKind.attachment, rowSize: 32)
        return try rows(header: header, rowSize: 32).enumerated().map { index, offset in
            let rawTarget = try string(try stringRef(at: offset + 8), header: header)
            let resolvedPath = try optionalString(try stringRef(at: offset + 16), header: header)
            let source = try attachmentSource(try uint32(at: offset + 24))
            let state = try attachmentState(try uint32(at: offset + 28), resolvedPath: resolvedPath)
            return AttachmentReferenceItem(
                id: "\(index)-\(source.rawValue)-\(rawTarget)",
                source: source,
                rawTarget: rawTarget,
                state: state
            )
        }
    }

    func decodeGraph(edgeDecoder: EngineReadBinaryDecoder) throws -> LocalGraphSnapshot {
        let nodeHeader = try validatedHeader(rowKind: EngineReadABI.RowKind.graphNode, rowSize: 28)
        let edgeHeader = try edgeDecoder.validatedHeader(rowKind: EngineReadABI.RowKind.graphEdge, rowSize: 36)
        let nodes = try rows(header: nodeHeader, rowSize: 28).map { offset in
            let nodeID = try string(try stringRef(at: offset), header: nodeHeader)
            let filePath = try optionalString(try stringRef(at: offset + 8), header: nodeHeader)
            let label = try string(try stringRef(at: offset + 16), header: nodeHeader)
            return LocalGraphNode(
                id: nodeID,
                file: filePath.map(FileTreeItem.init(relativePath:)),
                label: label,
                kind: try graphNodeKind(try uint32(at: offset + 24))
            )
        }
        let edges = try edgeDecoder.rows(header: edgeHeader, rowSize: 36).enumerated().map { index, offset in
            let source = try edgeDecoder.string(try edgeDecoder.stringRef(at: offset), header: edgeHeader)
            let target = try edgeDecoder.string(try edgeDecoder.stringRef(at: offset + 8), header: edgeHeader)
            let targetText = try edgeDecoder.string(try edgeDecoder.stringRef(at: offset + 16), header: edgeHeader)
            return LocalGraphEdge(
                id: "\(source)->\(target)-\(index)",
                sourceNodeID: source,
                targetNodeID: target,
                targetText: targetText,
                direction: try edgeDecoder.graphEdgeDirection(try edgeDecoder.uint32(at: offset + 24)),
                hop: Int(try edgeDecoder.uint32(at: offset + 32))
            )
        }
        let centerNodeID = nodes.first { $0.kind == .center }?.id ?? nodes.first?.id ?? ""
        return LocalGraphSnapshot(
            centerNodeID: centerNodeID,
            nodes: nodes,
            edges: edges,
            state: try searchState(max(nodeHeader.state, edgeHeader.state))
        )
    }

    func decodeLivePreviewMetadata() throws -> EngineLivePreviewMetadata {
        let header = try validatedHeader(rowKind: EngineReadABI.RowKind.livePreviewMetadata, rowSize: 60)
        var outgoing: [OutgoingLinkItem] = []
        var attachments: [AttachmentReferenceItem] = []
        for (index, offset) in try rows(header: header, rowSize: 60).enumerated() {
            let itemKind = try uint32(at: offset)
            let value = try string(try stringRef(at: offset + 12), header: header)
            let resolvedPath = try optionalString(try stringRef(at: offset + 28), header: header)
            let heading = try optionalString(try stringRef(at: offset + 36), header: header)
            let alias = try optionalString(try stringRef(at: offset + 44), header: header)
            let state = try uint32(at: offset + 52)
            let source = try uint32(at: offset + 56)
            switch itemKind {
            case 3:
                outgoing.append(OutgoingLinkItem(
                    id: "\(index)-\(value)",
                    label: alias ?? value,
                    target: resolvedPath ?? value,
                    heading: heading,
                    state: liveLinkState(state, resolvedPath: resolvedPath)
                ))
            case 4:
                let attachmentSource = try liveAttachmentSource(source)
                attachments.append(AttachmentReferenceItem(
                    id: "\(index)-\(attachmentSource.rawValue)-\(value)",
                    source: attachmentSource,
                    rawTarget: value,
                    state: try attachmentState(state, resolvedPath: resolvedPath)
                ))
            default:
                continue
            }
        }
        return EngineLivePreviewMetadata(outgoingLinks: outgoing, attachments: attachments)
    }

    func decodeSyntaxHighlight() throws -> EngineSyntaxHighlightResult {
        let header = try validatedHeader(rowKind: EngineReadABI.RowKind.syntaxToken, rowSize: 12)
        let tokens = try rows(header: header, rowSize: 12).map { offset in
            LivePreviewCodeFenceToken(
                kind: try syntaxTokenKind(try uint32(at: offset)),
                sourceRange: LivePreviewSourceRange(
                    location: Int(try uint32(at: offset + 4)),
                    length: Int(try uint32(at: offset + 8))
                )
            )
        }
        return EngineSyntaxHighlightResult(requestID: header.requestID, tokens: tokens)
    }

    func decodeIndexFreshness() throws -> EngineIndexFreshnessReport {
        let header = try validatedHeader(rowKind: EngineReadABI.RowKind.indexFreshness, rowSize: 120)
        guard let offset = try rows(header: header, rowSize: 120).first else {
            throw EngineReadDecodeError.bufferTooShort(required: 120, actual: 0)
        }
        return EngineIndexFreshnessReport(
            stale: try uint32(at: offset) != 0,
            unchanged: try uint64(at: offset + 8),
            created: try uint64(at: offset + 16),
            modified: try uint64(at: offset + 24),
            deleted: try uint64(at: offset + 32),
            incomplete: try uint64(at: offset + 40),
            currentMarkdownFiles: try uint64(at: offset + 48),
            indexedMarkdownFiles: try uint64(at: offset + 56),
            currentRowsScanned: try uint64(at: offset + 64),
            storedRowsRead: try uint64(at: offset + 72),
            scanMicros: try uint64(at: offset + 80),
            sqliteReadMicros: try uint64(at: offset + 88),
            compareMicros: try uint64(at: offset + 96),
            elapsedMicros: try uint64(at: offset + 104),
            rebuildScheduled: try uint32(at: offset + 112) != 0
        )
    }

    private func validatedHeader(rowKind: UInt32, rowSize: UInt32) throws -> EngineReadResultHeader {
        let header = try decodeHeader()
        guard header.rowKind == rowKind else {
            throw EngineReadDecodeError.wrongRowKind(expected: rowKind, actual: header.rowKind)
        }
        if header.rowCount > 0, header.rowStride != rowSize {
            throw EngineReadDecodeError.invalidRowStride(expected: rowSize, actual: header.rowStride)
        }
        let rowsEnd = Int(header.rowsOffset) + Int(header.rowCount) * Int(header.rowStride)
        guard rowsEnd <= buffer.count else {
            throw EngineReadDecodeError.truncatedRows
        }
        return header
    }

    private func rows(header: EngineReadResultHeader, rowSize: Int) throws -> [Int] {
        let start = Int(header.rowsOffset)
        let stride = Int(header.rowStride)
        if header.rowCount == 0 {
            return []
        }
        guard stride == rowSize else {
            throw EngineReadDecodeError.invalidRowStride(expected: UInt32(rowSize), actual: header.rowStride)
        }
        return (0..<Int(header.rowCount)).map { start + $0 * stride }
    }

    private func string(_ ref: EngineReadStringRef, header: EngineReadResultHeader) throws -> String {
        if ref.length == 0 {
            return ""
        }
        let arenaOffset = Int(header.stringArenaOffset)
        let arenaLength = Int(header.stringArenaLength)
        let relativeOffset = Int(ref.offset)
        let length = Int(ref.length)
        guard relativeOffset >= 0,
              length >= 0,
              relativeOffset + length <= arenaLength,
              arenaOffset + relativeOffset + length <= buffer.count
        else {
            throw EngineReadDecodeError.invalidStringRef
        }
        let start = arenaOffset + relativeOffset
        let bytes = [UInt8](buffer[start..<(start + length)])
        guard let value = String(bytes: bytes, encoding: .utf8) else {
            throw EngineReadDecodeError.invalidUTF8
        }
        return value
    }

    private func optionalString(_ ref: EngineReadStringRef, header: EngineReadResultHeader) throws -> String? {
        let value = try string(ref, header: header)
        return value.isEmpty ? nil : value
    }

    private func stringRef(at offset: Int) throws -> EngineReadStringRef {
        EngineReadStringRef(offset: try uint32(at: offset), length: try uint32(at: offset + 4))
    }

    private func fileTreeState(_ state: UInt32) throws -> FileTreeResultState {
        switch state {
        case EngineReadABI.State.complete:
            return .complete
        case EngineReadABI.State.partial:
            return .partial
        case EngineReadABI.State.stale:
            return .stale
        default:
            throw EngineReadDecodeError.unknownState(state)
        }
    }

    private func searchState(_ state: UInt32) throws -> SearchResultState {
        switch state {
        case EngineReadABI.State.complete:
            return .complete
        case EngineReadABI.State.partial:
            return .partial
        case EngineReadABI.State.stale:
            return .stale
        case EngineReadABI.State.cancelled:
            return .cancelled
        case EngineReadABI.State.error, EngineReadABI.State.indexUnavailable:
            return .error
        default:
            throw EngineReadDecodeError.unknownState(state)
        }
    }

    private func nextOffset(_ value: UInt64) throws -> Int? {
        if value == EngineReadABI.noNextOffset {
            return nil
        }
        guard value <= UInt64(Int.max) else {
            throw EngineReadDecodeError.invalidStringRef
        }
        return Int(value)
    }

    private func attachmentSource(_ value: UInt32) throws -> AttachmentReferenceSource {
        switch value {
        case 1:
            return .wikiEmbed
        case 2:
            return .markdownImage
        case 3:
            return .markdownLink
        default:
            throw EngineReadDecodeError.unknownState(value)
        }
    }

    private func liveAttachmentSource(_ value: UInt32) throws -> AttachmentReferenceSource {
        switch value {
        case 4:
            return .wikiEmbed
        case 5:
            return .markdownImage
        case 3:
            return .markdownLink
        default:
            throw EngineReadDecodeError.unknownState(value)
        }
    }

    private func attachmentState(_ value: UInt32, resolvedPath: String?) throws -> AttachmentResolutionState {
        switch value {
        case 1:
            guard let resolvedPath else {
                throw EngineReadDecodeError.invalidStringRef
            }
            return .resolved(FileTreeItem(relativePath: resolvedPath))
        case 2:
            return .missing
        case 3:
            return .duplicate([])
        case 4:
            return .remote
        case 5:
            return .rejected(.urlScheme)
        case 6:
            return .unsupported
        default:
            throw EngineReadDecodeError.unknownState(value)
        }
    }

    private func liveLinkState(_ value: UInt32, resolvedPath: String?) -> LinkResolutionState {
        if value == 1, let resolvedPath {
            return .resolved(FileTreeItem(relativePath: resolvedPath))
        }
        return .missing
    }

    private func graphNodeKind(_ value: UInt32) throws -> LocalGraphNodeKind {
        switch value {
        case 1:
            return .center
        case 2:
            return .resolved
        case 3:
            return .unresolved
        default:
            throw EngineReadDecodeError.unknownGraphNodeKind(value)
        }
    }

    private func graphEdgeDirection(_ value: UInt32) throws -> LocalGraphEdgeDirection {
        switch value {
        case 1:
            return .outgoing
        case 2:
            return .backlink
        default:
            throw EngineReadDecodeError.unknownGraphEdgeDirection(value)
        }
    }

    private func syntaxTokenKind(_ value: UInt32) throws -> LivePreviewCodeFenceToken.Kind {
        switch value {
        case 1:
            return .keyword
        case 2:
            return .string
        case 3:
            return .number
        case 4:
            return .comment
        case 5:
            return .propertyKey
        case 6:
            return .operatorToken
        default:
            throw EngineReadDecodeError.unknownSyntaxTokenKind(value)
        }
    }

    private func require(_ byteCount: Int) throws {
        guard buffer.count >= byteCount else {
            throw EngineReadDecodeError.bufferTooShort(required: byteCount, actual: buffer.count)
        }
    }

    private func uint32(at offset: Int) throws -> UInt32 {
        try require(offset + 4)
        return UInt32(buffer[offset])
            | UInt32(buffer[offset + 1]) << 8
            | UInt32(buffer[offset + 2]) << 16
            | UInt32(buffer[offset + 3]) << 24
    }

    private func uint64(at offset: Int) throws -> UInt64 {
        try require(offset + 8)
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(buffer[offset + index]) << UInt64(index * 8)
        }
        return value
    }

    private func double(at offset: Int) throws -> Double {
        Double(bitPattern: try uint64(at: offset))
    }
}
