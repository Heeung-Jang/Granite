import Foundation
import Testing
@testable import NativeMarkdownCore

@Test
func appStateSelectsAndClearsVault() {
    let state = AppState()
    let url = URL(fileURLWithPath: "/tmp/example-vault", isDirectory: true)

    #expect(state.vaultSelection == .noVault)

    state.selectVault(url)
    #expect(state.vaultSelection == .selected(url))

    state.clearVault()
    #expect(state.vaultSelection == .noVault)
}

