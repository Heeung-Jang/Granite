import Testing
@testable import NativeMarkdownCore

@Test
func vaultNameValidationRejectsUnsupportedNames() throws {
    let validator = VaultNameValidator()

    #expect(throws: VaultNameValidationError.empty) {
        try validator.validateVaultName("")
    }
    #expect(throws: VaultNameValidationError.empty) {
        try validator.validateVaultName("   ")
    }
    #expect(throws: VaultNameValidationError.reserved(".")) {
        try validator.validateVaultName(".")
    }
    #expect(throws: VaultNameValidationError.reserved("..")) {
        try validator.validateVaultName("..")
    }
    #expect(throws: VaultNameValidationError.containsPathSeparator) {
        try validator.validateVaultName("Nested/Vault")
    }
    #expect(throws: VaultNameValidationError.containsColon) {
        try validator.validateVaultName("Bad:Vault")
    }
}

@Test
func vaultNameValidationAcceptsKoreanAndSpaces() throws {
    let validator = VaultNameValidator()

    #expect(try validator.validateVaultName("새 볼트") == "새 볼트")
    #expect(try validator.validateFolderName("Project Notes") == "Project Notes")
}

@Test
func noteNameValidationNormalizesMarkdownExtension() throws {
    let validator = VaultNameValidator()

    #expect(try validator.validateNoteName("Meeting") == "Meeting.md")
    #expect(try validator.validateNoteName("Meeting.md") == "Meeting.md")
    #expect(try validator.validateNoteName("Meeting.MD") == "Meeting.MD")
    #expect(throws: VaultNameValidationError.unsupportedNoteExtension("txt")) {
        try validator.validateNoteName("Meeting.txt")
    }
}
