import CoreGraphics
import Testing
@testable import ScreenshotQuickMarkupCore

@Suite("Markup geometry")
struct MarkupGeometryTests {
    @Test("Rectangle normalization supports every drag direction", arguments: [
        (CGPoint(x: 10, y: 20), CGPoint(x: 30, y: 40)),
        (CGPoint(x: 30, y: 20), CGPoint(x: 10, y: 40)),
        (CGPoint(x: 10, y: 40), CGPoint(x: 30, y: 20)),
        (CGPoint(x: 30, y: 40), CGPoint(x: 10, y: 20))
    ])
    func normalizedRect(start: CGPoint, end: CGPoint) {
        let rect = MarkupGeometry.normalizedRect(from: start, to: end)

        #expect(rect == CGRect(x: 10, y: 20, width: 20, height: 20))
    }

    @Test("Preview scale preserves useful small-image scale")
    func previewScaleForSmallImage() {
        let scale = MarkupGeometry.previewScale(
            for: CGSize(width: 100, height: 100),
            viewportSize: CGSize(width: 1_000, height: 800)
        )

        #expect(scale == 4)
    }

    @Test("Preview scale fits large images")
    func previewScaleForLargeImage() {
        let scale = MarkupGeometry.previewScale(
            for: CGSize(width: 2_000, height: 1_000),
            viewportSize: CGSize(width: 1_120, height: 640)
        )

        #expect(scale == 0.5)
    }

    @Test("Preview scale never falls below quarter size")
    func previewScaleFloor() {
        let scale = MarkupGeometry.previewScale(
            for: CGSize(width: 10_000, height: 10_000),
            viewportSize: CGSize(width: 100, height: 100)
        )

        #expect(scale == 0.25)
    }

    @Test("Crop conversion flips Y and applies independent display scales")
    func captureCropConversion() {
        let crop = MarkupGeometry.captureCropRect(
            selection: CGRect(x: 100, y: 50, width: 200, height: 100),
            screenSize: CGSize(width: 1_000, height: 500),
            imagePixelSize: CGSize(width: 2_000, height: 1_500)
        )

        #expect(crop == CGRect(x: 200, y: 1_050, width: 400, height: 300))
    }

    @Test("Crop conversion standardizes and clamps selection")
    func captureCropClamping() {
        let crop = MarkupGeometry.captureCropRect(
            selection: CGRect(x: 75, y: 75, width: -100, height: -100),
            screenSize: CGSize(width: 100, height: 100),
            imagePixelSize: CGSize(width: 200, height: 200)
        )

        #expect(crop == CGRect(x: 0, y: 50, width: 150, height: 150))
    }

    @Test("Crop conversion expands fractional pixels outward")
    func captureCropIntegralPixels() {
        let crop = MarkupGeometry.captureCropRect(
            selection: CGRect(x: 0.25, y: 0.25, width: 1, height: 1),
            screenSize: CGSize(width: 10, height: 10),
            imagePixelSize: CGSize(width: 10, height: 10)
        )

        #expect(crop == CGRect(x: 0, y: 8, width: 2, height: 2))
    }

    @Test("Crop conversion rejects non-overlap and invalid dimensions")
    func captureCropInvalidInput() {
        #expect(MarkupGeometry.captureCropRect(
            selection: CGRect(x: 101, y: 0, width: 10, height: 10),
            screenSize: CGSize(width: 100, height: 100),
            imagePixelSize: CGSize(width: 200, height: 200)
        ) == nil)
        #expect(MarkupGeometry.captureCropRect(
            selection: CGRect(x: 0, y: 0, width: 10, height: 10),
            screenSize: .zero,
            imagePixelSize: CGSize(width: 200, height: 200)
        ) == nil)
    }

    @Test("Point-to-segment distance handles perpendicular projection")
    func pointToSegmentDistance() {
        let distance = MarkupGeometry.distance(
            from: CGPoint(x: 5, y: 4),
            toSegmentFrom: CGPoint(x: 0, y: 0),
            to: CGPoint(x: 10, y: 0)
        )

        #expect(distance == 4)
    }

    @Test("Point-to-segment distance clamps to endpoints")
    func pointToSegmentEndpointDistance() {
        let distance = MarkupGeometry.distance(
            from: CGPoint(x: 13, y: 4),
            toSegmentFrom: CGPoint(x: 0, y: 0),
            to: CGPoint(x: 10, y: 0)
        )

        #expect(distance == 5)
    }

    @Test("Point-to-segment distance handles a zero-length segment")
    func pointToDegenerateSegmentDistance() {
        let distance = MarkupGeometry.distance(
            from: CGPoint(x: 3, y: 4),
            toSegmentFrom: .zero,
            to: .zero
        )

        #expect(distance == 5)
    }

    @Test("Expanded rectangle and tolerant hit test include nearby points")
    func rectHitTolerance() {
        let rect = CGRect(x: 10, y: 10, width: 20, height: 20)

        #expect(MarkupGeometry.expanded(rect, by: 5) == CGRect(x: 5, y: 5, width: 30, height: 30))
        #expect(MarkupGeometry.contains(CGPoint(x: 33, y: 20), in: rect, tolerance: 4))
        #expect(!MarkupGeometry.contains(CGPoint(x: 35, y: 20), in: rect, tolerance: 4))
    }

    @Test("Translation clamp respects bounds and existing overflow")
    func translationClamp() {
        #expect(MarkupGeometry.clampedTranslationDelta(
            minimum: 20,
            maximum: 60,
            limit: 100,
            proposed: 80
        ) == 40)
        #expect(MarkupGeometry.clampedTranslationDelta(
            minimum: -14,
            maximum: 14,
            limit: 100,
            proposed: 1
        ) == 1)
        #expect(MarkupGeometry.clampedTranslationDelta(
            minimum: -14,
            maximum: 14,
            limit: 100,
            proposed: -1
        ) == 0)
        #expect(MarkupGeometry.clampedTranslationDelta(
            minimum: -50,
            maximum: 150,
            limit: 100,
            proposed: 80
        ) == 50)
    }
}
