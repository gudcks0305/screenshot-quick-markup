@preconcurrency import AppKit

@MainActor
final class StatusMenu {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    func configure(
        capture: @escaping () -> Void,
        editClipboard: @escaping () -> Void,
        openImage: @escaping () -> Void,
        quit: @escaping () -> Void
    ) {
        statusItem.button?.image = NSImage(
            systemSymbolName: "camera.viewfinder",
            accessibilityDescription: "Screenshot Quick Markup"
        )

        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Capture Area  ⌥⇧S", action: capture))
        menu.addItem(ClosureMenuItem(title: "Mark Up Clipboard Image", action: editClipboard))
        menu.addItem(ClosureMenuItem(title: "Open Image…", keyEquivalent: "o", action: openImage))
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Quit", action: quit))
        statusItem.menu = menu
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String = "", action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(runHandler), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func runHandler() {
        handler()
    }
}
