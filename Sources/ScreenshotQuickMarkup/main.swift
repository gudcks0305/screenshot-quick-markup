@preconcurrency import AppKit
import Carbon
import Carbon.HIToolbox
import CoreGraphics
import Darwin
import Foundation
import ScreenshotQuickMarkupCore

private let hotKeySignature = OSType(
    UInt32(UInt8(ascii: "S")) << 24
        | UInt32(UInt8(ascii: "Q")) << 16
        | UInt32(UInt8(ascii: "M")) << 8
        | UInt32(UInt8(ascii: "K"))
)

private enum SingleInstanceLock {
    static let descriptor: Int32 = {
        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.local.screenshot-quick-markup.lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return -1 }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            return -1
        }
        return descriptor
    }()

    static var isPrimary: Bool { descriptor >= 0 }
}

@main
@MainActor
private enum Main {
    static func main() {
        setbuf(stdout, nil)
        setbuf(stderr, nil)
        guard SingleInstanceLock.isPrimary else {
            log("Another Screenshot Quick Markup instance is already running.")
            return
        }
        _ = NSApplication.shared
        ScreenshotQuickMarkupApp().run()
    }
}

@MainActor
private final class ScreenshotQuickMarkupApp: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private let statusMenu = StatusMenu()
    private var hotKeyRef: EventHotKeyRef?
    private var captureOverlay: CaptureOverlayWindowController?
    private var editorWindows: [ImageEditorWindowController] = []

    func run() {
        NSApplication.shared.delegate = self
        NSApplication.shared.setActivationPolicy(.accessory)
        NSWindow.allowsAutomaticWindowTabbing = true

        statusMenu.configure(
            capture: { [weak self] in self?.beginCapture() },
            editClipboard: { [weak self] in self?.openClipboardEditor() },
            quit: { NSApplication.shared.terminate(nil) }
        )
        registerHotKey()

        log("ScreenshotQuickMarkup is running. Press Option+Shift+S.")
        NSApplication.shared.run()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !editorWindows.isEmpty, let editorWindow = newestVisibleEditorWindow() else { return true }
        updateActivationPolicyForEditors()
        NSApplication.shared.activate(ignoringOtherApps: true)
        if editorWindow.isMiniaturized {
            editorWindow.deminiaturize(nil)
        }
        editorWindow.makeKeyAndOrderFront(nil)
        return false
    }

    private func registerHotKey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let userData = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let eventRef, let userData else {
                    return OSStatus(eventNotHandledErr)
                }

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                guard status == noErr,
                      hotKeyID.signature == hotKeySignature,
                      hotKeyID.id == 1
                else {
                    return OSStatus(eventNotHandledErr)
                }

                let app = Unmanaged<ScreenshotQuickMarkupApp>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                Task { @MainActor in
                    app.beginCapture()
                }
                return noErr
            },
            1,
            &eventType,
            userData,
            nil
        )

        guard handlerStatus == noErr else {
            fputs("Failed to install hotkey handler: \(handlerStatus)\n", stderr)
            exit(1)
        }

        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: 1)
        let hotKeyStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_S),
            UInt32(optionKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard hotKeyStatus == noErr else {
            fputs("Failed to register Option+Shift+S: \(hotKeyStatus)\n", stderr)
            exit(1)
        }
    }

    private func beginCapture() {
        log("Capture requested.")
        guard captureOverlay == nil else { return }
        guard ScreenCapture.hasScreenCaptureAccess() else {
            log("Screen Recording permission is missing.")
            ScreenCapture.requestScreenCaptureAccess()
            showCapturePermissionAlert()
            return
        }

        guard let screenshot = ScreenCapture.captureMainDisplay() else {
            log("Capture failed before overlay.")
            showCapturePermissionAlert()
            return
        }

        let overlay = CaptureOverlayWindowController(screenshot: screenshot)
        overlay.onCancel = { [weak self] in
            self?.captureOverlay = nil
        }
        overlay.onCapture = { [weak self] image in
            log("Capture completed. Opening editor for \(Int(image.size.width))x\(Int(image.size.height)).")
            self?.captureOverlay = nil
            self?.openEditor(image: image)
        }
        captureOverlay = overlay
        overlay.show()
    }

    private func openClipboardEditor() {
        let pasteboard = NSPasteboard.general
        let imageData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
        guard let imageData, let image = NSImage(data: imageData) else {
            NSApplication.shared.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "No image on the clipboard"
            alert.informativeText = "Copy an image, then choose Mark Up Clipboard Image again."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        log("Opening clipboard image for markup.")
        openEditor(image: image)
    }

    private func openEditor(image: NSImage) {
        let editor = ImageEditorWindowController(image: image)
        editor.onClose = { [weak self, weak editor] in
            guard let self, let editor else { return }
            self.editorWindows.removeAll { $0 === editor }
            self.updateActivationPolicyForEditors()
        }
        let lastTabbedWindow = newestVisibleEditorWindow()
        editorWindows.append(editor)
        updateActivationPolicyForEditors()
        NSApplication.shared.activate(ignoringOtherApps: true)

        if let lastTabbedWindow, let newWindow = editor.window {
            lastTabbedWindow.addTabbedWindow(newWindow, ordered: .above)
            newWindow.makeKeyAndOrderFront(nil)
        } else {
            editor.show()
        }
        editor.focusCanvas()

        log("Editor window shown. Open editors: \(editorWindows.count).")
    }

    private func updateActivationPolicyForEditors() {
        NSApplication.shared.setActivationPolicy(editorWindows.isEmpty ? .accessory : .regular)
    }

    private func newestVisibleEditorWindow() -> NSWindow? {
        let windows = editorWindows.compactMap { $0.window }
        let preferredWindow = windows.first { $0.isVisible && !$0.isMiniaturized } ?? windows.last
        return preferredWindow?.tabbedWindows?.last ?? preferredWindow
    }

    private func showCapturePermissionAlert() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission needed"
        alert.informativeText = "macOS is returning only the wallpaper because this app does not have Screen Recording permission. Enable it in System Settings > Privacy & Security > Screen Recording, then restart Screenshot Quick Markup."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

@MainActor
private final class StatusMenu {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    func configure(
        capture: @escaping () -> Void,
        editClipboard: @escaping () -> Void,
        quit: @escaping () -> Void
    ) {
        statusItem.button?.image = NSImage(
            systemSymbolName: "camera.viewfinder",
            accessibilityDescription: "Screenshot Quick Markup"
        )

        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Capture Area  ⌥⇧S", action: capture))
        menu.addItem(ClosureMenuItem(title: "Mark Up Clipboard Image", action: editClipboard))
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Quit", action: quit))
        statusItem.menu = menu
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(runHandler), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func runHandler() {
        handler()
    }
}

private struct CapturedScreenshot {
    let image: CGImage
    let screenFrame: NSRect
}

private enum ScreenCapture {
    static func hasScreenCaptureAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestScreenCaptureAccess() {
        _ = CGRequestScreenCaptureAccess()
    }

    static func captureMainDisplay() -> CapturedScreenshot? {
        guard let screen = screenUnderMouse(),
              let displayID = displayID(for: screen),
              let image = CGDisplayCreateImage(displayID)
        else {
            return nil
        }

        return CapturedScreenshot(image: image, screenFrame: screen.frame)
    }

    private static func screenUnderMouse() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    static func image(from screenshot: CapturedScreenshot, selection: NSRect?) -> NSImage? {
        let fullImage = screenshot.image
        guard let selection, selection.width >= 4, selection.height >= 4 else {
            return NSImage(cgImage: fullImage, size: screenshot.screenFrame.size)
        }

        guard let cropRect = MarkupGeometry.captureCropRect(
            selection: selection,
            screenSize: screenshot.screenFrame.size,
            imagePixelSize: CGSize(width: fullImage.width, height: fullImage.height)
        ) else {
            return nil
        }

        guard let cropped = fullImage.cropping(to: cropRect) else { return nil }
        return NSImage(cgImage: cropped, size: selection.size)
    }
}

private final class CaptureOverlayWindowController: NSWindowController {
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
        selectionRect = normalizedRect(from: dragStart, to: current).intersection(bounds)
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

private enum MarkupTool: String, CaseIterable {
    case select
    case pen
    case highlighter
    case arrow
    case rectangle
    case ellipse
    case mosaic
    case marker
    case check
    case text

    var symbolName: String {
        switch self {
        case .select: return "cursorarrow"
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .mosaic: return "checkerboard.rectangle"
        case .marker: return "mappin.circle"
        case .check: return "checkmark.circle"
        case .text: return "textformat"
        }
    }

    var title: String {
        switch self {
        case .select: return "Select"
        case .pen: return "Pen"
        case .highlighter: return "Highlight"
        case .arrow: return "Arrow"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .mosaic: return "Blur"
        case .marker: return "Marker"
        case .check: return "Check"
        case .text: return "Text"
        }
    }

    var shortcut: String {
        switch self {
        case .select: return "V"
        case .pen: return "P"
        case .highlighter: return "H"
        case .arrow: return "A"
        case .rectangle: return "R"
        case .ellipse: return "O"
        case .mosaic: return "B"
        case .marker: return "N"
        case .check: return "K"
        case .text: return "T"
        }
    }
}

private enum ShapeKind {
    case arrow
    case rectangle
    case ellipse
}

private enum Annotation {
    case stroke(points: [NSPoint], color: NSColor, width: CGFloat, alpha: CGFloat)
    case shape(kind: ShapeKind, start: NSPoint, end: NSPoint, color: NSColor, width: CGFloat)
    case mosaic(start: NSPoint, end: NSPoint, strength: CGFloat)
    case marker(number: Int, center: NSPoint, color: NSColor)
    case checkmark(center: NSPoint, color: NSColor)
    case text(String, origin: NSPoint, color: NSColor, fontSize: CGFloat, background: Bool)
}

private extension Annotation {
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
            return normalizedRect(from: start, to: end).insetBy(dx: -padding, dy: -padding)
        case let .mosaic(start, end, _):
            return normalizedRect(from: start, to: end)
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
                let rect = normalizedRect(from: start, to: end)
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
                let rect = normalizedRect(from: start, to: end)
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
        case .mosaic, .text:
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
        case let .marker(number, center, color):
            return .marker(number: number, center: move(center), color: color)
        case let .checkmark(center, color):
            return .checkmark(center: move(center), color: color)
        case let .text(text, origin, color, fontSize, background):
            return .text(text, origin: move(origin), color: color, fontSize: fontSize, background: background)
        }
    }
}

private enum ZoomMode {
    case fit
    case fixed(CGFloat)
}

private enum EditorPreferences {
    private static let toolKey = "editor.lastTool"
    private static let colorKey = "editor.lastColor"
    private static let widthKey = "editor.lastWidth"
    private static let fontSizeKey = "editor.lastFontSize"

    static var tool: MarkupTool {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: toolKey),
                  let tool = MarkupTool(rawValue: rawValue)
            else {
                return .pen
            }
            return tool
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: toolKey)
        }
    }

    static var color: NSColor {
        get {
            guard let components = UserDefaults.standard.array(forKey: colorKey) as? [Double],
                  components.count == 4
            else {
                return .systemRed
            }
            return NSColor(
                calibratedRed: CGFloat(components[0]),
                green: CGFloat(components[1]),
                blue: CGFloat(components[2]),
                alpha: CGFloat(components[3])
            )
        }
        set {
            guard let color = newValue.usingColorSpace(.deviceRGB) else { return }
            UserDefaults.standard.set(
                [
                    Double(color.redComponent),
                    Double(color.greenComponent),
                    Double(color.blueComponent),
                    Double(color.alphaComponent)
                ],
                forKey: colorKey
            )
        }
    }

    static var width: CGFloat {
        get {
            let storedWidth = UserDefaults.standard.double(forKey: widthKey)
            guard storedWidth > 0 else { return 4 }
            return min(24, max(1, CGFloat(storedWidth)))
        }
        set {
            UserDefaults.standard.set(Double(min(24, max(1, newValue))), forKey: widthKey)
        }
    }

    static var fontSize: CGFloat {
        get {
            let storedSize = UserDefaults.standard.double(forKey: fontSizeKey)
            guard storedSize > 0 else { return 28 }
            return min(96, max(12, CGFloat(storedSize)))
        }
        set {
            UserDefaults.standard.set(Double(min(96, max(12, newValue))), forKey: fontSizeKey)
        }
    }
}

