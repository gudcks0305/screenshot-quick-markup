import AppKit
import Testing
@testable import ScreenshotQuickMarkup

@Suite("Canvas editing", .serialized)
@MainActor
struct CanvasEditingTests {
    init() { _ = NSApplication.shared }

    @Test("Selection style changes are undoable and no-op updates add no history")
    func styleUndo() throws {
        let canvas = makeCanvas()
        canvas.tool = .rectangle
        try drag(canvas, from: NSPoint(x: 30, y: 30), to: NSPoint(x: 100, y: 90))
        let original = try #require(canvas.renderedPNGData())
        canvas.tool = .select
        try click(canvas, at: NSPoint(x: 60, y: 30))
        #expect(canvas.selectedAnnotation?.tool == .rectangle)
        canvas.updateSelectedStyle(color: .blue, width: 8, fontSize: 28)
        let updated = try #require(canvas.renderedPNGData())
        #expect(updated != original)
        canvas.updateSelectedStyle(color: .blue, width: 8, fontSize: 28)
        canvas.undo()
        #expect(canvas.renderedPNGData() == original)
        canvas.redo()
        #expect(canvas.renderedPNGData() == updated)
    }

    @Test("Resize is one undoable gesture and Escape restores the original")
    func resizeUndoAndCancel() throws {
        let canvas = makeCanvas()
        canvas.tool = .rectangle
        try drag(canvas, from: NSPoint(x: 30, y: 30), to: NSPoint(x: 100, y: 90))
        let original = try #require(canvas.renderedPNGData())
        canvas.tool = .select
        try click(canvas, at: NSPoint(x: 60, y: 30))
        try drag(canvas, from: NSPoint(x: 100, y: 90), to: NSPoint(x: 130, y: 110))
        #expect(canvas.selectedAnnotation?.resizeHandles[2] == NSPoint(x: 130, y: 110))
        canvas.undo()
        #expect(canvas.renderedPNGData() == original)
        try click(canvas, at: NSPoint(x: 60, y: 30))
        canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, NSPoint(x: 100, y: 90)))
        canvas.mouseDragged(with: try mouse(canvas, .leftMouseDragged, NSPoint(x: 130, y: 110)))
        canvas.keyDown(with: try key(53))
        #expect(canvas.renderedPNGData() == original)
        canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, NSPoint(x: 130, y: 110)))
        canvas.undo()
        #expect(canvas.renderedPNGData() != original)
    }

    @Test("Existing text is replaced, cancel preserves it, and undo restores it")
    func reeditText() throws {
        let canvas = makeCanvas()
        canvas.tool = .text
        try click(canvas, at: NSPoint(x: 20, y: 20))
        let field = try #require(canvas.subviews.compactMap { $0 as? NSTextField }.first)
        field.stringValue = "Before"
        let original = try #require(canvas.renderedPNGData())
        canvas.tool = .select
        try click(canvas, at: NSPoint(x: 30, y: 30))
        canvas.editSelectedText()
        let editor = try #require(canvas.subviews.compactMap { $0 as? NSTextField }.first)
        #expect(editor.stringValue == "Before")
        editor.stringValue = "After"
        let updated = try #require(canvas.renderedPNGData())
        #expect(updated != original)
        canvas.editSelectedText()
        let cancelled = try #require(canvas.subviews.compactMap { $0 as? NSTextField }.first)
        cancelled.stringValue = "Discard"
        #expect(canvas.control(cancelled, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(canvas.renderedPNGData() == updated)
        canvas.undo()
        #expect(canvas.renderedPNGData() == original)
    }

    @Test("Export lock rejects edits and async export cache invalidates after changes")
    func exportLockAndCache() async throws {
        let canvas = makeCanvas()
        let original = try #require(await canvas.renderedPNGDataAsync())
        #expect(await canvas.renderedPNGDataAsync() == original)
        canvas.tool = .marker
        canvas.isEditingEnabled = false
        try click(canvas, at: NSPoint(x: 70, y: 50))
        #expect(await canvas.renderedPNGDataAsync() == original)
        canvas.isEditingEnabled = true
        try click(canvas, at: NSPoint(x: 70, y: 50))
        #expect(await canvas.renderedPNGDataAsync() != original)
    }

    @Test("Small dirty regions skip unrelated completed annotations")
    func dirtyRegionCulling() throws {
        let canvas = makeCanvas()
        canvas.tool = .marker
        try click(canvas, at: NSPoint(x: 30, y: 30))
        try click(canvas, at: NSPoint(x: 130, y: 90))
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 200,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let previous = NSGraphicsContext.current
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.current = previous }
        canvas.draw(canvas.bounds)
        #expect(canvas.lastDrawnAnnotationCount == 2)
        canvas.draw(NSRect(x: 98, y: 68, width: 4, height: 4))
        #expect(canvas.lastDrawnAnnotationCount == 1)
    }

    @Test("Commands finish a drag before changing history or locking export")
    func gestureBoundaries() throws {
        let canvas = makeCanvas()
        canvas.tool = .rectangle
        try drag(canvas, from: NSPoint(x: 30, y: 30), to: NSPoint(x: 100, y: 90))
        let original = try #require(canvas.renderedPNGData())
        canvas.tool = .select
        try click(canvas, at: NSPoint(x: 60, y: 30))
        canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, NSPoint(x: 60, y: 30)))
        canvas.mouseDragged(with: try mouse(canvas, .leftMouseDragged, NSPoint(x: 75, y: 40)))
        canvas.undo()
        canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, NSPoint(x: 75, y: 40)))
        #expect(canvas.renderedPNGData() == original)

        try click(canvas, at: NSPoint(x: 60, y: 30))
        canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, NSPoint(x: 60, y: 30)))
        canvas.mouseDragged(with: try mouse(canvas, .leftMouseDragged, NSPoint(x: 75, y: 40)))
        canvas.isEditingEnabled = false
        let exported = try #require(canvas.renderedPNGData())
        canvas.tool = .pen
        #expect(canvas.tool == .select)
        canvas.isEditingEnabled = true
        canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, NSPoint(x: 75, y: 40)))
        #expect(canvas.renderedPNGData() == exported)
        canvas.undo()
        #expect(canvas.renderedPNGData() == original)
    }

    @Test("Resizing the viewport commits an active text editor before moving it")
    func viewportTextCommit() throws {
        let canvas = makeCanvas()
        canvas.tool = .text
        try click(canvas, at: NSPoint(x: 20, y: 20))
        let field = try #require(canvas.subviews.compactMap { $0 as? NSTextField }.first)
        field.stringValue = "Retain this text"
        canvas.updateCanvasSize(NSSize(width: 500, height: 400))
        #expect(canvas.subviews.compactMap { $0 as? NSTextField }.isEmpty)
        let original = try #require(canvas.renderedPNGData())
        canvas.undo()
        #expect(canvas.renderedPNGData() != original)
    }

    @Test("Appearance changes invalidate the cached PNG")
    func appearanceInvalidatesExport() async throws {
        let canvas = makeCanvas()
        canvas.appearance = NSAppearance(named: .aqua)
        canvas.tool = .text
        try click(canvas, at: NSPoint(x: 20, y: 20))
        let field = try #require(canvas.subviews.compactMap { $0 as? NSTextField }.first)
        field.stringValue = "Background"
        let light = try #require(await canvas.renderedPNGDataAsync())
        canvas.appearance = NSAppearance(named: .darkAqua)
        canvas.viewDidChangeEffectiveAppearance()
        let dark = try #require(await canvas.renderedPNGDataAsync())
        #expect(dark != light)
    }

    @Test("The real text field editor records typing for native Command-Z")
    func nativeFieldUndo() throws {
        let canvas = makeCanvas()
        let controller = ImageEditorWindowController(image: canvas.image)
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 300, height: 200))
        window.contentView = canvas
        defer { window.close() }
        canvas.tool = .text
        try click(canvas, at: NSPoint(x: 20, y: 20))
        let field = try #require(canvas.subviews.compactMap { $0 as? NSTextField }.first)
        let editor = try #require(field.currentEditor() as? NSTextView)
        #expect(editor.allowsUndo)
        let undoManager = try #require(editor.undoManager)
        undoManager.beginUndoGrouping()
        editor.insertText("Draft", replacementRange: NSRange(location: 0, length: 0))
        undoManager.endUndoGrouping()
        #expect(editor.string == "Draft")
        #expect(undoManager.canUndo)
        #expect(window.performKeyEquivalent(with: try key(6, modifiers: [.command])))
        #expect(editor.string.isEmpty)
    }

    private func makeCanvas() -> MarkupCanvasView {
        let image = NSImage(size: NSSize(width: 160, height: 120), flipped: true) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        let canvas = MarkupCanvasView(image: image)
        canvas.zoomActualSize(in: NSSize(width: 300, height: 200))
        return canvas
    }

    private func mouse(_ canvas: MarkupCanvasView, _ type: NSEvent.EventType, _ imagePoint: NSPoint) throws -> NSEvent {
        let point = NSPoint(x: imagePoint.x + 70, y: imagePoint.y + 40)
        return try #require(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func click(_ canvas: MarkupCanvasView, at point: NSPoint) throws {
        canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, point))
        canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, point))
    }

    private func drag(_ canvas: MarkupCanvasView, from start: NSPoint, to end: NSPoint) throws {
        canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, start))
        canvas.mouseDragged(with: try mouse(canvas, .leftMouseDragged, end))
        canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, end))
    }

    private func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
    }
}
