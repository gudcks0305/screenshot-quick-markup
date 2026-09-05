@preconcurrency import AppKit
import ScreenshotQuickMarkupCore

final class ImageEditorWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    var onOpenImage: ((NSImage) -> Void)?

    private let editorViewController: ImageEditorViewController
    private var exportTask: Task<Void, Never>?
    private var isClosed = false

    private enum ExportAction {
        case copy(close: Bool)
        case save(URL)
    }
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
        window.titlebarAppearsTransparent = true
        window.center()
        window.contentViewController = editorViewController
        super.init(window: window)
        window.delegate = self
        window.onCommandSave = { [weak self] in self?.saveImage() }
        window.onCommandCopy = { [weak self] in self?.startExport(.copy(close: false)) }
        window.onCommandOpen = { [weak self] in
            guard let image = ImageImport.chooseImage() else { return }
            self?.onOpenImage?(image)
        }
        window.onUndo = { [weak self] in self?.editorViewController.undo() }
        window.onRedo = { [weak self] in self?.editorViewController.redo() }
        window.onToolShortcut = { [weak self] tool in
            self?.editorViewController.activateTool(tool)
        }
        editorViewController.onCopy = { [weak self] in
            self?.startExport(.copy(close: false))
        }
        editorViewController.onOpenImage = { [weak self] image in self?.onOpenImage?(image) }
        editorViewController.onSave = { [weak self] in self?.saveImage() }
        editorViewController.onDone = { [weak self] in
            self?.startExport(.copy(close: true))
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
        isClosed = true
        exportTask?.cancel()
        onClose?()
    }

    @discardableResult
    private func copyImageToClipboard(_ data: Data) -> Bool {
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
        guard exportTask == nil, let window, !isClosed else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "screenshot-\(Int(Date().timeIntervalSince1970)).png"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.png]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.startExport(.save(url))
        }
    }

    private func startExport(_ action: ExportAction) {
        guard exportTask == nil, !isClosed else { return }
        editorViewController.setExporting(true)
        exportTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.exportTask = nil
                self.editorViewController.setExporting(false)
            }
            guard let data = await self.editorViewController.renderedPNGDataAsync() else {
                if !Task.isCancelled && !self.isClosed {
                    self.editorViewController.showStatus("Couldn’t render image", isError: true)
                }
                return
            }
            guard !Task.isCancelled, !self.isClosed else { return }
            switch action {
            case let .copy(close):
                if self.copyImageToClipboard(data), close { self.window?.close() }
            case let .save(url):
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try data.write(to: url, options: .atomic)
                    }.value
                    guard !self.isClosed else { return }
                    self.editorViewController.showStatus("Saved \(url.lastPathComponent)")
                    NSSound(named: "Pop")?.play()
                } catch {
                    self.editorViewController.showStatus("Save failed: \(error.localizedDescription)", isError: true)
                }
            }
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
    let preferredScale = MarkupGeometry.previewScale(for: imageSize, viewportSize: maxSize)

    return NSSize(
        width: min(maxSize.width, max(minSize.width, imageSize.width * preferredScale + 160)),
        height: min(maxSize.height, max(minSize.height, imageSize.height * preferredScale + 180))
    )
}

private final class EditorWindow: NSWindow {
    var onCommandSave: (() -> Void)?
    var onCommandCopy: (() -> Void)?
    var onCommandOpen: (() -> Void)?
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

        if let editor = firstResponder as? NSTextView {
            switch Int(event.keyCode) {
            case 0:
                editor.selectAll(nil)
                return true
            case 6:
                if event.modifierFlags.contains(.shift) { editor.undoManager?.redo() }
                else { editor.undoManager?.undo() }
                return true
            case 7:
                editor.cut(nil)
                return true
            case 8:
                editor.copy(nil)
                return true
            case 9:
                editor.paste(nil)
                return true
            default: break
            }
        }

        switch Int(event.keyCode) {
        case 31:
            onCommandOpen?()
            return true
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
