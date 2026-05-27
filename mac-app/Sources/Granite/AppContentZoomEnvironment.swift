import NativeMarkdownCore
import SwiftUI

private struct AppContentZoomScaleKey: EnvironmentKey {
    static let defaultValue = AppContentZoom.defaultScale
}

extension EnvironmentValues {
    var appContentZoomScale: Double {
        get { self[AppContentZoomScaleKey.self] }
        set { self[AppContentZoomScaleKey.self] = AppContentZoom(rawScale: newValue).scale }
    }
}
