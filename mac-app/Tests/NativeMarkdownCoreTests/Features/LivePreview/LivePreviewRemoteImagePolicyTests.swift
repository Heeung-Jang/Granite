import Foundation
import Testing
@testable import NativeMarkdownCore

@Test
func livePreviewRemoteImagePolicyAllowsHTTPAndHTTPSWhenEnabled() throws {
    let policy = LivePreviewRemoteImagePolicy(isEnabled: true)

    #expect(policy.allows(try #require(URL(string: "https://example.com/image.png"))))
    #expect(policy.allows(try #require(URL(string: "http://example.com/image.png"))))
}

@Test
func livePreviewRemoteImagePolicyBlocksRemoteWhenDisabled() throws {
    let policy = LivePreviewRemoteImagePolicy(isEnabled: false)

    #expect(!policy.allows(try #require(URL(string: "https://example.com/image.png"))))
}

@Test
func livePreviewRemoteImagePolicyRejectsUnsafeSchemes() throws {
    let policy = LivePreviewRemoteImagePolicy(isEnabled: true)

    #expect(!policy.allows(try #require(URL(string: "file:///tmp/image.png"))))
    #expect(!policy.allows(try #require(URL(string: "data:image/png;base64,abc"))))
    #expect(!policy.allows(try #require(URL(string: "javascript:alert(1)"))))
}

