@preconcurrency import AppKit
import Carbon
import Carbon.HIToolbox
import CoreGraphics
import Foundation

private let hotKeySignature = OSType(
    UInt32(UInt8(ascii: "S")) << 24
        | UInt32(UInt8(ascii: "Q")) << 16
        | UInt32(UInt8(ascii: "M")) << 8
        | UInt32(UInt8(ascii: "K"))
)

@main
@MainActor
private enum Main {
    static func main() {
        setbuf(stdout, nil)
        setbuf(stderr, nil)
        _ = NSApplication.shared
        ScreenshotQuickMarkupApp().run()
    }
}

@MainActor
private final class ScreenshotQuickMarkupApp: @unchecked Sendable {
    private let statusMenu = StatusMenu()
    private var hotKeyRef: EventHotKeyRef?
    private var captureOverlay: CaptureOverlayWindowController?
    private var editorWindows: [ImageEditorWindowController] = []

    func run() {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSWindow.allowsAutomaticWindowTabbing = true

        statusMenu.configure(
            capture: { [weak self] in self?.beginCapture() },
            quit: { NSApplication.shared.terminate(nil) }
        )
        registerHotKey()

        log("ScreenshotQuickMarkup is running. Press Option+Shift+S.")
        NSApplication.shared.run()
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

    private func openEditor(image: NSImage) {
        let editor = ImageEditorWindowController(image: image)
        editor.onClose = { [weak self, weak editor] in
            guard let self, let editor else { return }
            self.editorWindows.removeAll { $0 === editor }
        }
        let lastTabbedWindow = newestVisibleEditorWindow()
        editorWindows.append(editor)
        NSApplication.shared.activate(ignoringOtherApps: true)

        if let lastTabbedWindow, let newWindow = editor.window {
            lastTabbedWindow.addTabbedWindow(newWindow, ordered: .above)
            newWindow.makeKeyAndOrderFront(nil)
        } else {
            editor.show()
        }

        log("Editor window shown. Open editors: \(editorWindows.count).")
    }

    private func newestVisibleEditorWindow() -> NSWindow? {
        let visibleWindow = editorWindows
            .compactMap { $0.window }
            .first { $0.isVisible }
        return visibleWindow?.tabbedWindows?.last ?? visibleWindow
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

    func configure(capture: @escaping () -> Void, quit: @escaping () -> Void) {
        statusItem.button?.image = NSImage(
            systemSymbolName: "camera.viewfinder",
            accessibilityDescription: "Screenshot Quick Markup"
        )

        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Capture", action: capture))
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

        let scaleX = CGFloat(fullImage.width) / screenshot.screenFrame.width
        let scaleY = CGFloat(fullImage.height) / screenshot.screenFrame.height
        let cropRect = CGRect(
            x: selection.minX * scaleX,
            y: (screenshot.screenFrame.height - selection.maxY) * scaleY,
            width: selection.width * scaleX,
            height: selection.height * scaleY
        ).integral

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
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
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
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }

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
        let text = "Drag to capture area    Return full screen    Esc cancel"
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

        drawCornerHandles(rect)
        drawSizeBadge(for: rect)
    }

    private func drawCornerHandles(_ rect: NSRect) {
        let points = [
            NSPoint(x: rect.minX, y: rect.minY),
            NSPoint(x: rect.maxX, y: rect.minY),
            NSPoint(x: rect.minX, y: rect.maxY),
            NSPoint(x: rect.maxX, y: rect.maxY)
        ]
        for point in points {
            let handle = NSRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
            NSColor.systemBlue.setFill()
            NSBezierPath(roundedRect: handle, xRadius: 4, yRadius: 4).fill()
            NSColor.white.setStroke()
            NSBezierPath(roundedRect: handle.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4).stroke()
        }
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

private enum MarkupTool: CaseIterable {
    case select
    case pen
    case highlighter
    case arrow
    case rectangle
    case ellipse
    case mosaic
    case marker
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
        case .text: return "Text"
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
    case mosaic(start: NSPoint, end: NSPoint)
    case marker(number: Int, center: NSPoint, color: NSColor)
    case text(String, origin: NSPoint, color: NSColor, fontSize: CGFloat, background: Bool)
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
        window.title = "\(captureTime) \(Int(image.size.width))x\(Int(image.size.height))"
        window.minSize = NSSize(width: 900, height: 640)
        window.level = .normal
        window.tabbingIdentifier = "ScreenshotQuickMarkup.Editor"
        window.tabbingMode = .preferred
        window.isReleasedWhenClosed = false
        window.center()
        window.contentViewController = editorViewController
        super.init(window: window)
        window.delegate = self
        window.onCommandSave = { [weak self] in self?.saveImage() }
        window.onCommandCopy = { [weak self] in self?.copyImageToClipboard() }
        window.onUndo = { [weak self] in self?.editorViewController.undo() }
        window.onRedo = { [weak self] in self?.editorViewController.redo() }
        editorViewController.onCopy = { [weak self] in self?.copyImageToClipboard() }
        editorViewController.onSave = { [weak self] in self?.saveImage() }
        editorViewController.onDone = { [weak self] in
            self?.window?.close()
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        copyImageToClipboard()
        onClose?()
    }

    private func copyImageToClipboard() {
        guard let data = editorViewController.renderedPNGData() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
        NSSound(named: "Pop")?.play()
        log("Copied edited screenshot to clipboard.")
    }

    private func saveImage() {
        guard let data = editorViewController.renderedPNGData() else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "screenshot-\(Int(Date().timeIntervalSince1970)).png"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            log("Failed to save screenshot: \(error.localizedDescription)")
        }
    }
}

private func editorWindowSize(for imageSize: NSSize) -> NSSize {
    let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let maxSize = NSSize(
        width: max(900, screenFrame.width * 0.82),
        height: max(640, screenFrame.height * 0.82)
    )
    let minSize = NSSize(width: 1100, height: 760)
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

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }

        switch Int(event.keyCode) {
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
    private let colorWell = NSColorWell()
    private let widthSlider = NSSlider(value: 4, minValue: 1, maxValue: 24, target: nil, action: nil)
    private let fontSizeSlider = NSSlider(value: 28, minValue: 12, maxValue: 96, target: nil, action: nil)

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
        toolButtons.spacing = 6
        toolButtons.translatesAutoresizingMaskIntoConstraints = false

        for tool in MarkupTool.allCases {
            let button = ToolButton(tool: tool)
            button.target = self
            button.action = #selector(selectTool(_:))
            button.toolTip = tool.title
            toolButtons.addArrangedSubview(button)
        }

        colorSwatches.orientation = .horizontal
        colorSwatches.spacing = 4
        colorSwatches.translatesAutoresizingMaskIntoConstraints = false
        for color in [NSColor.systemRed, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .white, .black] {
            let swatch = ColorSwatchButton(color: color)
            swatch.target = self
            swatch.action = #selector(selectSwatch(_:))
            colorSwatches.addArrangedSubview(swatch)
        }

        colorWell.color = .systemRed
        colorWell.target = self
        colorWell.action = #selector(styleChanged)
        colorWell.translatesAutoresizingMaskIntoConstraints = false

        widthSlider.target = self
        widthSlider.action = #selector(styleChanged)
        widthSlider.translatesAutoresizingMaskIntoConstraints = false

        fontSizeSlider.target = self
        fontSizeSlider.action = #selector(styleChanged)
        fontSizeSlider.translatesAutoresizingMaskIntoConstraints = false

        let copyButton = toolbarButton(title: "Copy", symbolName: "doc.on.doc", action: #selector(copyTapped))
        let saveButton = toolbarButton(title: "Save", symbolName: "square.and.arrow.down", action: #selector(saveTapped))
        let doneButton = toolbarButton(title: "Done", symbolName: "checkmark.circle.fill", action: #selector(doneTapped))
        doneButton.contentTintColor = .controlAccentColor

        let scrollView = NSScrollView()
        scrollView.documentView = canvasView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(toolbar)
        toolbar.addSubview(toolButtons)
        toolbar.addSubview(colorSwatches)
        toolbar.addSubview(colorWell)
        toolbar.addSubview(widthSlider)
        toolbar.addSubview(fontSizeSlider)
        toolbar.addSubview(copyButton)
        toolbar.addSubview(saveButton)
        toolbar.addSubview(doneButton)
        root.addSubview(scrollView)

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 56),

            toolButtons.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 12),
            toolButtons.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            colorSwatches.leadingAnchor.constraint(equalTo: toolButtons.trailingAnchor, constant: 16),
            colorSwatches.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            colorWell.leadingAnchor.constraint(equalTo: colorSwatches.trailingAnchor, constant: 8),
            colorWell.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            colorWell.widthAnchor.constraint(equalToConstant: 32),
            colorWell.heightAnchor.constraint(equalToConstant: 26),

            widthSlider.leadingAnchor.constraint(equalTo: colorWell.trailingAnchor, constant: 14),
            widthSlider.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            widthSlider.widthAnchor.constraint(equalToConstant: 130),

            fontSizeSlider.leadingAnchor.constraint(equalTo: widthSlider.trailingAnchor, constant: 14),
            fontSizeSlider.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            fontSizeSlider.widthAnchor.constraint(equalToConstant: 130),

            doneButton.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -12),
            doneButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            saveButton.trailingAnchor.constraint(equalTo: doneButton.leadingAnchor, constant: -8),
            saveButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            copyButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -8),
            copyButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            copyButton.leadingAnchor.constraint(greaterThanOrEqualTo: fontSizeSlider.trailingAnchor, constant: 14),

            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        view = root
        canvasView.tool = .pen
        updateSelectedToolButtons()
        styleChanged()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        canvasView.updateCanvasSize(view.bounds.size)
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

    @objc private func selectTool(_ sender: ToolButton) {
        canvasView.tool = sender.tool
        updateSelectedToolButtons()
    }

    @objc private func styleChanged() {
        canvasView.currentColor = colorWell.color
        canvasView.currentWidth = CGFloat(widthSlider.doubleValue)
        canvasView.currentFontSize = CGFloat(fontSizeSlider.doubleValue)
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

    private func toolbarButton(title: String, symbolName: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private func updateSelectedToolButtons() {
        for case let button as ToolButton in toolButtons.arrangedSubviews {
            button.isSelectedTool = button.tool == canvasView.tool
        }
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
        }
    }

    init(tool: MarkupTool) {
        self.tool = tool
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: tool.symbolName, accessibilityDescription: tool.title)
        imagePosition = .imageOnly
        bezelStyle = .rounded
        isBordered = false
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 36),
            heightAnchor.constraint(equalToConstant: 36)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }
}

