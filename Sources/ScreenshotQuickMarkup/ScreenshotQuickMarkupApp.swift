@preconcurrency import AppKit
import Carbon
import Carbon.HIToolbox

private let hotKeySignature = OSType(
    UInt32(UInt8(ascii: "S")) << 24
        | UInt32(UInt8(ascii: "Q")) << 16
        | UInt32(UInt8(ascii: "M")) << 8
        | UInt32(UInt8(ascii: "K"))
)

@MainActor
final class ScreenshotQuickMarkupApp: NSObject, NSApplicationDelegate, @unchecked Sendable {
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
            openImage: { [weak self] in self?.openImage() },
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
        guard let image = ImageImport.image(from: .general) else {
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

    private func openImage() {
        guard let image = ImageImport.chooseImage() else { return }
        log("Opening image file for markup.")
        openEditor(image: image)
    }

    private func openEditor(image: NSImage) {
        let editor = ImageEditorWindowController(image: image)
        editor.onOpenImage = { [weak self] image in
            self?.openEditor(image: image)
        }
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

func log(_ message: String) {
    print("[screenshot-quick-markup] \(message)")
}
