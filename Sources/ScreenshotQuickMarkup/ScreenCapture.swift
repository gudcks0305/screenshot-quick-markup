@preconcurrency import AppKit
import ScreenshotQuickMarkupCore

struct CapturedScreenshot {
    let image: CGImage
    let screenFrame: NSRect
}

enum ScreenCapture {
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
