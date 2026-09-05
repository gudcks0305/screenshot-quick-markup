import AppKit
import Testing
@testable import ScreenshotQuickMarkup

@Suite("Annotation editing")
@MainActor
struct AnnotationEditingTests {
    @Test("Highlight styling preserves opacity and uses the inspector's width units")
    func highlightStyle() {
        let original = Annotation.stroke(points: [.zero, NSPoint(x: 10, y: 10)], color: .red, width: 11.2, alpha: 0.32)
        let changed = original.styled(color: .blue, width: 8, fontSize: 28)
        #expect(changed.tool == .highlighter)
        #expect(changed.editableWidth == 8)
        if case let .stroke(points, color, width, alpha) = changed {
            #expect(points.count == 2)
            #expect(color == .blue)
            #expect(width == 22.4)
            #expect(alpha == 0.32)
        } else { Issue.record("Expected a highlight stroke") }
    }

    @Test("Resize preserves the opposite corner and rejects inversion")
    func rectangleResize() {
        let original = Annotation.shape(kind: .rectangle, start: NSPoint(x: 80, y: 60), end: NSPoint(x: 20, y: 10), color: .red, width: 4)
        let resized = original.resized(handle: 0, to: NSPoint(x: 5, y: 6))
        #expect(resized.resizeHandles[0] == NSPoint(x: 5, y: 6))
        #expect(resized.resizeHandles[2] == NSPoint(x: 80, y: 60))
        let crossed = original.resized(handle: 0, to: NSPoint(x: 100, y: 100))
        #expect(crossed.resizeHandles[0] == NSPoint(x: 76, y: 56))
    }

    @Test("Arrow handles change endpoints without changing style")
    func arrowResize() {
        let original = Annotation.shape(kind: .arrow, start: NSPoint(x: 20, y: 10), end: NSPoint(x: 80, y: 60), color: .red, width: 4)
        let point = NSPoint(x: 110, y: 90)
        let resized = original.resized(handle: 1, to: point)
        #expect(resized.resizeHandles == [NSPoint(x: 20, y: 10), point])
        #expect(resized.color == .red)
        #expect(resized.editableWidth == 4)
    }

    @Test("Redaction cannot be made translucent by style controls")
    func redactionStyle() {
        let redaction = Annotation.redaction(start: .zero, end: NSPoint(x: 30, y: 40))
        #expect(redaction.styled(color: .clear, width: 1, fontSize: 12) == redaction)
        #expect(redaction.isRedaction)
        #expect(redaction.canResize)
        #expect(redaction.color == nil)
    }

    @Test("Culling bounds include minimum marker size and fixed text padding")
    func smallScaleBounds() {
        let marker = Annotation.marker(number: 1, center: NSPoint(x: 100, y: 100), color: .red)
        let rect = marker.displayBounds(scale: 0.1, offset: .zero)
        #expect(rect.contains(NSPoint(x: 19, y: 10)))
        let text = Annotation.text("", origin: .zero, color: .red, fontSize: 12, background: true)
        let textRect = text.displayBounds(scale: 0.1, offset: .zero)
        #expect(textRect.width >= 14)
        let arrow = Annotation.shape(kind: .arrow, start: .zero, end: NSPoint(x: 100, y: 0), color: .red, width: 1)
        #expect(arrow.displayBounds(scale: 0.1, offset: .zero).minY <= -14)
    }
}
