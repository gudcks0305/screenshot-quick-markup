import AppKit
import Testing
@testable import ScreenshotQuickMarkup

@Suite("Annotation rendering", .serialized)
@MainActor
struct AnnotationRendererTests {
    init() {
        _ = NSApplication.shared
    }

    @Test("Export preserves native pixels, orientation, and annotation coordinates")
    func nativePixelExport() throws {
        let image = try makeImage()
        let renderer = AnnotationRenderer(image: image)
        let annotation = Annotation.stroke(
            points: [NSPoint(x: 5, y: 5), NSPoint(x: 15, y: 5)],
            color: .green, width: 4, alpha: 1
        )
        let data = try #require(renderer.renderedPNGData(annotations: [annotation]))
        let bitmap = try #require(NSBitmapImageRep(data: data))

        #expect(bitmap.pixelsWide == 160)
        #expect(bitmap.pixelsHigh == 120)
        try expectDominantChannel(bitmap, x: 80, y: 10, channel: .red)
        try expectDominantChannel(bitmap, x: 80, y: 110, channel: .blue)
        try expectDominantChannel(bitmap, x: 20, y: 10, channel: .green)
    }

    @Test("Images without pixel dimensions export at their logical size")
    func logicalSizeFallback() throws {
        let image = NSImage(size: NSSize(width: 40, height: 30), flipped: true) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let renderer = AnnotationRenderer(image: image)
        let data = try #require(renderer.renderedPNGData(annotations: []))
        let bitmap = try #require(NSBitmapImageRep(data: data))

        #expect(bitmap.pixelsWide == 40)
        #expect(bitmap.pixelsHigh == 30)
        try expectDominantChannel(bitmap, x: 20, y: 15, channel: .red)
    }

    @Test("Incomplete strokes leave the exported image unchanged")
    func incompleteStrokes() throws {
        let renderer = AnnotationRenderer(image: try makeImage())
        let original = try #require(renderer.renderedPNGData(annotations: []))
        let incomplete: [Annotation] = [
            .stroke(points: [], color: .green, width: 4, alpha: 1),
            .stroke(points: [NSPoint(x: 10, y: 10)], color: .green, width: 4, alpha: 1)
        ]

        #expect(renderer.renderedPNGData(annotations: incomplete) == original)
    }

    @Test("Preview zoom and mosaic cache do not change the exported image")
    func previewDoesNotChangeExport() throws {
        let renderer = AnnotationRenderer(image: try makeImage())
        let start = NSPoint(x: 10, y: 10)
        let end = NSPoint(x: 60, y: 45)
        let annotations: [Annotation] = [
            .stroke(points: [start, end], color: .green, width: 4, alpha: 0.32),
            .shape(kind: .arrow, start: start, end: end, color: .red, width: 3),
            .shape(kind: .rectangle, start: start, end: end, color: .green, width: 2),
            .shape(kind: .ellipse, start: start, end: end, color: .blue, width: 2),
            .mosaic(start: start, end: end, strength: 4),
            .marker(number: 12, center: end, color: .red),
            .checkmark(center: start, color: .green),
            .text("Markup", origin: start, color: .black, fontSize: 16, background: true)
        ]
        let original = try #require(renderer.renderedPNGData(annotations: annotations))
        for scale: CGFloat in [0.25, 1, 2] {
            _ = try preview(renderer, annotations: annotations, scale: scale)
            #expect(renderer.renderedPNGData(annotations: annotations) == original)
        }
    }

    @Test("Small previews keep markers readable and mosaic borders are preview-only")
    func previewDecorations() throws {
        let renderer = AnnotationRenderer(image: try makeImage())
        let marker = Annotation.marker(number: 1, center: NSPoint(x: 40, y: 40), color: .red)
        let markerBitmap = try preview(renderer, annotations: [marker], scale: 0.25)
        // Center is (30, 30) after the preview transform. A literal 25% radius
        // would end at 33.5; the existing readability floor extends past 37.
        let markerEdge = try #require(markerBitmap.colorAt(x: 37, y: 30))
        #expect(markerEdge.alphaComponent > 0.9)

        let mosaic = Annotation.mosaic(start: NSPoint(x: 10, y: 10), end: NSPoint(x: 60, y: 45), strength: 4)
        let bordered = try preview(renderer, annotations: [mosaic], scale: 1)
        let borderless = try preview(renderer, annotations: [mosaic], scale: 1, showsMosaicBorder: false)
        #expect(bordered.representation(using: .png, properties: [:]) != borderless.representation(using: .png, properties: [:]))
        let centerWithBorder = try #require(bordered.colorAt(x: 50, y: 45))
        let centerWithoutBorder = try #require(borderless.colorAt(x: 50, y: 45))
        #expect(centerWithBorder == centerWithoutBorder)
    }

    private func makeImage() throws -> NSImage {
        let bitmap = try makeBitmap(width: 160, height: 120)
        let red = NSColor(calibratedRed: 1, green: 0, blue: 0, alpha: 1)
        let blue = NSColor(calibratedRed: 0, green: 0, blue: 1, alpha: 1)
        for y in 0..<120 {
            for x in 0..<160 {
                bitmap.setColor(y < 60 ? red : blue, atX: x, y: y)
            }
        }
        let image = NSImage(size: NSSize(width: 80, height: 60))
        image.addRepresentation(bitmap)
        return image
    }

    private func makeBitmap(width: Int, height: Int) throws -> NSBitmapImageRep {
        try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
    }

    private func preview(
        _ renderer: AnnotationRenderer,
        annotations: [Annotation],
        scale: CGFloat,
        showsMosaicBorder: Bool = true
    ) throws -> NSBitmapImageRep {
        let bitmap = try makeBitmap(width: 200, height: 160)
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        context.cgContext.clear(CGRect(x: 0, y: 0, width: 200, height: 160))
        context.cgContext.translateBy(x: 0, y: 160)
        context.cgContext.scaleBy(x: 1, y: -1)
        let previousContext = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        defer { NSGraphicsContext.current = previousContext }
        for annotation in annotations {
            renderer.draw(annotation, scale: scale, transform: {
                NSPoint(x: 20 + $0.x * scale, y: 20 + $0.y * scale)
            }, showsMosaicBorder: showsMosaicBorder)
        }
        return bitmap
    }

    private enum Channel: Int {
        case red, green, blue
    }

    private func expectDominantChannel(
        _ bitmap: NSBitmapImageRep, x: Int, y: Int, channel: Channel
    ) throws {
        let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
        // Check spatial orientation without depending on the machine's RGB profile.
        let components = [color.redComponent, color.greenComponent, color.blueComponent]
        #expect(components[channel.rawValue] > 0.8)
        for index in components.indices where index != channel.rawValue {
            #expect(components[index] < 0.4)
        }
        #expect(color.alphaComponent > 0.98)
    }
}
