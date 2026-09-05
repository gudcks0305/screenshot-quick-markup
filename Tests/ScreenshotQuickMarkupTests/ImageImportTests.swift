import AppKit
import Testing
@testable import ScreenshotQuickMarkup

@Suite("Image import", .serialized)
@MainActor
struct ImageImportTests {
    @Test("Reads PNG data from an isolated pasteboard")
    func readsPNGData() throws {
        let pasteboard = uniquePasteboard()
        let data = try #require(makeImage().pngData)
        let item = NSPasteboardItem()
        #expect(item.setData(data, forType: .png))
        #expect(pasteboard.writeObjects([item]))

        let image = try #require(ImageImport.image(from: pasteboard))
        #expect(image.size.width == 4)
        #expect(image.size.height == 3)
    }

    @Test("Reads one local image file URL from an isolated pasteboard")
    func readsLocalFileURL() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("image.png")
        try #require(makeImage().pngData).write(to: fileURL)

        let pasteboard = uniquePasteboard()
        let item = NSPasteboardItem()
        #expect(item.setString(fileURL.absoluteString, forType: .fileURL))
        #expect(pasteboard.writeObjects([item]))

        let image = try #require(ImageImport.image(from: pasteboard))
        #expect(image.size.width == 4)
        #expect(image.size.height == 3)
    }

    @Test("Rejects remote and multiple file URLs")
    func rejectsUnsupportedURLs() {
        let remotePasteboard = uniquePasteboard()
        let remoteItem = NSPasteboardItem()
        #expect(remoteItem.setString("https://example.com/image.png", forType: .fileURL))
        #expect(remotePasteboard.writeObjects([remoteItem]))
        #expect(ImageImport.image(from: remotePasteboard) == nil)

        let multiplePasteboard = uniquePasteboard()
        let firstItem = NSPasteboardItem()
        let secondItem = NSPasteboardItem()
        #expect(firstItem.setString("file:///tmp/first.png", forType: .fileURL))
        #expect(secondItem.setString("file:///tmp/second.png", forType: .fileURL))
        #expect(multiplePasteboard.writeObjects([firstItem, secondItem]))
        #expect(ImageImport.image(from: multiplePasteboard) == nil)
    }

    private func uniquePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ImageImportTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    private func makeImage() -> NSImage {
        NSImage(size: NSSize(width: 4, height: 3), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
    }
}

private extension NSImage {
    var pngData: Data? {
        guard let tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffRepresentation)
        else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}
