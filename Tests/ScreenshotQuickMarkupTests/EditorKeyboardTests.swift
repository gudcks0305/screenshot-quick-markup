import AppKit
import Testing
@testable import ScreenshotQuickMarkup

@Suite("Editor keyboard routing", .serialized)
@MainActor
struct EditorKeyboardTests {
    @Test("Text editing shortcuts stay in the native text responder; Cmd-W still closes")
    func textShortcuts() throws {
        _ = NSApplication.shared
        let controller = ImageEditorWindowController(image: NSImage(size: NSSize(width: 100, height: 100)))
        let window = try #require(controller.window)
        let textView = TextCommandSpy(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        textView.string = "Editable text"
        window.contentView?.addSubview(textView)
        #expect(window.makeFirstResponder(textView))
        for code: UInt16 in [7, 8, 9] {
            #expect(window.performKeyEquivalent(with: try command(code)))
        }
        #expect(textView.commands == ["cut", "copy", "paste"])
        #expect(window.performKeyEquivalent(with: try command(0)))
        #expect(textView.selectedRange() == NSRange(location: 0, length: 13))
        var closed = false
        controller.onClose = { closed = true }
        #expect(window.performKeyEquivalent(with: try command(13)))
        #expect(closed)
    }

    private func command(_ code: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
    }
}

@MainActor
private final class TextCommandSpy: NSTextView {
    var commands: [String] = []
    override func cut(_ sender: Any?) { commands.append("cut") }
    override func copy(_ sender: Any?) { commands.append("copy") }
    override func paste(_ sender: Any?) { commands.append("paste") }
}
