import Testing
@testable import NativeMarkdownCore

@Test
func appContentZoomDefaultsToActualSize() {
    let zoom = AppContentZoom()

    #expect(zoom.scale == 1.0)
    #expect(AppContentZoom.actualSize.scale == 1.0)
    #expect(AppContentZoom.storageKey == "appContentZoomScale")
}

@Test
func appContentZoomNormalizesInvalidValues() {
    #expect(AppContentZoom(rawScale: .nan).scale == 1.0)
    #expect(AppContentZoom(rawScale: .infinity).scale == 1.0)
    #expect(AppContentZoom(rawScale: -.infinity).scale == 1.0)
}

@Test
func appContentZoomClampsToSupportedRange() {
    #expect(AppContentZoom(rawScale: 0).scale == 0.75)
    #expect(AppContentZoom(rawScale: 0.75).scale == 0.75)
    #expect(AppContentZoom(rawScale: 1.0).scale == 1.0)
    #expect(AppContentZoom(rawScale: 1.75).scale == 1.75)
    #expect(AppContentZoom(rawScale: 2.5).scale == 1.75)
}

@Test
func appContentZoomStepsAndRoundsToTwoDecimals() {
    #expect(AppContentZoom(rawScale: 1.0).zoomedIn().scale == 1.1)
    #expect(AppContentZoom(rawScale: 1.0).zoomedOut().scale == 0.9)
    #expect(AppContentZoom(rawScale: 1.234).scale == 1.23)
    #expect(AppContentZoom(rawScale: 1.235).scale == 1.24)
}

@Test
func appContentZoomStepOperationsClampAtBoundaries() {
    #expect(AppContentZoom(rawScale: 1.75).zoomedIn().scale == 1.75)
    #expect(AppContentZoom(rawScale: 0.75).zoomedOut().scale == 0.75)
}

@Test
func appContentZoomRepeatedStepsDoNotDrift() {
    var zoom = AppContentZoom.actualSize

    for _ in 0..<3 {
        zoom = zoom.zoomedIn()
    }
    #expect(zoom.scale == 1.3)

    for _ in 0..<6 {
        zoom = zoom.zoomedOut()
    }
    #expect(zoom.scale == 0.75)
}
