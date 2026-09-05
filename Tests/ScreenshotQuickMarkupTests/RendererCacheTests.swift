import AppKit
import Testing
@testable import ScreenshotQuickMarkup

@Suite("Renderer mosaic cache", .serialized)
@MainActor
struct RendererCacheTests {
    init() {
        _ = NSApplication.shared
    }

    @Test("Forty mosaics remain hot across repeated rendering")
    func repeatedMosaicsHitCache() throws {
        let renderer = AnnotationRenderer(image: try makeImage())
        let mosaics = makeMosaics(count: 40, strength: 4)

        try draw(mosaics, with: renderer)
        let firstPass = renderer.mosaicCacheStatistics
        #expect(firstPass.entryCount == 40)
        #expect(firstPass.hitCount == 0)
        #expect(firstPass.missCount == 40)
        #expect(firstPass.evictionCount == 0)

        try draw(mosaics, with: renderer)
        let secondPass = renderer.mosaicCacheStatistics
        #expect(secondPass.entryCount == 40)
        #expect(secondPass.hitCount == 40)
        #expect(secondPass.missCount == 40)
        #expect(secondPass.evictionCount == 0)
    }

    @Test("Entry limit evicts the least recently used mosaic")
    func entryLimitUsesLRU() throws {
        let renderer = AnnotationRenderer(image: try makeImage())
        let mosaics = makeMosaics(count: AnnotationRenderer.mosaicCacheEntryLimit + 1, strength: 4)

        try withGraphicsContext {
            for mosaic in mosaics.dropLast() {
                renderer.draw(mosaic, scale: 1, transform: { $0 }, showsMosaicBorder: false)
            }
            renderer.draw(mosaics[0], scale: 1, transform: { $0 }, showsMosaicBorder: false)
            renderer.draw(mosaics.last!, scale: 1, transform: { $0 }, showsMosaicBorder: false)
            renderer.draw(mosaics[1], scale: 1, transform: { $0 }, showsMosaicBorder: false)
            renderer.draw(mosaics[0], scale: 1, transform: { $0 }, showsMosaicBorder: false)
        }

        let statistics = renderer.mosaicCacheStatistics
        #expect(statistics.entryCount == AnnotationRenderer.mosaicCacheEntryLimit)
        #expect(statistics.hitCount == 2)
        #expect(statistics.missCount == AnnotationRenderer.mosaicCacheEntryLimit + 2)
        #expect(statistics.evictionCount == 2)
    }

    @Test("Decoded image cost stays within sixteen MiB")
    func decodedCostIsBounded() throws {
        let renderer = AnnotationRenderer(image: try makeImage())
        let mosaics = makeMosaics(count: 48, strength: 1)

        try draw(mosaics, with: renderer, transform: {
            NSPoint(x: $0.x * 120, y: $0.y * 120)
        })

        let statistics = renderer.mosaicCacheStatistics
        #expect(statistics.totalCost <= AnnotationRenderer.mosaicCacheCostLimit)
        #expect(statistics.entryCount < mosaics.count)
        #expect(statistics.evictionCount > 0)
    }

    @Test("CGImage export preserves native pixel dimensions")
    func renderedCGImageUsesNativePixels() throws {
        let renderer = AnnotationRenderer(image: try makeImage())
        let image = try #require(renderer.renderedCGImage(annotations: []))

        #expect(image.width == 256)
        #expect(image.height == 256)
    }

    @Test("Redactions are opaque black and export after mosaics")
    func redactionsRenderLast() throws {
        let renderer = AnnotationRenderer(image: try makeImage())
        let rect = (start: NSPoint(x: 40, y: 40), end: NSPoint(x: 100, y: 100))
        let data = try #require(renderer.renderedPNGData(annotations: [
            .redaction(start: rect.start, end: rect.end),
            .mosaic(start: rect.start, end: rect.end, strength: 4)
        ]))
        let bitmap = try #require(NSBitmapImageRep(data: data))
        let center = try #require(bitmap.colorAt(x: 70, y: 70)?.usingColorSpace(.deviceRGB))

        #expect(center.redComponent == 0)
        #expect(center.greenComponent == 0)
        #expect(center.blueComponent == 0)
        #expect(center.alphaComponent == 1)
    }

    private func makeImage() throws -> NSImage {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 256,
            pixelsHigh: 256,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        let previousContext = NSGraphicsContext.current
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 256, height: 256).fill()
        NSGraphicsContext.current = previousContext

        let image = NSImage(size: NSSize(width: 256, height: 256))
        image.addRepresentation(bitmap)
        return image
    }

    private func makeMosaics(count: Int, strength: CGFloat) -> [Annotation] {
        (0..<count).map { index in
            let start = NSPoint(
                x: 4 + CGFloat(index % 10) * 24,
                y: 4 + CGFloat(index / 10) * 24
            )
            return .mosaic(
                start: start,
                end: NSPoint(x: start.x + 18, y: start.y + 18),
                strength: strength
            )
        }
    }

    private func draw(
        _ annotations: [Annotation],
        with renderer: AnnotationRenderer,
        transform: (NSPoint) -> NSPoint = { $0 }
    ) throws {
        try withGraphicsContext {
            for annotation in annotations {
                renderer.draw(
                    annotation,
                    scale: 1,
                    transform: transform,
                    showsMosaicBorder: false
                )
            }
        }
    }

    private func withGraphicsContext(_ body: () -> Void) throws {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 256,
            pixelsHigh: 256,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        let previousContext = NSGraphicsContext.current
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.current = previousContext }
        body()
    }
}