private final class ImageEditorWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let editorViewController: ImageEditorViewController
    private static let titleTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(image: NSImage) {
        editorViewController = ImageEditorViewController(image: image)
        let windowSize = editorWindowSize(for: image.size)
        let window = EditorWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let captureTime = Self.titleTimeFormatter.string(from: Date())
        window.title = "Screenshot · \(captureTime) · \(Int(image.size.width)) × \(Int(image.size.height))"
        window.minSize = NSSize(width: 900, height: 620)
        window.level = .normal
        window.tabbingIdentifier = "ScreenshotQuickMarkup.Editor"
        window.tabbingMode = .preferred
        window.isReleasedWhenClosed = false
        window.center()
        window.contentViewController = editorViewController
        super.init(window: window)
        window.delegate = self
        window.onCommandSave = { [weak self] in self?.saveImage() }
        window.onCommandCopy = { [weak self] in _ = self?.copyImageToClipboard() }
        window.onUndo = { [weak self] in self?.editorViewController.undo() }
        window.onRedo = { [weak self] in self?.editorViewController.redo() }
        window.onToolShortcut = { [weak self] tool in
            self?.editorViewController.activateTool(tool)
        }
        editorViewController.onCopy = { [weak self] in
            _ = self?.copyImageToClipboard()
        }
        editorViewController.onSave = { [weak self] in self?.saveImage() }
        editorViewController.onDone = { [weak self] in
            guard let self, self.copyImageToClipboard() else { return }
            self.window?.close()
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        focusCanvas()
    }

    func focusCanvas() {
        editorViewController.focusCanvas()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    @discardableResult
    private func copyImageToClipboard() -> Bool {
        guard let data = editorViewController.renderedPNGData() else {
            editorViewController.showStatus("Couldn’t render image", isError: true)
            return false
        }
        let item = NSPasteboardItem()
        guard item.setData(data, forType: .png) else {
            editorViewController.showStatus("Couldn’t prepare image for copying", isError: true)
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            editorViewController.showStatus("Couldn’t copy image", isError: true)
            return false
        }
        NSSound(named: "Pop")?.play()
        editorViewController.showStatus("Copied to clipboard")
        log("Copied edited screenshot to clipboard.")
        return true
    }

    private func saveImage() {
        guard let data = editorViewController.renderedPNGData() else {
            editorViewController.showStatus("Couldn’t render image", isError: true)
            return
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "screenshot-\(Int(Date().timeIntervalSince1970)).png"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
            editorViewController.showStatus("Saved \(url.lastPathComponent)")
            NSSound(named: "Pop")?.play()
        } catch {
            log("Failed to save screenshot: \(error.localizedDescription)")
            editorViewController.showStatus("Save failed: \(error.localizedDescription)", isError: true)
        }
    }
}

private func editorWindowSize(for imageSize: NSSize) -> NSSize {
    let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let maxSize = NSSize(
        width: max(900, screenFrame.width * 0.82),
        height: max(640, screenFrame.height * 0.82)
    )
    let minSize = NSSize(width: 920, height: 680)
    let preferredScale = calculatePreviewScale(for: imageSize, viewportSize: maxSize)

    return NSSize(
        width: min(maxSize.width, max(minSize.width, imageSize.width * preferredScale + 160)),
        height: min(maxSize.height, max(minSize.height, imageSize.height * preferredScale + 180))
    )
}

private final class EditorWindow: NSWindow {
    var onCommandSave: (() -> Void)?
    var onCommandCopy: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onToolShortcut: ((MarkupTool) -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           !(firstResponder is NSTextView),
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let character = event.charactersIgnoringModifiers?.uppercased(),
           let tool = MarkupTool.allCases.first(where: { $0.shortcut == character }) {
            onToolShortcut?(tool)
            return
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }

        if firstResponder is NSTextView, [6, 7, 8, 9].contains(Int(event.keyCode)) {
            return super.performKeyEquivalent(with: event)
        }

        switch Int(event.keyCode) {
        case 13:
            performClose(nil)
            return true
        case 1:
            onCommandSave?()
            return true
        case 8:
            onCommandCopy?()
            return true
        case 6:
            if event.modifierFlags.contains(.shift) {
                onRedo?()
            } else {
                onUndo?()
            }
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}

private final class ImageEditorViewController: NSViewController {
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onDone: (() -> Void)?

    private let image: NSImage
    private let canvasView: MarkupCanvasView
    private let toolButtons = NSStackView()
    private let colorSwatches = NSStackView()
    private let zoomButtons = NSStackView()
    private let historyButtons = NSStackView()
    private let scrollView = NSScrollView()
    private let colorWell = NSColorWell()
    private let colorControls = NSStackView()
    private let widthControls = NSStackView()
    private let fontControls = NSStackView()
    private let widthLabel = NSTextField(labelWithString: "Size")
    private let widthValueLabel = NSTextField(labelWithString: "4")
    private let widthSlider = NSSlider(value: 4, minValue: 1, maxValue: 24, target: nil, action: nil)
    private let fontSizeSlider = NSSlider(value: 28, minValue: 12, maxValue: 96, target: nil, action: nil)
    private let fontSizeValueLabel = NSTextField(labelWithString: "28")
    private let statusLabel = NSTextField(labelWithString: "")
    private lazy var undoButton = compactButton(
        symbolName: "arrow.uturn.backward",
        action: #selector(undoTapped),
        tooltip: "Undo (⌘Z)"
    )
    private lazy var redoButton = compactButton(
        symbolName: "arrow.uturn.forward",
        action: #selector(redoTapped),
        tooltip: "Redo (⌘⇧Z)"
    )
    private lazy var deleteButton = compactButton(
        symbolName: "trash",
        action: #selector(deleteTapped),
        tooltip: "Delete selected annotation (⌫)"
    )

    init(image: NSImage) {
        self.image = image
        canvasView = MarkupCanvasView(image: image)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let toolbar = NSView()
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        toolbar.layer?.borderColor = NSColor.separatorColor.cgColor
        toolbar.layer?.borderWidth = 1
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        toolButtons.orientation = .horizontal
        toolButtons.spacing = 4
        toolButtons.translatesAutoresizingMaskIntoConstraints = false

        for tool in MarkupTool.allCases {
            let button = ToolButton(tool: tool)
            button.target = self
            button.action = #selector(selectTool(_:))
            button.toolTip = "\(tool.title) (\(tool.shortcut))"
            toolButtons.addArrangedSubview(button)
        }

        colorSwatches.orientation = .horizontal
        colorSwatches.spacing = 4
        colorSwatches.translatesAutoresizingMaskIntoConstraints = false
        let colors: [(String, NSColor)] = [
            ("Red", .systemRed),
            ("Yellow", .systemYellow),
            ("Green", .systemGreen),
            ("Blue", .systemBlue),
            ("Purple", .systemPurple),
            ("White", .white),
            ("Black", .black)
        ]
        for (name, color) in colors {
            let swatch = ColorSwatchButton(name: name, color: color)
            swatch.target = self
            swatch.action = #selector(selectSwatch(_:))
            colorSwatches.addArrangedSubview(swatch)
        }

        colorWell.color = EditorPreferences.color
        colorWell.target = self
        colorWell.action = #selector(styleChanged)
        colorWell.toolTip = "Custom color"
        colorWell.setAccessibilityLabel("Custom annotation color")
        colorWell.translatesAutoresizingMaskIntoConstraints = false

        configureOptionLabel(widthLabel)
        configureValueLabel(widthValueLabel)
        configureValueLabel(fontSizeValueLabel)

        widthSlider.doubleValue = Double(EditorPreferences.width)
        widthSlider.target = self
        widthSlider.action = #selector(styleChanged)
        widthSlider.toolTip = "Stroke width / blur strength"
        widthSlider.setAccessibilityLabel("Annotation size")
        widthSlider.translatesAutoresizingMaskIntoConstraints = false

        fontSizeSlider.doubleValue = Double(EditorPreferences.fontSize)
        fontSizeSlider.target = self
        fontSizeSlider.action = #selector(styleChanged)
        fontSizeSlider.toolTip = "Text size"
        fontSizeSlider.setAccessibilityLabel("Text size")
        fontSizeSlider.translatesAutoresizingMaskIntoConstraints = false

        configureOptionStack(colorControls, views: [optionLabel("Color"), colorSwatches, colorWell])
        configureOptionStack(widthControls, views: [widthLabel, widthSlider, widthValueLabel])
        configureOptionStack(fontControls, views: [optionLabel("Text"), fontSizeSlider, fontSizeValueLabel])

        zoomButtons.orientation = .horizontal
        zoomButtons.spacing = 4
        zoomButtons.translatesAutoresizingMaskIntoConstraints = false
        zoomButtons.addArrangedSubview(zoomButton(title: "-", action: #selector(zoomOutTapped), tooltip: "Zoom out"))
        zoomButtons.addArrangedSubview(zoomButton(title: "100%", action: #selector(actualSizeTapped), tooltip: "Actual size"))
        zoomButtons.addArrangedSubview(zoomButton(title: "Fit", action: #selector(fitTapped), tooltip: "Fit to window"))
        zoomButtons.addArrangedSubview(zoomButton(title: "+", action: #selector(zoomInTapped), tooltip: "Zoom in"))

        historyButtons.orientation = .horizontal
        historyButtons.spacing = 4
        historyButtons.translatesAutoresizingMaskIntoConstraints = false
        historyButtons.addArrangedSubview(undoButton)
        historyButtons.addArrangedSubview(redoButton)
        historyButtons.addArrangedSubview(deleteButton)

        let copyButton = toolbarButton(
            title: "Copy",
            symbolName: "doc.on.doc",
            action: #selector(copyTapped),
            width: 78
        )
        let saveButton = toolbarButton(
            title: "Save",
            symbolName: "square.and.arrow.down",
            action: #selector(saveTapped),
            width: 76
        )
        let doneButton = toolbarButton(
            title: "Copy & Close",
            symbolName: "checkmark.circle.fill",
            action: #selector(doneTapped),
            width: 128
        )
        doneButton.contentTintColor = .controlAccentColor
        doneButton.toolTip = "Copy edited image and close window"

        let topSpacer = flexibleSpacer()
        let topRow = NSStackView(views: [toolButtons, topSpacer, historyButtons, copyButton, saveButton, doneButton])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 8
        topRow.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .right
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.setAccessibilityLabel("Editor status")
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let bottomSpacer = flexibleSpacer()
        let bottomRow = NSStackView(views: [colorControls, widthControls, fontControls, zoomButtons, bottomSpacer, statusLabel])
        bottomRow.orientation = .horizontal
        bottomRow.alignment = .centerY
        bottomRow.spacing = 14
        bottomRow.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = canvasView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = .black
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(toolbar)
        toolbar.addSubview(topRow)
        toolbar.addSubview(bottomRow)
        root.addSubview(scrollView)

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 94),

            topRow.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 12),
            topRow.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -12),
            topRow.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: 8),
            topRow.heightAnchor.constraint(equalToConstant: 34),

            bottomRow.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 14),
            bottomRow.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -14),
            bottomRow.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 8),
            bottomRow.heightAnchor.constraint(equalToConstant: 30),

            colorWell.widthAnchor.constraint(equalToConstant: 32),
            colorWell.heightAnchor.constraint(equalToConstant: 24),
            widthSlider.widthAnchor.constraint(equalToConstant: 86),
            widthValueLabel.widthAnchor.constraint(equalToConstant: 24),
            fontSizeSlider.widthAnchor.constraint(equalToConstant: 86),
            fontSizeValueLabel.widthAnchor.constraint(equalToConstant: 28),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),

            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        view = root
        canvasView.onHistoryChanged = { [weak self] canUndo, canRedo in
            self?.updateHistoryControls(canUndo: canUndo, canRedo: canRedo)
        }
        canvasView.onSelectionChanged = { [weak self] hasSelection in
            self?.deleteButton.isEnabled = hasSelection
        }
        canvasView.onToolShortcut = { [weak self] tool in
            self?.setTool(tool)
        }
        setTool(EditorPreferences.tool, focusCanvas: false)
        updateSelectedToolButtons()
        styleChanged()
        updateHistoryControls(canUndo: false, canRedo: false)
        deleteButton.isEnabled = false
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        canvasView.updateCanvasSize(scrollView.contentView.bounds.size)
    }

    func undo() {
        canvasView.undo()
    }

    func redo() {
        canvasView.redo()
    }

    func renderedPNGData() -> Data? {
        canvasView.renderedPNGData()
    }

    func focusCanvas() {
        loadViewIfNeeded()
        view.window?.makeFirstResponder(canvasView)
    }

    func activateTool(_ tool: MarkupTool) {
        loadViewIfNeeded()
        setTool(tool)
    }

    func showStatus(_ message: String, isError: Bool = false) {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(clearStatus), object: nil)
        statusLabel.stringValue = message
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
        statusLabel.toolTip = message
        perform(#selector(clearStatus), with: nil, afterDelay: isError ? 5 : 2.5)
    }

    @objc private func selectTool(_ sender: ToolButton) {
        setTool(sender.tool)
    }

    @objc private func styleChanged() {
        canvasView.currentColor = colorWell.color
        canvasView.currentWidth = CGFloat(widthSlider.doubleValue)
        canvasView.currentFontSize = CGFloat(fontSizeSlider.doubleValue)
        EditorPreferences.color = colorWell.color
        EditorPreferences.width = CGFloat(widthSlider.doubleValue)
        EditorPreferences.fontSize = CGFloat(fontSizeSlider.doubleValue)
        updateStyleLabels()
        updateSelectedColorSwatches()
    }

    @objc private func selectSwatch(_ sender: ColorSwatchButton) {
        colorWell.color = sender.color
        styleChanged()
    }

    @objc private func copyTapped() {
        onCopy?()
    }

    @objc private func saveTapped() {
        onSave?()
    }

    @objc private func doneTapped() {
        onDone?()
    }

    @objc private func undoTapped() {
        undo()
    }

    @objc private func redoTapped() {
        redo()
    }

    @objc private func deleteTapped() {
        canvasView.deleteSelectedAnnotation()
    }

    @objc private func zoomOutTapped() {
        canvasView.zoomOut(in: scrollView.contentView.bounds.size)
    }

    @objc private func actualSizeTapped() {
        canvasView.zoomActualSize(in: scrollView.contentView.bounds.size)
    }

    @objc private func fitTapped() {
        canvasView.zoomToFit(in: scrollView.contentView.bounds.size)
    }

    @objc private func zoomInTapped() {
        canvasView.zoomIn(in: scrollView.contentView.bounds.size)
    }

    @objc private func clearStatus() {
        statusLabel.stringValue = ""
        statusLabel.toolTip = nil
    }

    private func toolbarButton(
        title: String,
        symbolName: String,
        action: Selector,
        width: CGFloat
    ) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: width),
            button.heightAnchor.constraint(equalToConstant: 32)
        ])
        return button
    }

    private func compactButton(symbolName: String, action: Selector, tooltip: String) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip)
        button.imagePosition = .imageOnly
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 32),
            button.heightAnchor.constraint(equalToConstant: 32)
        ])
        return button
    }

    private func zoomButton(title: String, action: Selector, tooltip: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 28),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: title == "100%" ? 46 : 32)
        ])
        return button
    }

    private func updateSelectedToolButtons() {
        for case let button as ToolButton in toolButtons.arrangedSubviews {
            button.isSelectedTool = button.tool == canvasView.tool
        }
        updateStyleLabels()
    }

    private func updateStyleLabels() {
        widthLabel.stringValue = canvasView.tool == .mosaic ? "Blur" : "Size"
        widthValueLabel.stringValue = "\(Int(widthSlider.doubleValue.rounded()))"
        fontSizeValueLabel.stringValue = "\(Int(fontSizeSlider.doubleValue.rounded()))"

        switch canvasView.tool {
        case .select:
            colorControls.isHidden = true
            widthControls.isHidden = true
            fontControls.isHidden = true
        case .mosaic:
            colorControls.isHidden = true
            widthControls.isHidden = false
            fontControls.isHidden = true
        case .text:
            colorControls.isHidden = false
            widthControls.isHidden = true
            fontControls.isHidden = false
        case .marker, .check:
            colorControls.isHidden = false
            widthControls.isHidden = true
            fontControls.isHidden = true
        case .pen, .highlighter, .arrow, .rectangle, .ellipse:
            colorControls.isHidden = false
            widthControls.isHidden = false
            fontControls.isHidden = true
        }
    }

    private func setTool(_ tool: MarkupTool, focusCanvas: Bool = true) {
        canvasView.tool = tool
        EditorPreferences.tool = tool
        updateSelectedToolButtons()
        if focusCanvas {
            view.window?.makeFirstResponder(canvasView)
        }
        if tool == .select {
            showStatus("Click an annotation to move or delete it")
        }
    }

    private func updateHistoryControls(canUndo: Bool, canRedo: Bool) {
        undoButton.isEnabled = canUndo
        redoButton.isEnabled = canRedo
    }

    private func updateSelectedColorSwatches() {
        for case let swatch as ColorSwatchButton in colorSwatches.arrangedSubviews {
            swatch.isSelectedColor = swatch.color.isEqual(colorWell.color)
        }
    }

    private func configureOptionStack(_ stack: NSStackView, views: [NSView]) {
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        for view in views {
            stack.addArrangedSubview(view)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
    }

    private func optionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        configureOptionLabel(label)
        return label
    }

    private func configureOptionLabel(_ label: NSTextField) {
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureValueLabel(_ label: NSTextField) {
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .left
        label.translatesAutoresizingMaskIntoConstraints = false
    }

    private func flexibleSpacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return spacer
    }
}

