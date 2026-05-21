import Testing
@testable import NativeMarkdownCore

@Test
func openDispositionResolverUsesCommandKeyForNewTabs() {
    #expect(OpenDispositionResolver.resolve(isCommandPressed: false) == .currentTab)
    #expect(OpenDispositionResolver.resolve(isCommandPressed: true) == .newTab)
}
