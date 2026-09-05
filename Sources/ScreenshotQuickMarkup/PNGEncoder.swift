import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PNGEncoder {
    static func encode(_ image: CGImage) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return nil as Data? }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
                return nil
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return data as Data
        }.value
    }
}
