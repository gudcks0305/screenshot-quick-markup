@preconcurrency import AppKit
import ScreenshotQuickMarkupCore

final class CaptureOverlayWindowController: NSWindowController {
    var onCapture: ((NSImage) -> Void)?
    var onCancel: (() -> Void)?

    private let screenshot: CapturedScreenshot
    private let overlayView: CaptureOverlayView
    private var isFinishing = false

    init(screenshot: CapturedScreenshot) {
        self.screenshot = screenshot
        overlayView = CaptureOverlayView(frame: NSRect(origin: .zero, size: screenshot.screenFrame.size))

        let window = CaptureOverlayWindow(
            contentRect: screenshot.screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = overlayView
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.ignoresMouseEvents = false

        super.init(window: window)

        overlayView.onCancel = { [weak self] in
            self?.cancel()
        }
        overlayView.onComplete = { [weak self] selection in
            self?.complete(selection: selection)
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        log("Capture overlay shown.")
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        window?.makeFirstResponder(overlayView)
    }

    private func cancel() {
        guard !isFinishing else { return }
        log("Capture cancelled.")
        finishOverlay()
        onCancel?()
    }

    private func complete(selection: NSRect?) {
        guard !isFinishing else { return }
        if let selection {
            log("Capture selection: \(Int(selection.width))x\(Int(selection.height)).")
        } else {
            log("Capture full screen selected.")
        }
        guard let image = ScreenCapture.image(from: screenshot, selection: selection) else {
            log("Failed to crop selected screenshot.")
            cancel()
            return
        }
        finishOverlay()
        onCapture?(image)
    }

    private func finishOverlay() {
        isFinishing = true
        overlayView.onCancel = nil
        overlayView.onComplete = nil
        window?.ignoresMouseEvents = true
        window?.orderOut(nil)
        window?.contentView = nil
        close()
    }
}

private final class CaptureOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class CaptureOverlayView: NSView {
    var onComplete: ((NSRect?) -> Void)?
    var onCancel: (() -> Void)?

    private var dragStart: NSPoint?
    private var selectionRect: NSRect?

    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Screen capture area selector")
        setAccessibilityHelp("Drag to capture an area. Press Return for the display under the pointer, or Escape to cancel.")
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        if let selectionRect {
            let dimPath = NSBezierPath(rect: bounds)
            dimPath.append(NSBezierPath(roundedRect: selectionRect, xRadius: 5, yRadius: 5))
            dimPath.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.44).setFill()
            dimPath.fill()
            drawSelection(selectionRect)
        } else {
            NSColor.black.withAlphaComponent(0.34).setFill()
            bounds.fill()
        }

        drawHint()
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        selectionRect = NSRect(origin: dragStart ?? .zero, size: .zero)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        let current = convert(event.locationInWindow, from: nil)
        selectionRect = MarkupGeometry.normalizedRect(from: dragStart, to: current).intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let selectionRect, selectionRect.width >= 4, selectionRect.height >= 4 else {
            dragStart = nil
            self.selectionRect = nil
            needsDisplay = true
            return
        }
        onComplete?(selectionRect)
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 53:
            onCancel?()
        case 36, 76:
            onComplete?(nil)
        default:
            super.keyDown(with: event)
        }
    }

    private func drawHint() {
        let text = "Drag to capture    Return captures this display    Esc cancels"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attributes)
        let pill = NSRect(
            x: bounds.midX - (size.width + 34) / 2,
            y: bounds.maxY - 74,
            width: size.width + 34,
            height: 34
        )
        NSColor.black.withAlphaComponent(0.50).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 17, yRadius: 17).fill()
        NSColor.white.withAlphaComponent(0.16).setStroke()
        NSBezierPath(roundedRect: pill.insetBy(dx: 0.5, dy: 0.5), xRadius: 17, yRadius: 17).stroke()

        let rect = NSRect(
            x: bounds.midX - size.width / 2,
            y: pill.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        text.draw(in: rect, withAttributes: attributes)
    }

    private func drawSelection(_ rect: NSRect) {
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()

        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        NSColor.white.withAlphaComponent(0.95).setStroke()
        border.lineWidth = 1.5
        border.stroke()

        let accent = NSBezierPath(roundedRect: rect.insetBy(dx: 2.5, dy: 2.5), xRadius: 4, yRadius: 4)
        NSColor.systemBlue.setStroke()
        accent.lineWidth = 2
        accent.stroke()

        drawSizeBadge(for: rect)
    }

    private func drawSizeBadge(for rect: NSRect) {
        let text = "\(Int(rect.width)) x \(Int(rect.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attributes)
        var badge = NSRect(
            x: rect.minX,
            y: rect.minY - size.height - 18,
            width: size.width + 18,
            height: size.height + 10
        )
        if badge.minY < bounds.minY + 12 {
            badge.origin.y = rect.maxY + 8
        }
        if badge.maxX > bounds.maxX - 12 {
            badge.origin.x = bounds.maxX - badge.width - 12
        }

        NSColor.black.withAlphaComponent(0.68).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 7, yRadius: 7).fill()
        text.draw(
            in: badge.insetBy(dx: 9, dy: 5),
            withAttributes: attributes
        )
    }
}
