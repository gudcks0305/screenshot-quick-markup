import CoreGraphics

/// Pure geometry operations shared by screenshot capture and markup editing.
public enum MarkupGeometry {
    /// Returns the rectangle spanning two points, regardless of drag direction.
    public static func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    /// Calculates the editor's fit scale while keeping small images useful to edit.
    public static func previewScale(for imageSize: CGSize, viewportSize: CGSize) -> CGFloat {
        let imageWidth = positiveFiniteValue(imageSize.width, fallback: 1)
        let imageHeight = positiveFiniteValue(imageSize.height, fallback: 1)
        let viewportWidth = finiteValue(viewportSize.width, fallback: 0)
        let viewportHeight = finiteValue(viewportSize.height, fallback: 0)

        let fitScale = min(
            (viewportWidth - 120) / imageWidth,
            (viewportHeight - 140) / imageHeight
        )
        let minimumUsefulScale = max(
            1,
            min(4, min(560 / imageWidth, 420 / imageHeight))
        )

        if fitScale >= minimumUsefulScale {
            return minimumUsefulScale
        }
        if fitScale >= 1 {
            return fitScale
        }
        return max(0.25, fitScale)
    }

    /// Converts a selection in bottom-left-origin screen points to top-left-origin image pixels.
    ///
    /// The result expands fractional pixels outward and is clamped to the image bounds.
    /// Returns `nil` when dimensions are invalid or the selection does not overlap the screen.
    public static func captureCropRect(
        selection: CGRect,
        screenSize: CGSize,
        imagePixelSize: CGSize
    ) -> CGRect? {
        guard isPositiveFinite(screenSize.width),
              isPositiveFinite(screenSize.height),
              isPositiveFinite(imagePixelSize.width),
              isPositiveFinite(imagePixelSize.height),
              isFinite(selection)
        else {
            return nil
        }

        let screenBounds = CGRect(origin: .zero, size: screenSize)
        let boundedSelection = selection.standardized.intersection(screenBounds)
        guard !boundedSelection.isNull, !boundedSelection.isEmpty else { return nil }

        let scaleX = imagePixelSize.width / screenSize.width
        let scaleY = imagePixelSize.height / screenSize.height
        let pixelRect = CGRect(
            x: boundedSelection.minX * scaleX,
            y: (screenSize.height - boundedSelection.maxY) * scaleY,
            width: boundedSelection.width * scaleX,
            height: boundedSelection.height * scaleY
        ).integral
        let imageBounds = CGRect(origin: .zero, size: imagePixelSize)
        let clampedRect = pixelRect.intersection(imageBounds)
        guard !clampedRect.isNull, !clampedRect.isEmpty else { return nil }
        return clampedRect
    }

    /// Returns the shortest Euclidean distance from a point to a finite line segment.
    public static func distance(from point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let segmentX = end.x - start.x
        let segmentY = end.y - start.y
        let lengthSquared = segmentX * segmentX + segmentY * segmentY
        guard lengthSquared > 0, lengthSquared.isFinite else {
            return hypot(point.x - start.x, point.y - start.y)
        }

        let projection = (
            (point.x - start.x) * segmentX
                + (point.y - start.y) * segmentY
        ) / lengthSquared
        let t = min(1, max(0, projection))
        let closest = CGPoint(x: start.x + t * segmentX, y: start.y + t * segmentY)
        return hypot(point.x - closest.x, point.y - closest.y)
    }

    /// Expands a standardized rectangle equally in every direction.
    public static func expanded(_ rect: CGRect, by amount: CGFloat) -> CGRect {
        rect.standardized.insetBy(dx: -max(0, amount), dy: -max(0, amount))
    }

    /// Tests a point against a rectangle with an optional hit tolerance.
    public static func contains(_ point: CGPoint, in rect: CGRect, tolerance: CGFloat = 0) -> Bool {
        expanded(rect, by: tolerance).contains(point)
    }

    /// Clamps a proposed translation without worsening existing overflow.
    ///
    /// Oversized content may move between aligning its leading and trailing edges.
    public static func clampedTranslationDelta(
        minimum: CGFloat,
        maximum: CGFloat,
        limit: CGFloat,
        proposed: CGFloat
    ) -> CGFloat {
        guard minimum.isFinite,
              maximum.isFinite,
              limit.isFinite,
              proposed.isFinite,
              limit >= 0,
              maximum >= minimum
        else {
            return 0
        }

        if maximum - minimum > limit {
            return min(-minimum, max(limit - maximum, proposed))
        }
        if minimum < 0 {
            return min(limit - maximum, max(0, proposed))
        }
        if maximum > limit {
            return min(0, max(-minimum, proposed))
        }
        return min(limit - maximum, max(-minimum, proposed))
    }

    private static func isFinite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.size.width.isFinite
            && rect.size.height.isFinite
    }

    private static func isPositiveFinite(_ value: CGFloat) -> Bool {
        value.isFinite && value > 0
    }

    private static func positiveFiniteValue(_ value: CGFloat, fallback: CGFloat) -> CGFloat {
        isPositiveFinite(value) ? value : fallback
    }

    private static func finiteValue(_ value: CGFloat, fallback: CGFloat) -> CGFloat {
        value.isFinite ? value : fallback
    }
}
