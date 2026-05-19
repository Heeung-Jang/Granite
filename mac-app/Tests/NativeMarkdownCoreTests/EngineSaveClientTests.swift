import Foundation
import Testing
@testable import NativeMarkdownCore

@Test
func engineSaveClientDecodesBaselineEnvelope() throws {
    let json = """
    {
      "ok": true,
      "value": {
        "relative_path": "Home.md",
        "file_identity": { "device": 1, "inode": 2 },
        "size_bytes": 7,
        "modified": { "secs_since_unix_epoch": 100, "nanos": 5 },
        "content_hash": "abc"
      },
      "error": null
    }
    """

    let baseline = try EngineSaveClient.decodeEnvelope(json, as: EngineSaveBaseline.self)

    #expect(baseline.relativePath == "Home.md")
    #expect(baseline.fileIdentity == EngineFileIdentity(device: 1, inode: 2))
    #expect(baseline.sizeBytes == 7)
    #expect(baseline.modified == EngineSystemTime(secsSinceUnixEpoch: 100, nanos: 5))
    #expect(baseline.contentHash == "abc")
}

@Test
func engineSaveClientDecodesSaveOutcomeEnvelope() throws {
    let json = """
    {
      "ok": true,
      "value": {
        "baseline": {
          "relative_path": "Home.md",
          "file_identity": { "device": 1, "inode": 3 },
          "size_bytes": 9,
          "modified": null,
          "content_hash": "def"
        },
        "bytes_written": 9
      },
      "error": null
    }
    """

    let outcome = try EngineSaveClient.decodeEnvelope(json, as: EngineSaveOutcome.self)

    #expect(outcome.baseline.relativePath == "Home.md")
    #expect(outcome.baseline.fileIdentity.inode == 3)
    #expect(outcome.baseline.modified == nil)
    #expect(outcome.bytesWritten == 9)
}

@Test
func engineSaveClientDecodesStructuredErrorEnvelope() {
    let json = """
    {
      "ok": false,
      "value": null,
      "error": {
        "code": "save_conflict",
        "message": "changed",
        "conflict_kind": "ContentChanged"
      }
    }
    """

    #expect(throws: EngineSaveClientError.engine(EngineSaveErrorPayload(
        code: "save_conflict",
        message: "changed",
        conflictKind: "ContentChanged"
    ))) {
        try EngineSaveClient.decodeEnvelope(json, as: EngineSaveOutcome.self)
    }
}

@Test
func engineSaveClientReportsMissingLibrary() throws {
    let client = EngineSaveClient(libraryPath: "/definitely/missing/libvault_engine.dylib")

    do {
        _ = try client.captureBaseline(
            vaultURL: URL(fileURLWithPath: "/tmp/vault", isDirectory: true),
            file: FileTreeItem(relativePath: "Home.md")
        )
        Issue.record("expected missing library")
    } catch EngineSaveClientError.missingLibrary(let message) {
        #expect(message.contains("libvault_engine"))
    }
}