private final class ToolButton: NSButton {
    let tool: MarkupTool

    var isSelectedTool = false {
        didSet {
            wantsLayer = true
            layer?.cornerRadius = 6
            layer?.backgroundColor = isSelectedTool
                ? NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
                : NSColor.clear.cgColor
            state = isSelectedTool ? .on : .off
            setAccessibilityValue(isSelectedTool ? "Selected" : "Not selected")
        }
    }

    init(tool: MarkupTool) {
        self.tool = tool
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: tool.symbolName, accessibilityDescription: tool.title)
        imagePosition = .imageOnly
        bezelStyle = .rounded
        isBordered = false
        title = ""
        setButtonType(.toggle)
        setAccessibilityLabel("\(tool.title) tool")
        setAccessibilityHelp("Keyboard shortcut \(tool.shortcut)")
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 30),
            heightAnchor.constraint(equalToConstant: 30)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }
}

private final class ColorSwatchButton: NSButton {
    let color: NSColor

    var isSelectedColor = false {
        didSet {
            layer?.borderWidth = isSelectedColor ? 3 : 1
            layer?.borderColor = isSelectedColor
                ? NSColor.controlAccentColor.cgColor
                : NSColor.separatorColor.cgColor
            state = isSelectedColor ? .on : .off
            setAccessibilityValue(isSelectedColor ? "Selected" : "Not selected")
        }
    }

