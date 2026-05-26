import Foundation

public struct EditorBufferSnapshot: Equatable, Sendable {
    public let vaultID: String
    public let fileID: String
    public let tabID: UUID
    public let ownerID: UUID
    public let revision: UInt64
    public let contentHash: String
    public let byteCount: Int
    public let contents: String

    public init(
        vaultID: String,
        fileID: String,
        tabID: UUID,
        ownerID: UUID,
        revision: UInt64,
        contents: String
    ) {
        self.vaultID = vaultID
        self.fileID = fileID
        self.tabID = tabID
        self.ownerID = ownerID
        self.revision = revision
        self.contentHash = SummaryContentHash.hash(contents)
        self.byteCount = contents.utf8.count
        self.contents = contents
    }
}

public enum SummaryContentHash {
    public static func hash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
