@preconcurrency import AppKit
import ScreenshotQuickMarkupCore

enum ShapeKind: Equatable {
    case arrow
    case rectangle
    case ellipse
}

enum Annotation: Equatable {
    case stroke(points: [NSPoint], color: NSColor, width: CGFloat, alpha: CGFloat)
    case shape(kind: ShapeKind, start: NSPoint, end: NSPoint, color: NSColor, width: CGFloat)
    case mosaic(start: NSPoint, end: NSPoint, strength: CGFloat)
    case redaction(start: NSPoint, end: NSPoint)
    case marker(number: Int, center: NSPoint, color: NSColor)
    case checkmark(center: NSPoint, color: NSColor)
    case text(String, origin: NSPoint, color: NSColor, fontSize: CGFloat, background: Bool)
}

extension Annotation {
    var bounds: NSRect {
        switch self {
        case let .stroke(points, _, width, _):
            guard let first = points.first else { return .zero }
            var minX = first.x
            var maxX = first.x
            var minY = first.y
            var maxY = first.y
            for point in points.dropFirst() {
                minX = min(minX, point.x)
                maxX = max(maxX, point.x)
                minY = min(minY, point.y)
                maxY = max(maxY, point.y)
            }
            return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                .insetBy(dx: -width / 2, dy: -width / 2)
        case let .shape(kind, start, end, _, width):
            let padding: CGFloat = switch kind {
            case .arrow: max(width * 4.2, 14)
            case .rectangle, .ellipse: width / 2
            }
            return MarkupGeometry.normalizedRect(from: start, to: end).insetBy(dx: -padding, dy: -padding)
        case let .mosaic(start, end, _), let .redaction(start, end):
            return MarkupGeometry.normalizedRect(from: start, to: end)
        case let .marker(_, center, _), let .checkmark(center, _):
            return NSRect(x: center.x - 14, y: center.y - 14, width: 28, height: 28)
        case let .text(text, origin, _, fontSize, _):
            let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
            let size = text.size(withAttributes: [.font: font])
            return NSRect(origin: origin, size: NSSize(width: size.width + 14, height: size.height + 10))
        }
    }

    func hitTest(_ point: NSPoint, tolerance: CGFloat) -> Bool {
        switch self {
        case let .stroke(points, _, width, _):
            guard points.count > 1 else { return false }
            let threshold = max(tolerance, width / 2 + 3)
            for index in 1..<points.count where MarkupGeometry.distance(
                from: point,
                toSegmentFrom: points[index - 1],
                to: points[index]
            ) <= threshold {
                return true
            }
            return false
        case let .shape(kind, start, end, _, width):
            let threshold = max(tolerance, width / 2 + 3)
            switch kind {
            case .arrow:
                return MarkupGeometry.distance(from: point, toSegmentFrom: start, to: end)
                    <= threshold
                    || hypot(point.x - end.x, point.y - end.y) <= max(14, width * 4.2) + tolerance
            case .rectangle:
                let rect = MarkupGeometry.normalizedRect(from: start, to: end)
                let corners = [
                    NSPoint(x: rect.minX, y: rect.minY),
                    NSPoint(x: rect.maxX, y: rect.minY),
                    NSPoint(x: rect.maxX, y: rect.maxY),
                    NSPoint(x: rect.minX, y: rect.maxY)
                ]
                return corners.indices.contains { index in
                    MarkupGeometry.distance(
                        from: point,
                        toSegmentFrom: corners[index],
                        to: corners[(index + 1) % corners.count]
                    ) <= threshold
                }
            case .ellipse:
                let rect = MarkupGeometry.normalizedRect(from: start, to: end)
                let radiusX = max(rect.width / 2, 0.001)
                let radiusY = max(rect.height / 2, 0.001)
                let normalizedDistance = hypot(
                    (point.x - rect.midX) / radiusX,
                    (point.y - rect.midY) / radiusY
                )
                return abs(normalizedDistance - 1) * min(radiusX, radiusY) <= threshold
            }
        case let .marker(_, center, _), let .checkmark(center, _):
            return hypot(point.x - center.x, point.y - center.y) <= 14 + tolerance
        case .mosaic, .redaction, .text:
            return MarkupGeometry.contains(point, in: bounds, tolerance: tolerance)
        }
    }

    func translated(by delta: NSSize) -> Annotation {
        func move(_ point: NSPoint) -> NSPoint {
            NSPoint(x: point.x + delta.width, y: point.y + delta.height)
        }

        switch self {
        case let .stroke(points, color, width, alpha):
            return .stroke(points: points.map(move), color: color, width: width, alpha: alpha)
        case let .shape(kind, start, end, color, width):
            return .shape(kind: kind, start: move(start), end: move(end), color: color, width: width)
        case let .mosaic(start, end, strength):
            return .mosaic(start: move(start), end: move(end), strength: strength)
        case let .redaction(start, end):
            return .redaction(start: move(start), end: move(end))
        case let .marker(number, center, color):
            return .marker(number: number, center: move(center), color: color)
        case let .checkmark(center, color):
            return .checkmark(center: move(center), color: color)
        case let .text(text, origin, color, fontSize, background):
            return .text(text, origin: move(origin), color: color, fontSize: fontSize, background: background)
        }
    }