    init(name: String, color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.toggle)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = color.cgColor
        toolTip = "Use \(name.lowercased())"
        setAccessibilityLabel("\(name) annotation color")
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 18),
            heightAnchor.constraint(equalToConstant: 18)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }
}

private final class MarkupCanvasView: NSView, NSTextFieldDelegate {
    var onHistoryChanged: ((Bool, Bool) -> Void)?
    var onSelectionChanged: ((Bool) -> Void)?
    var onToolShortcut: ((MarkupTool) -> Void)?

    let image: NSImage
    var tool: MarkupTool = .pen {
        didSet {
            if tool != .text {
                commitActiveText()
            }
            if tool != .select {
                setSelectedAnnotation(nil)
            }
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }
    var currentColor: NSColor = .systemRed
    var currentWidth: CGFloat = 4
    var currentFontSize: CGFloat = 28

    private var annotations: [Annotation] = []
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    private var currentStrokePoints: [NSPoint] = []
    private var currentShapeStart: NSPoint?
    private var currentShapeEnd: NSPoint?
    private var activeTextField: NSTextField?
    private var activeTextOrigin: NSPoint?
    private var selectedAnnotationIndex: Int?
    private var selectionDragStart: NSPoint?
    private var selectionDragOriginalAnnotation: Annotation?
    private var selectionDragOriginalState: [Annotation]?
    private var selectionDidMove = false
    private var previewScale: CGFloat = 1
    private var zoomMode: ZoomMode = .fit
    private var lastContainerSize = NSSize(width: 980, height: 654)
    private let outputPixelSize: NSSize
    private var mosaicCache: [MosaicCacheKey: NSImage] = [:]

    private struct MosaicCacheKey: Hashable {
        let sourceX: Int
        let sourceY: Int
        let sourceWidth: Int
        let sourceHeight: Int
        let pixelWidth: Int
        let pixelHeight: Int
        let strength: Int
    }

    override var isFlipped: Bool { true }

    init(image: NSImage) {
        self.image = image
        if let representation = image.representations.max(by: {
            $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh
        }), representation.pixelsWide > 0, representation.pixelsHigh > 0 {
            outputPixelSize = NSSize(width: representation.pixelsWide, height: representation.pixelsHigh)
        } else {
            outputPixelSize = image.size
        }
        super.init(frame: NSRect(origin: .zero, size: image.size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Screenshot markup canvas")
        setAccessibilityHelp("Use tool shortcuts to annotate. Select an annotation to move or delete it.")
        updateCanvasSize(NSSize(width: 980, height: 654))
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        let cursor: NSCursor = switch tool {
        case .select: .openHand
        case .text: .iBeam
        default: .crosshair
        }
        addCursorRect(imageRect, cursor: cursor)
    }

    func updateCanvasSize(_ containerSize: NSSize) {
        lastContainerSize = containerSize
        applyCanvasSize()
    }

    func zoomIn(in containerSize: NSSize) {
        lastContainerSize = containerSize
        setZoomScale(previewScale * 1.25)
    }

    func zoomOut(in containerSize: NSSize) {
        lastContainerSize = containerSize
        setZoomScale(previewScale / 1.25)
    }

    func zoomActualSize(in containerSize: NSSize) {
        lastContainerSize = containerSize
        setZoomScale(1)
    }

    func zoomToFit(in containerSize: NSSize) {
        lastContainerSize = containerSize
        zoomMode = .fit
        applyCanvasSize()
    }

    private func setZoomScale(_ scale: CGFloat) {
        zoomMode = .fixed(min(6, max(0.1, scale)))
        applyCanvasSize()
    }

    private func applyCanvasSize() {
        let imageSize = image.size
        switch zoomMode {
        case .fit:
            previewScale = displayScale(for: imageSize, in: lastContainerSize)
        case let .fixed(scale):
            previewScale = scale
        }
        let size = NSSize(
            width: max(imageSize.width * previewScale + 80, lastContainerSize.width),
            height: max(imageSize.height * previewScale + 80, lastContainerSize.height)
        )
        setFrameSize(size)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.85).setFill()
        bounds.fill()

        let rect = imageRect
        image.draw(in: rect)

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        let transform = imageTransform
        for annotation in annotations {
            draw(annotation, transform: transform)
        }
        drawInProgress(transform: transform)
        drawSelectionOverlay(transform: transform)
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = imagePoint(from: convert(event.locationInWindow, from: nil))
        guard point != nil else { return }

        if tool == .select {
            beginSelection(at: point!)
            return
        }

        if event.clickCount >= 2 || tool == .text {
            beginTextEditing(at: point!)
            return
        }

        switch tool {
        case .pen, .highlighter:
            currentStrokePoints = [point!]
        case .arrow, .rectangle, .ellipse:
            currentShapeStart = point
            currentShapeEnd = point
        case .mosaic:
            currentShapeStart = point
            currentShapeEnd = point
        case .marker:
            append(.marker(number: nextMarkerNumber(), center: point!, color: currentColor))
        case .check:
            append(.checkmark(center: point!, color: currentColor))
        case .select, .text:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let point = imagePoint(from: convert(event.locationInWindow, from: nil)) else { return }
        switch tool {
        case .pen, .highlighter:
            let minimumDistance = max(0.75, currentWidth * 0.15)
            if let last = currentStrokePoints.last,
               hypot(point.x - last.x, point.y - last.y) < minimumDistance {
                return
            }
            currentStrokePoints.append(point)
            needsDisplay = true
        case .arrow, .rectangle, .ellipse:
            currentShapeEnd = point
            needsDisplay = true
        case .mosaic:
            currentShapeEnd = point
            needsDisplay = true
        case .select:
            moveSelection(to: point)
        case .marker, .check, .text:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if tool == .select {
            finishSelectionMove()
            return
        }

        defer {
            currentStrokePoints = []
            currentShapeStart = nil
            currentShapeEnd = nil
            needsDisplay = true
        }

        switch tool {
        case .pen:
            guard currentStrokePoints.count > 1 else { return }
            append(.stroke(points: currentStrokePoints, color: currentColor, width: currentWidth, alpha: 1))
        case .highlighter:
            guard currentStrokePoints.count > 1 else { return }
            append(.stroke(points: currentStrokePoints, color: currentColor, width: currentWidth * 2.8, alpha: 0.32))
        case .arrow:
            appendCurrentShape(.arrow)
        case .rectangle:
            appendCurrentShape(.rectangle)
        case .ellipse:
            appendCurrentShape(.ellipse)
        case .mosaic:
            appendCurrentMosaic()
        case .select, .marker, .check, .text:
            break
        }
    }

    override func keyDown(with event: NSEvent) {
        let keyCode = Int(event.keyCode)
        switch keyCode {
        case 51, 117:
            deleteSelectedAnnotation()
            return
        case 53:
            if activeTextField != nil {
                cancelActiveText()
            } else if selectedAnnotationIndex != nil {
                setSelectedAnnotation(nil)
            } else {
                cancelInProgressAnnotation()
            }
            return
        case 123, 124, 125, 126:
            guard selectedAnnotationIndex != nil else { break }
            let distance: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let delta: NSSize = switch keyCode {
            case 123: NSSize(width: -distance, height: 0)
            case 124: NSSize(width: distance, height: 0)
            case 125: NSSize(width: 0, height: distance)
            default: NSSize(width: 0, height: -distance)
            }
            nudgeSelectedAnnotation(by: delta)
            return
        default:
            break
        }

        let disallowedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        if event.modifierFlags.intersection(disallowedModifiers).isEmpty,
           let character = event.charactersIgnoringModifiers?.uppercased(),
           let shortcutTool = MarkupTool.allCases.first(where: { $0.shortcut == character }) {
            onToolShortcut?(shortcutTool)
            return
        }

        super.keyDown(with: event)
    }

    func undo() {
        commitActiveText()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
        setSelectedAnnotation(nil)
        notifyHistoryChanged()
        needsDisplay = true
    }

    func redo() {
        commitActiveText()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        setSelectedAnnotation(nil)
        notifyHistoryChanged()
        needsDisplay = true
    }

    func deleteSelectedAnnotation() {
        guard let selectedAnnotationIndex, annotations.indices.contains(selectedAnnotationIndex) else { return }
        recordStateForUndo()
        annotations.remove(at: selectedAnnotationIndex)
        setSelectedAnnotation(nil)
        needsDisplay = true
    }

    func renderedPNGData() -> Data? {
        commitActiveText()
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
        for annotation in annotations {
            drawForExport(annotation, transform: { $0 })
        }

        return bitmap.representation(using: .png, properties: [:])
    }

    private var imageRect: NSRect {
        let imageSize = image.size
        let scale = max(0.1, previewScale)
        let size = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return NSRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private var imageTransform: (NSPoint) -> NSPoint {
        let rect = imageRect
        let scaleX = rect.width / max(image.size.width, 1)
        let scaleY = rect.height / max(image.size.height, 1)
        return { point in
            NSPoint(x: rect.minX + point.x * scaleX, y: rect.minY + point.y * scaleY)
        }
    }

    private func imagePoint(from viewPoint: NSPoint) -> NSPoint? {
        let rect = imageRect
        guard rect.contains(viewPoint) else { return nil }
        let scaleX = image.size.width / max(rect.width, 1)
        let scaleY = image.size.height / max(rect.height, 1)
        return NSPoint(
            x: (viewPoint.x - rect.minX) * scaleX,
            y: (viewPoint.y - rect.minY) * scaleY
        )
    }

    private func viewPoint(from imagePoint: NSPoint) -> NSPoint {
        imageTransform(imagePoint)
    }

    private func append(_ annotation: Annotation) {
        recordStateForUndo()
        annotations.append(annotation)
        needsDisplay = true
    }

    private func beginSelection(at point: NSPoint) {
        let tolerance = 8 / max(previewScale, 0.1)
        let hitIndex = annotations.indices.reversed().first {
            annotations[$0].hitTest(point, tolerance: tolerance)
        }
        setSelectedAnnotation(hitIndex)
        guard let hitIndex else { return }
        selectionDragStart = point
        selectionDragOriginalAnnotation = annotations[hitIndex]
        selectionDragOriginalState = annotations
        selectionDidMove = false
    }

    private func moveSelection(to point: NSPoint) {
        guard let selectedAnnotationIndex,
              annotations.indices.contains(selectedAnnotationIndex),
              let dragStart = selectionDragStart,
              let original = selectionDragOriginalAnnotation
        else {
            return
        }

        let proposed = NSSize(width: point.x - dragStart.x, height: point.y - dragStart.y)
        let delta = clampedTranslation(for: original, proposed: proposed)
        annotations[selectedAnnotationIndex] = original.translated(by: delta)
        selectionDidMove = abs(delta.width) > 0.01 || abs(delta.height) > 0.01
        NSCursor.closedHand.set()
        needsDisplay = true
    }

    private func finishSelectionMove() {
        if selectionDidMove, let originalState = selectionDragOriginalState {
            pushUndoState(originalState)
        }
        selectionDragStart = nil
        selectionDragOriginalAnnotation = nil
        selectionDragOriginalState = nil
        selectionDidMove = false
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    private func nudgeSelectedAnnotation(by proposed: NSSize) {
        guard let selectedAnnotationIndex,
              annotations.indices.contains(selectedAnnotationIndex)
        else {
            return
        }
        let original = annotations[selectedAnnotationIndex]
        let delta = clampedTranslation(for: original, proposed: proposed)
        guard abs(delta.width) > 0.01 || abs(delta.height) > 0.01 else { return }
        recordStateForUndo()
        annotations[selectedAnnotationIndex] = original.translated(by: delta)
        needsDisplay = true
    }

    private func clampedTranslation(for annotation: Annotation, proposed: NSSize) -> NSSize {
        let bounds = annotation.bounds
        return NSSize(
            width: MarkupGeometry.clampedTranslationDelta(
                minimum: bounds.minX,
                maximum: bounds.maxX,
                limit: image.size.width,
                proposed: proposed.width
            ),
            height: MarkupGeometry.clampedTranslationDelta(
                minimum: bounds.minY,
                maximum: bounds.maxY,
                limit: image.size.height,
                proposed: proposed.height
            )
        )
    }

    private func setSelectedAnnotation(_ index: Int?) {
        guard selectedAnnotationIndex != index else { return }
        selectedAnnotationIndex = index
        onSelectionChanged?(index != nil)
        needsDisplay = true
    }

    private func recordStateForUndo() {
        pushUndoState(annotations)
    }

    private func pushUndoState(_ state: [Annotation]) {
        undoStack.append(state)
        if undoStack.count > 100 {
            undoStack.removeFirst(undoStack.count - 100)
        }
        redoStack.removeAll()
        notifyHistoryChanged()
    }

    private func notifyHistoryChanged() {
        onHistoryChanged?(!undoStack.isEmpty, !redoStack.isEmpty)
    }

    private func cancelInProgressAnnotation() {
        currentStrokePoints.removeAll()
        currentShapeStart = nil
        currentShapeEnd = nil
        needsDisplay = true
    }

    private func nextMarkerNumber() -> Int {
        let maxNumber = annotations.compactMap { annotation -> Int? in
            if case let .marker(number, _, _) = annotation {
                return number
            }
            return nil
        }.max() ?? 0
        return maxNumber + 1
    }

    private func appendCurrentShape(_ kind: ShapeKind) {
        guard let start = currentShapeStart,
              let end = currentShapeEnd,
              hypot(end.x - start.x, end.y - start.y) >= 4
        else {
            return
        }
        append(.shape(kind: kind, start: start, end: end, color: currentColor, width: currentWidth))
    }

    private func appendCurrentMosaic() {
        guard let start = currentShapeStart,
              let end = currentShapeEnd,
              abs(end.x - start.x) >= 8,
              abs(end.y - start.y) >= 8
        else {
            return
        }
        append(.mosaic(start: start, end: end, strength: currentWidth))
    }

    private func beginTextEditing(at point: NSPoint) {
        commitActiveText()
        let viewPoint = viewPoint(from: point)
        let field = NSTextField(frame: NSRect(x: viewPoint.x, y: viewPoint.y, width: 260, height: max(currentFontSize + 14, 38)))
        field.stringValue = ""
        field.placeholderString = "Text"
        field.font = .systemFont(ofSize: currentFontSize, weight: .semibold)
        field.textColor = currentColor
        field.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.92)
        field.isBordered = true
        field.delegate = self
        field.target = self
        field.action = #selector(commitActiveText)
        addSubview(field)
        activeTextField = field
        activeTextOrigin = point
        window?.makeFirstResponder(field)
    }

    private func cancelActiveText() {
        activeTextField?.removeFromSuperview()
        activeTextField = nil
        activeTextOrigin = nil
        window?.makeFirstResponder(self)
    }

    @objc private func commitActiveText() {
        guard let field = activeTextField,
              let origin = activeTextOrigin
        else {
            return
        }

        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        activeTextField = nil
        activeTextOrigin = nil
        window?.makeFirstResponder(self)

        guard !text.isEmpty else { return }
        append(.text(text, origin: origin, color: currentColor, fontSize: currentFontSize, background: true))
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitActiveText()
    }

    private func drawInProgress(transform: (NSPoint) -> NSPoint) {
        switch tool {
        case .pen:
            draw(.stroke(points: currentStrokePoints, color: currentColor, width: currentWidth, alpha: 1), transform: transform)
        case .highlighter:
            draw(.stroke(points: currentStrokePoints, color: currentColor, width: currentWidth * 2.8, alpha: 0.32), transform: transform)
        case .arrow:
            drawCurrentShape(.arrow, transform: transform)
        case .rectangle:
            drawCurrentShape(.rectangle, transform: transform)
        case .ellipse:
            drawCurrentShape(.ellipse, transform: transform)
        case .mosaic:
            drawCurrentMosaic(transform: transform)
        case .select, .check, .text:
            break
        case .marker:
            break
        }
    }

    private func drawSelectionOverlay(transform: (NSPoint) -> NSPoint) {
        guard let selectedAnnotationIndex,
              annotations.indices.contains(selectedAnnotationIndex)
        else {
            return
        }

        let annotationBounds = annotations[selectedAnnotationIndex].bounds
        let rect = normalizedRect(
            from: transform(NSPoint(x: annotationBounds.minX, y: annotationBounds.minY)),
            to: transform(NSPoint(x: annotationBounds.maxX, y: annotationBounds.maxY))
        ).insetBy(dx: -6, dy: -6)

        let outline = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        outline.lineWidth = 3
        NSColor.white.withAlphaComponent(0.92).setStroke()
        outline.stroke()

        outline.lineWidth = 1.5
        outline.setLineDash([5, 4], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        outline.stroke()
    }

    private func drawCurrentShape(_ kind: ShapeKind, transform: (NSPoint) -> NSPoint) {
        guard let start = currentShapeStart, let end = currentShapeEnd else { return }
        draw(.shape(kind: kind, start: start, end: end, color: currentColor, width: currentWidth), transform: transform)
    }

    private func drawCurrentMosaic(transform: (NSPoint) -> NSPoint) {
        guard let start = currentShapeStart, let end = currentShapeEnd else { return }
        draw(.mosaic(start: start, end: end, strength: currentWidth), transform: transform)
    }

    private func draw(_ annotation: Annotation, transform: (NSPoint) -> NSPoint) {
        switch annotation {
        case let .stroke(points, color, width, alpha):
            guard points.count > 1 else { return }
            let path = NSBezierPath()
            path.move(to: transform(points[0]))
            for point in points.dropFirst() {
                path.line(to: transform(point))
            }
            color.withAlphaComponent(alpha).setStroke()
            path.lineWidth = width * displayScale
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()

        case let .shape(kind, start, end, color, width):
            color.setStroke()
            let start = transform(start)
            let end = transform(end)
            let rect = normalizedRect(from: start, to: end)
            switch kind {
            case .arrow:
                drawArrow(from: start, to: end, color: color, width: width * displayScale)
            case .rectangle:
                let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
                path.lineWidth = width * displayScale
                path.stroke()
            case .ellipse:
                let path = NSBezierPath(ovalIn: rect)
                path.lineWidth = width * displayScale
                path.stroke()
            }

        case let .mosaic(start, end, strength):
            drawMosaic(
                sourceRect: normalizedRect(from: start, to: end),
                destinationRect: normalizedRect(from: transform(start), to: transform(end)),
                strength: strength
            )

        case let .marker(number, center, color):
            drawMarker(number: number, center: transform(center), radius: 14 * max(displayScale, 0.75), color: color)

        case let .checkmark(center, color):
            drawCheckmark(center: transform(center), radius: 14 * max(displayScale, 0.75), color: color)

        case let .text(text, origin, color, fontSize, background):
            let point = transform(origin)
            let font = NSFont.systemFont(ofSize: fontSize * displayScale, weight: .semibold)
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

    private var displayScale: CGFloat {
        let rect = imageRect
        return rect.width / max(image.size.width, 1)
    }

    private func drawMosaic(
        sourceRect: NSRect,
        destinationRect: NSRect,
        strength: CGFloat,
        showsBorder: Bool = true
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
        if let cached = mosaicCache[cacheKey] {
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
            if mosaicCache.count >= 32 {
                mosaicCache.removeAll(keepingCapacity: true)
            }
            mosaicCache[cacheKey] = generated
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
            border.lineWidth = max(1, displayScale)
            border.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func imageSourceRect(from rect: NSRect) -> NSRect {
        NSRect(
            x: rect.minX,
            y: max(0, image.size.height - rect.maxY),
            width: rect.width,
            height: rect.height
        )
    }

    private func drawMarker(number: Int, center: NSPoint, radius: CGFloat, color: NSColor) {
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

        let check = NSBezierPath()
        check.move(to: NSPoint(x: center.x - radius * 0.48, y: center.y + radius * 0.02))
        check.line(to: NSPoint(x: center.x - radius * 0.14, y: center.y + radius * 0.34))
        check.line(to: NSPoint(x: center.x + radius * 0.52, y: center.y - radius * 0.38))
        check.lineWidth = max(2.4, radius * 0.22)
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        check.stroke()
    }

    private func displayScale(for imageSize: NSSize, in containerSize: NSSize) -> CGFloat {
        calculatePreviewScale(for: imageSize, viewportSize: containerSize)
    }

    private func drawForExport(_ annotation: Annotation, transform: (NSPoint) -> NSPoint) {
        switch annotation {
        case let .stroke(points, color, width, alpha):
            guard points.count > 1 else { return }
            let path = NSBezierPath()
            path.move(to: transform(points[0]))
            for point in points.dropFirst() {
                path.line(to: transform(point))
            }
            color.withAlphaComponent(alpha).setStroke()
            path.lineWidth = width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        case let .shape(kind, start, end, color, width):
            color.setStroke()
            let rect = normalizedRect(from: start, to: end)
            switch kind {
            case .arrow:
                drawArrow(from: start, to: end, color: color, width: width)
            case .rectangle:
                let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
                path.lineWidth = width
                path.stroke()
            case .ellipse:
                let path = NSBezierPath(ovalIn: rect)
                path.lineWidth = width
                path.stroke()
            }
        case let .mosaic(start, end, strength):
            let rect = normalizedRect(from: start, to: end)
            drawMosaic(sourceRect: rect, destinationRect: rect, strength: strength, showsBorder: false)
        case let .marker(number, center, color):
            drawMarker(number: number, center: center, radius: 14, color: color)
        case let .checkmark(center, color):
            drawCheckmark(center: center, radius: 14, color: color)
        case let .text(text, origin, color, fontSize, background):
            let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color
            ]
            let size = text.size(withAttributes: attributes)
            let rect = NSRect(origin: origin, size: NSSize(width: size.width + 14, height: size.height + 10))
            if background {
                NSColor.textBackgroundColor.withAlphaComponent(0.86).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            }
            text.draw(in: rect.insetBy(dx: 7, dy: 5), withAttributes: attributes)
        }
    }
}

private func calculatePreviewScale(for imageSize: NSSize, viewportSize: NSSize) -> CGFloat {
    MarkupGeometry.previewScale(for: imageSize, viewportSize: viewportSize)
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

private func normalizedRect(from start: NSPoint, to end: NSPoint) -> NSRect {
    MarkupGeometry.normalizedRect(from: start, to: end)
}

private func log(_ message: String) {
    print("[screenshot-quick-markup] \(message)")
}
