import NativeMarkdownCore
import SwiftUI

@main
struct NativeMarkdownApp: App {
    @StateObject private var appState = AppState()

    init() {
        if CommandLine.arguments.contains("--smoke-test") {
            print("NativeMarkdownApp smoke test")
            Foundation.exit(0)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .frame(minWidth: 960, minHeight: 640)
        }
        .windowStyle(.titleBar)
    }
}