    var isRedaction: Bool {
        if case .redaction = self { return true }
        return false
    }

    var tool: MarkupTool {
        switch self {
        case let .stroke(_, _, _, alpha): return alpha < 1 ? .highlighter : .pen
        case let .shape(kind, _, _, _, _):
            switch kind {
            case .arrow: return .arrow
            case .rectangle: return .rectangle
            case .ellipse: return .ellipse
            }
        case .mosaic: return .mosaic
        case .redaction: return .redaction
        case .marker: return .marker
        case .checkmark: return .check
        case .text: return .text
        }
    }

    var color: NSColor? {
        switch self {
        case let .stroke(_, color, _, _), let .shape(_, _, _, color, _),
             let .marker(_, _, color), let .checkmark(_, color), let .text(_, _, color, _, _):
            return color
        case .mosaic, .redaction: return nil
        }
    }

    var editableWidth: CGFloat? {
        switch self {
        case let .stroke(_, _, width, alpha): return width / (alpha < 1 ? 2.8 : 1)
        case let .shape(_, _, _, _, width): return width
        case let .mosaic(_, _, strength): return strength
        default: return nil
        }
    }

    var fontSize: CGFloat? {
        if case let .text(_, _, _, size, _) = self { return size }
        return nil
    }

    func styled(color: NSColor, width: CGFloat, fontSize: CGFloat) -> Annotation {
        switch self {
        case let .stroke(points, _, _, alpha):
            return .stroke(points: points, color: color, width: width * (alpha < 1 ? 2.8 : 1), alpha: alpha)
        case let .shape(kind, start, end, _, _):
            return .shape(kind: kind, start: start, end: end, color: color, width: width)
        case let .mosaic(start, end, _): return .mosaic(start: start, end: end, strength: width)
        case let .marker(number, center, _): return .marker(number: number, center: center, color: color)
        case let .checkmark(center, _): return .checkmark(center: center, color: color)
        case let .text(text, origin, _, _, background):
            return .text(text, origin: origin, color: color, fontSize: fontSize, background: background)
        case .redaction: return self
        }
    }

    var resizeHandles: [NSPoint] {
        switch self {
        case let .shape(.arrow, start, end, _, _): return [start, end]
        case let .shape(_, start, end, _, _), let .mosaic(start, end, _), let .redaction(start, end):
            let rect = MarkupGeometry.normalizedRect(from: start, to: end)
            return [NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: rect.maxX, y: rect.minY),
                    NSPoint(x: rect.maxX, y: rect.maxY), NSPoint(x: rect.minX, y: rect.maxY)]
        default: return []
        }
    }

    var canResize: Bool { !resizeHandles.isEmpty }

    func resized(handle: Int, to point: NSPoint) -> Annotation {
        let handles = resizeHandles
        guard handles.indices.contains(handle) else { return self }
        if case let .shape(.arrow, start, end, color, width) = self {
            let newStart = handle == 0 ? point : start
            let newEnd = handle == 1 ? point : end
            guard hypot(newEnd.x - newStart.x, newEnd.y - newStart.y) >= 4 else { return self }
            return .shape(kind: .arrow, start: newStart, end: newEnd, color: color, width: width)
        }
        let anchor = handles[(handle + 2) % 4]
        let corner = NSPoint(
            x: (handle == 0 || handle == 3) ? min(point.x, anchor.x - 4) : max(point.x, anchor.x + 4),
            y: (handle == 0 || handle == 1) ? min(point.y, anchor.y - 4) : max(point.y, anchor.y + 4)
        )
        let rect = MarkupGeometry.normalizedRect(from: anchor, to: corner)
        let start = rect.origin
        let end = NSPoint(x: rect.maxX, y: rect.maxY)
        switch self {
        case let .shape(kind, _, _, color, width):
            return .shape(kind: kind, start: start, end: end, color: color, width: width)
        case let .mosaic(_, _, strength): return .mosaic(start: start, end: end, strength: strength)
        case .redaction: return .redaction(start: start, end: end)
        default: return self
        }
    }

    /// Screen-space bounds include fixed-size badges, text padding, and antialiasing.
    func displayBounds(scale: CGFloat, offset: NSPoint) -> NSRect {
        func transform(_ point: NSPoint) -> NSPoint {
            NSPoint(x: offset.x + point.x * scale, y: offset.y + point.y * scale)
        }
        let rect: NSRect
        switch self {
        case let .marker(_, center, _), let .checkmark(center, _):
            let center = transform(center)
            let radius = 14 * max(scale, 0.75)
            rect = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        case let .text(text, origin, _, size, _):
            let font = NSFont.systemFont(ofSize: size * scale, weight: .semibold)
            let size = text.size(withAttributes: [.font: font])
            rect = NSRect(origin: transform(origin), size: NSSize(width: size.width + 14, height: size.height + 10))
        case let .shape(.arrow, start, end, _, width):
            let padding = max(width * scale * 4.2, 14)
            rect = MarkupGeometry.normalizedRect(from: transform(start), to: transform(end)).insetBy(dx: -padding, dy: -padding)
        default:
            let source = bounds
            rect = NSRect(x: offset.x + source.minX * scale, y: offset.y + source.minY * scale,
                          width: source.width * scale, height: source.height * scale)
        }
        return rect.insetBy(dx: -2, dy: -2)
    }
}
