import Testing
@testable import NativeMarkdownCore

@Test
func telemetryRedactsRawRelativePaths() {
    let path = "Private/Secret Note.md"
    let identifier = AppTelemetry.redactedIdentifier(for: path)

    #expect(identifier.count == 16)
    #expect(!identifier.contains("Private"))
    #expect(!identifier.contains("Secret"))
    #expect(identifier == AppTelemetry.redactedIdentifier(for: path))
}

@Test
func telemetryRedactionOmitsContentLikeValues() {
    let sensitiveValue = "/Users/example/Vault/Private/Secret Note.md\napiKey: private-token"
    let identifier = AppTelemetry.redactedIdentifier(for: sensitiveValue)

    #expect(identifier.count == 16)
    #expect(!identifier.contains("Users"))
    #expect(!identifier.contains("Secret"))
    #expect(!identifier.contains("private-token"))
    #expect(identifier == AppTelemetry.redactedIdentifier(for: sensitiveValue))
}

@Test
func telemetryTimerReportsMilliseconds() {
    let timer = AppTelemetryTimer(startNanoseconds: 1_000_000)

    #expect(timer.elapsedMilliseconds(nowNanoseconds: 9_000_000) == 8)
    #expect(timer.elapsedMilliseconds(nowNanoseconds: 500_000) == 0)
}
