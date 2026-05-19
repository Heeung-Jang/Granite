import Foundation
import Testing
@testable import NativeMarkdownCore

@Test
func appStateSelectsAndClearsVault() {
    let state = AppState(engineHealth: EngineHealthStatus(
        state: .loaded,
        abiVersion: 1,
        message: "test"
    ))
    let url = URL(fileURLWithPath: "/tmp/example-vault", isDirectory: true)

    #expect(state.vaultSelection == .noVault)

    state.selectVault(url)
    #expect(state.vaultSelection == .selected(url))

    state.clearVault()
    #expect(state.vaultSelection == .noVault)
}

@Test
func engineHealthDetectsAbiMismatch() {
    let status = EngineHealthStatus.evaluate(
        abiVersion: 2,
        expectedAbiVersion: 1,
        message: "test"
    )

    #expect(status.state == .abiMismatch)
    #expect(status.abiVersion == 2)
}
