@preconcurrency import AppKit
import ScreenshotQuickMarkupCore

@MainActor
final class AnnotationRenderer {
    static let mosaicCacheEntryLimit = 64
    static let mosaicCacheCostLimit = 16 * 1024 * 1024

    struct MosaicCacheStatistics: Equatable {
        let entryCount: Int
        let totalCost: Int
        let hitCount: Int
        let missCount: Int
        let evictionCount: Int
    }

    private let image: NSImage
    private let outputPixelSize: NSSize
    private var mosaicCache: [MosaicCacheKey: MosaicCacheEntry] = [:]
    private var mosaicCacheTotalCost = 0
    private var mosaicCacheAccessSequence: UInt64 = 0
    private var mosaicCacheHitCount = 0
    private var mosaicCacheMissCount = 0
    private var mosaicCacheEvictionCount = 0

    private struct MosaicCacheKey: Hashable {
        let sourceX: Int
        let sourceY: Int
        let sourceWidth: Int
        let sourceHeight: Int
        let pixelWidth: Int
        let pixelHeight: Int
        let strength: Int
    }

    private struct MosaicCacheEntry {
        let image: NSImage
        let cost: Int
        var lastAccess: UInt64
    }

    var mosaicCacheStatistics: MosaicCacheStatistics {
        MosaicCacheStatistics(
            entryCount: mosaicCache.count,
            totalCost: mosaicCacheTotalCost,
            hitCount: mosaicCacheHitCount,
            missCount: mosaicCacheMissCount,
            evictionCount: mosaicCacheEvictionCount
        )
    }

    init(image: NSImage) {
        self.image = image
        if let representation = image.representations.max(by: {
            $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh
        }), representation.pixelsWide > 0, representation.pixelsHigh > 0 {
            outputPixelSize = NSSize(width: representation.pixelsWide, height: representation.pixelsHigh)
        } else {
            outputPixelSize = image.size
        }
    }

    func renderedPNGData(annotations: [Annotation]) -> Data? {
        renderedBitmap(annotations: annotations)?.representation(using: .png, properties: [:])
    }

    func renderedCGImage(annotations: [Annotation]) -> CGImage? {
        renderedBitmap(annotations: annotations)?.cgImage
    }

    private func renderedBitmap(annotations: [Annotation]) -> NSBitmapImageRep? {
        let pixelWidth = max(1, Int(outputPixelSize.width.rounded()))
        let pixelHeight = max(1, Int(outputPixelSize.height.rounded()))
        guard image.size.width > 0,
              image.size.height > 0,
              let bitmap = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: pixelWidth,
                  pixelsHigh: pixelHeight,
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bitmapFormat: [],
                  bytesPerRow: 0,
                  bitsPerPixel: 0
              ),
              let bitmapContext = NSGraphicsContext(bitmapImageRep: bitmap)
        else {
            return nil
        }

        let scaleX = CGFloat(pixelWidth) / image.size.width
        let scaleY = CGFloat(pixelHeight) / image.size.height
        // Match AppKit's flipped image drawing to the annotations' top-left origin.
        bitmapContext.cgContext.translateBy(x: 0, y: CGFloat(pixelHeight))
        bitmapContext.cgContext.scaleBy(x: scaleX, y: -scaleY)
        let context = NSGraphicsContext(cgContext: bitmapContext.cgContext, flipped: true)
        let previousContext = NSGraphicsContext.current
        NSGraphicsContext.current = context
        NSGraphicsContext.saveGraphicsState()
        defer {
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.current = previousContext
        }

