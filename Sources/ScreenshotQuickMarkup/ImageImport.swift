@preconcurrency import AppKit
import UniformTypeIdentifiers

@MainActor
enum ImageImport {
    static func chooseImage() -> NSImage? {
        NSApplication.shared.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.title = "Open Image"
        panel.prompt = "Open"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let image = image(fromFileURL: url) else {
            showUnreadableImageAlert(fileName: url.lastPathComponent)
            return nil
        }
        return image
    }

    static func image(from pasteboard: NSPasteboard) -> NSImage? {
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type),
               let image = decodedImage(data: data) {
                return image
            }
        }

        let fileURLStrings = pasteboard.pasteboardItems?
            .compactMap { $0.string(forType: .fileURL) } ?? []
        guard fileURLStrings.count == 1,
              let url = URL(string: fileURLStrings[0]),
              url.isFileURL
        else {
            return nil
        }

        return image(fromFileURL: url)
    }

    private static func image(fromFileURL url: URL) -> NSImage? {
        guard url.isFileURL, let image = NSImage(contentsOf: url) else { return nil }
        return usableImage(image)
    }

    private static func decodedImage(data: Data) -> NSImage? {
        guard let image = NSImage(data: data) else { return nil }
        return usableImage(image)
    }

    private static func usableImage(_ image: NSImage) -> NSImage? {
        let size = image.size
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0
        else {
            return nil
        }

        var proposedRect = NSRect(origin: .zero, size: size)
        guard let cgImage = image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ), cgImage.width > 0, cgImage.height > 0 else {
            return nil
        }
        return image
    }

    private static func showUnreadableImageAlert(fileName: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t open image"
        alert.informativeText = "\(fileName) isn’t a readable image file."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
