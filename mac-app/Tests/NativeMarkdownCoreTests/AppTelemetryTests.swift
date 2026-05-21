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
func telemetryRedactionOmitsSecretLookingProperties() {
    let property = PropertyItem(key: "secret_token", value: "fixture-secret-not-real")
    let identifier = AppTelemetry.redactedIdentifier(for: "\(property.key)=\(property.value)")

    #expect(identifier.count == 16)
    #expect(!identifier.contains("secret_token"))
    #expect(!identifier.contains("fixture-secret"))
    #expect(identifier == AppTelemetry.redactedIdentifier(for: "\(property.key)=\(property.value)"))
}

@Test
func telemetrySchemaDefinesAllowedAndDisallowedFields() {
    let schema = AppTelemetry.privacySchema

    #expect(schema.allowsPublicField("durationMilliseconds"))
    #expect(schema.allowsPublicField("byteCount"))
    #expect(schema.allowsPublicField("fallbackReason"))
    #expect(schema.allowsPublicField("hardCeilingPassed"))
    #expect(schema.allowsPublicField("hardCeilingViolations"))
    #expect(schema.allowsPublicField("memoryDeltaBytes"))
    #expect(schema.allowsPublicField("source"))
    #expect(schema.rejectsRawField("absolutePath"))
    #expect(schema.rejectsRawField("fileName"))
    #expect(schema.rejectsRawField("noteText"))
    #expect(schema.rejectsRawField("linkTarget"))
    #expect(schema.rejectsRawField("tagName"))
    #expect(schema.rejectsRawField("embedName"))
    #expect(!schema.allowsPublicField("noteText"))
    #expect(!schema.allowsPublicField("absolutePath"))
}

@Test
func telemetryRedactsPrivateMarkdownValues() {
    let sensitiveValues = [
        "/Users/example/Codex Vault/Private/Secret Note.md",
        "Secret Note.md",
        "private note body with customer details",
        "https://example.invalid/private/project-plan",
        "#private/project",
        "Screenshots/secret-diagram.png"
    ]

    for value in sensitiveValues {
        let identifier = AppTelemetry.redactedIdentifier(for: value)

        #expect(identifier.count == 16)
        #expect(identifier == AppTelemetry.redactedIdentifier(for: value))
        #expect(!identifier.contains("Secret"))
        #expect(!identifier.contains("private"))
        #expect(!identifier.contains("project"))
        #expect(!identifier.contains("diagram"))
    }
}

@Test
func telemetryTimerReportsMilliseconds() {
    let timer = AppTelemetryTimer(startNanoseconds: 1_000_000)

    #expect(timer.elapsedMilliseconds(nowNanoseconds: 9_000_000) == 8)
    #expect(timer.elapsedMilliseconds(nowNanoseconds: 500_000) == 0)
}