        context.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: image.size))
        for annotation in annotations where !annotation.isRedaction {
            draw(annotation, scale: 1, transform: { $0 }, showsMosaicBorder: false)
        }
        for annotation in annotations where annotation.isRedaction {
            draw(annotation, scale: 1, transform: { $0 }, showsMosaicBorder: false)
        }

        return bitmap
    }

    func draw(
        _ annotation: Annotation,
        scale: CGFloat,
        transform: (NSPoint) -> NSPoint,
        showsMosaicBorder: Bool = true
    ) {
        switch annotation {
        case let .stroke(points, color, width, alpha):
            guard points.count > 1 else { return }
            let path = NSBezierPath()
            path.move(to: transform(points[0]))
            for point in points.dropFirst() {
                path.line(to: transform(point))
            }
            color.withAlphaComponent(alpha).setStroke()
            path.lineWidth = width * scale
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()

        case let .shape(kind, start, end, color, width):
            color.setStroke()
            let start = transform(start)
            let end = transform(end)
            let rect = MarkupGeometry.normalizedRect(from: start, to: end)
            switch kind {
            case .arrow:
                drawArrow(from: start, to: end, color: color, width: width * scale)
            case .rectangle:
                let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
                path.lineWidth = width * scale
                path.stroke()
            case .ellipse:
                let path = NSBezierPath(ovalIn: rect)
                path.lineWidth = width * scale
                path.stroke()
            }

        case let .mosaic(start, end, strength):
            drawMosaic(
                sourceRect: MarkupGeometry.normalizedRect(from: start, to: end),
                destinationRect: MarkupGeometry.normalizedRect(from: transform(start), to: transform(end)),
                strength: strength,
                showsBorder: showsMosaicBorder,
                borderWidth: max(1, scale)
            )

        case let .redaction(start, end):
            NSColor.black.setFill()
            MarkupGeometry.normalizedRect(from: transform(start), to: transform(end)).fill()

        case let .marker(number, center, color):
            drawMarker(number: number, center: transform(center), radius: 14 * max(scale, 0.75), color: color)

        case let .checkmark(center, color):
            drawCheckmark(center: transform(center), radius: 14 * max(scale, 0.75), color: color)

        case let .text(text, origin, color, fontSize, background):
            let point = transform(origin)
            let font = NSFont.systemFont(ofSize: fontSize * scale, weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color
            ]
            let size = text.size(withAttributes: attributes)
            let rect = NSRect(origin: point, size: NSSize(width: size.width + 14, height: size.height + 10))
            if background {
                NSColor.textBackgroundColor.withAlphaComponent(0.86).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            }
            text.draw(in: rect.insetBy(dx: 7, dy: 5), withAttributes: attributes)
        }
    }

    private func drawMosaic(
        sourceRect: NSRect,
        destinationRect: NSRect,
        strength: CGFloat,
        showsBorder: Bool,
        borderWidth: CGFloat
    ) {
        guard sourceRect.width >= 2,
              sourceRect.height >= 2,
              destinationRect.width >= 2,
              destinationRect.height >= 2
        else {
            return
        }

        let blockSize = min(64, max(3, 4 + min(24, max(1, strength)) * 2.5))
        let pixelatedSize = NSSize(
            width: max(2, destinationRect.width / blockSize),
            height: max(2, destinationRect.height / blockSize)
        )
        let cacheKey = MosaicCacheKey(
            sourceX: Int((sourceRect.minX * 10).rounded()),
            sourceY: Int((sourceRect.minY * 10).rounded()),
            sourceWidth: Int((sourceRect.width * 10).rounded()),
            sourceHeight: Int((sourceRect.height * 10).rounded()),
            pixelWidth: Int(pixelatedSize.width.rounded()),
            pixelHeight: Int(pixelatedSize.height.rounded()),
            strength: Int((strength * 10).rounded())
        )
        let pixelated: NSImage
        if let cached = cachedMosaic(for: cacheKey) {
            pixelated = cached
        } else {
            let generated = NSImage(size: pixelatedSize)
            generated.lockFocusFlipped(true)
            NSGraphicsContext.current?.imageInterpolation = .low
            image.draw(
                in: NSRect(origin: .zero, size: pixelatedSize),
                from: imageSourceRect(from: sourceRect),
                operation: .copy,
                fraction: 1
            )
            generated.unlockFocus()
            cacheMosaic(generated, for: cacheKey, fallbackSize: pixelatedSize)
            pixelated = generated
        }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: destinationRect, xRadius: 4, yRadius: 4).addClip()
        NSGraphicsContext.current?.imageInterpolation = .none
        pixelated.draw(in: destinationRect, from: NSRect(origin: .zero, size: pixelatedSize), operation: .copy, fraction: 1)
        NSColor.black.withAlphaComponent(0.12).setFill()
        destinationRect.fill()
        if showsBorder {
            NSColor.white.withAlphaComponent(0.30).setStroke()
            let border = NSBezierPath(roundedRect: destinationRect, xRadius: 4, yRadius: 4)
            border.lineWidth = borderWidth
            border.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func cachedMosaic(for key: MosaicCacheKey) -> NSImage? {
        guard var entry = mosaicCache[key] else {
            mosaicCacheMissCount += 1
            return nil
        }

        mosaicCacheHitCount += 1
        entry.lastAccess = nextMosaicCacheAccessSequence()
        mosaicCache[key] = entry
        return entry.image
    }

    private func cacheMosaic(_ image: NSImage, for key: MosaicCacheKey, fallbackSize: NSSize) {
        let cost = decodedImageCost(image, fallbackSize: fallbackSize)
        guard cost <= Self.mosaicCacheCostLimit else { return }

        while mosaicCache.count >= Self.mosaicCacheEntryLimit
            || mosaicCacheTotalCost > Self.mosaicCacheCostLimit - cost
        {
            guard let leastRecentlyUsedKey = mosaicCache.min(by: {
                $0.value.lastAccess < $1.value.lastAccess
            })?.key,
                let removed = mosaicCache.removeValue(forKey: leastRecentlyUsedKey)
            else {
                break
            }
            mosaicCacheTotalCost -= removed.cost
            mosaicCacheEvictionCount += 1
        }

        let entry = MosaicCacheEntry(
            image: image,
            cost: cost,
            lastAccess: nextMosaicCacheAccessSequence()
        )
        mosaicCache[key] = entry
        mosaicCacheTotalCost += cost
    }

    private func decodedImageCost(_ image: NSImage, fallbackSize: NSSize) -> Int {
        let representation = image.representations.max(by: {
            $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh
        })
        let width = max(1, representation?.pixelsWide ?? Int(fallbackSize.width.rounded(.up)))
        let height = max(1, representation?.pixelsHigh ?? Int(fallbackSize.height.rounded(.up)))
        guard height <= Self.mosaicCacheCostLimit / 4,
              width <= Self.mosaicCacheCostLimit / (height * 4)
        else {
            return Self.mosaicCacheCostLimit + 1
        }
        return width * height * 4
    }

    private func nextMosaicCacheAccessSequence() -> UInt64 {
        if mosaicCacheAccessSequence == .max {
            let oldestFirst = mosaicCache.sorted {
                $0.value.lastAccess < $1.value.lastAccess
            }.map(\.key)
            for (offset, key) in oldestFirst.enumerated() {
                mosaicCache[key]?.lastAccess = UInt64(offset + 1)
            }
            mosaicCacheAccessSequence = UInt64(oldestFirst.count)
        }
        mosaicCacheAccessSequence += 1
        return mosaicCacheAccessSequence
    }

    private func imageSourceRect(from rect: NSRect) -> NSRect {
        NSRect(
            x: rect.minX,
            y: max(0, image.size.height - rect.maxY),
            width: rect.width,
            height: rect.height
        )
    }

    private func drawBadgeCircle(center: NSPoint, radius: CGFloat, color: NSColor) {
        let rect = NSRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
        NSColor.white.setStroke()
        let border = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
        border.lineWidth = max(1.5, radius * 0.12)
        border.stroke()
    }

    private func drawMarker(number: Int, center: NSPoint, radius: CGFloat, color: NSColor) {
        drawBadgeCircle(center: center, radius: radius, color: color)

        let text = "\(number)"
        let font = NSFont.monospacedDigitSystemFont(ofSize: max(12, radius * 0.95), weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
            withAttributes: attributes
        )
    }

    private func drawCheckmark(center: NSPoint, radius: CGFloat, color: NSColor) {
        drawBadgeCircle(center: center, radius: radius, color: color)

        let check = NSBezierPath()
        check.move(to: NSPoint(x: center.x - radius * 0.48, y: center.y + radius * 0.02))
        check.line(to: NSPoint(x: center.x - radius * 0.14, y: center.y + radius * 0.34))
        check.line(to: NSPoint(x: center.x + radius * 0.52, y: center.y - radius * 0.38))
        check.lineWidth = max(2.4, radius * 0.22)
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        check.stroke()
    }
}

private func drawArrow(from start: NSPoint, to end: NSPoint, color: NSColor, width: CGFloat) {
    color.setStroke()
    color.setFill()

    let path = NSBezierPath()
    path.move(to: start)
    path.line(to: end)
    path.lineWidth = width
    path.lineCapStyle = .round
    path.stroke()

    let angle = atan2(end.y - start.y, end.x - start.x)
    let headLength = max(width * 4.2, 14)
    let headAngle = CGFloat.pi / 7
    let p1 = NSPoint(
        x: end.x - headLength * cos(angle - headAngle),
        y: end.y - headLength * sin(angle - headAngle)
    )
    let p2 = NSPoint(
        x: end.x - headLength * cos(angle + headAngle),
        y: end.y - headLength * sin(angle + headAngle)
    )

    let head = NSBezierPath()
    head.move(to: end)
    head.line(to: p1)
    head.line(to: p2)
    head.close()
    head.fill()
}