private final class ColorSwatchButton: NSButton {
    let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = color.cgColor
        toolTip = "Use color"
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }
}

private final class MarkupCanvasView: NSView, NSTextFieldDelegate {
    let image: NSImage
    var tool: MarkupTool = .pen
    var currentColor: NSColor = .systemRed
    var currentWidth: CGFloat = 4
    var currentFontSize: CGFloat = 28

    private var annotations: [Annotation] = []
    private var redoStack: [Annotation] = []
    private var currentStrokePoints: [NSPoint] = []
    private var currentShapeStart: NSPoint?
    private var currentShapeEnd: NSPoint?
    private var activeTextField: NSTextField?
    private var activeTextOrigin: NSPoint?
    private var previewScale: CGFloat = 1
    private var nextMarkerNumber = 1

    override var isFlipped: Bool { true }

    init(image: NSImage) {
        self.image = image
        super.init(frame: NSRect(origin: .zero, size: image.size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        updateCanvasSize(NSSize(width: 980, height: 654))
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }

    func updateCanvasSize(_ containerSize: NSSize) {
        let imageSize = image.size
        previewScale = displayScale(for: imageSize, in: containerSize)
        let size = NSSize(
            width: max(imageSize.width * previewScale + 80, containerSize.width),
            height: max(imageSize.height * previewScale + 80, containerSize.height)
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
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = imagePoint(from: convert(event.locationInWindow, from: nil))
        guard point != nil else { return }

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
            append(.marker(number: nextMarkerNumber, center: point!, color: currentColor))
            nextMarkerNumber += 1
        case .select, .text:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let point = imagePoint(from: convert(event.locationInWindow, from: nil)) else { return }
        switch tool {
        case .pen, .highlighter:
            currentStrokePoints.append(point)
            needsDisplay = true
        case .arrow, .rectangle, .ellipse:
            currentShapeEnd = point
            needsDisplay = true
        case .mosaic:
            currentShapeEnd = point
            needsDisplay = true
        case .select, .marker, .text:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
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
        case .select, .marker, .text:
            break
        }
    }

    func undo() {
        guard let last = annotations.popLast() else { return }
        redoStack.append(last)
        needsDisplay = true
    }

    func redo() {
        guard let last = redoStack.popLast() else { return }
        annotations.append(last)
        needsDisplay = true
    }

    func renderedPNGData() -> Data? {
        commitActiveText()
        guard let rendered = renderedImage(),
              let tiff = rendered.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else {
            return nil
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
        annotations.append(annotation)
        redoStack.removeAll()
        needsDisplay = true
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
        append(.mosaic(start: start, end: end))
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
        case .select, .text:
            break
        case .marker:
            break
        }
    }

    private func drawCurrentShape(_ kind: ShapeKind, transform: (NSPoint) -> NSPoint) {
        guard let start = currentShapeStart, let end = currentShapeEnd else { return }
        draw(.shape(kind: kind, start: start, end: end, color: currentColor, width: currentWidth), transform: transform)
    }

    private func drawCurrentMosaic(transform: (NSPoint) -> NSPoint) {
        guard let start = currentShapeStart, let end = currentShapeEnd else { return }
        draw(.mosaic(start: start, end: end), transform: transform)
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

        case let .mosaic(start, end):
            drawMosaic(sourceRect: normalizedRect(from: start, to: end), destinationRect: normalizedRect(from: transform(start), to: transform(end)))

        case let .marker(number, center, color):
            drawMarker(number: number, center: transform(center), radius: 14 * max(displayScale, 0.75), color: color)

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

    private func drawMosaic(sourceRect: NSRect, destinationRect: NSRect) {
        guard sourceRect.width >= 2,
              sourceRect.height >= 2,
              destinationRect.width >= 2,
              destinationRect.height >= 2
        else {
            return
        }

        let blockSize = max(8, min(destinationRect.width, destinationRect.height) / 14)
        let pixelatedSize = NSSize(
            width: max(2, destinationRect.width / blockSize),
            height: max(2, destinationRect.height / blockSize)
        )
        let pixelated = NSImage(size: pixelatedSize)
        pixelated.lockFocusFlipped(true)
        NSGraphicsContext.current?.imageInterpolation = .low
        image.draw(
            in: NSRect(origin: .zero, size: pixelatedSize),
            from: sourceRect,
            operation: .copy,
            fraction: 1
        )
        pixelated.unlockFocus()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: destinationRect, xRadius: 4, yRadius: 4).addClip()
        NSGraphicsContext.current?.imageInterpolation = .none
        pixelated.draw(in: destinationRect, from: NSRect(origin: .zero, size: pixelatedSize), operation: .copy, fraction: 1)
        NSColor.black.withAlphaComponent(0.12).setFill()
        destinationRect.fill()
        NSColor.white.withAlphaComponent(0.30).setStroke()
        let border = NSBezierPath(roundedRect: destinationRect, xRadius: 4, yRadius: 4)
        border.lineWidth = max(1, displayScale)
        border.stroke()
        NSGraphicsContext.restoreGraphicsState()
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

    private func renderedImage() -> NSImage? {
        let size = image.size
        let output = NSImage(size: size)
        output.lockFocusFlipped(true)
        image.draw(in: NSRect(origin: .zero, size: size))
        let transform: (NSPoint) -> NSPoint = { $0 }
        for annotation in annotations {
            drawForExport(annotation, transform: transform)
        }
        output.unlockFocus()
        return output
    }

    private func displayScale(for imageSize: NSSize, in containerSize: NSSize) -> CGFloat {
        calculatePreviewScale(for: imageSize, viewportSize: containerSize)
    }

    private func drawForExport(_ annotation: Annotation, transform: (NSPoint) -> NSPoint) {
        let previousRect = imageRect
        _ = previousRect
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
        case let .mosaic(start, end):
            let rect = normalizedRect(from: start, to: end)
            drawMosaic(sourceRect: rect, destinationRect: rect)
        case let .marker(number, center, color):
            drawMarker(number: number, center: center, radius: 14, color: color)
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
    let fitScale = min(
        (viewportSize.width - 120) / max(imageSize.width, 1),
        (viewportSize.height - 140) / max(imageSize.height, 1)
    )
    let minUsefulScale = max(
        1,
        min(4, min(560 / max(imageSize.width, 1), 420 / max(imageSize.height, 1)))
    )

    if fitScale >= minUsefulScale {
        return minUsefulScale
    }

    if fitScale >= 1 {
        return fitScale
    }

    return max(0.25, fitScale)
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
    NSRect(
        x: min(start.x, end.x),
        y: min(start.y, end.y),
        width: abs(end.x - start.x),
        height: abs(end.y - start.y)
    )
}

private func log(_ message: String) {
    print("[screenshot-quick-markup] \(message)")
}
