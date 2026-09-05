@preconcurrency import AppKit
import Darwin
import Foundation

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
