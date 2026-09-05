@preconcurrency import AppKit

enum EditorPreferences {
    private static let toolKey = "editor.lastTool"
    private static let colorKey = "editor.lastColor"
    private static let widthKey = "editor.lastWidth"
    private static let fontSizeKey = "editor.lastFontSize"

    static var tool: MarkupTool {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: toolKey),
                  let tool = MarkupTool(rawValue: rawValue)
            else {
                return .pen
            }
            return tool
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: toolKey)
        }
    }

    static var color: NSColor {
        get {
            guard let components = UserDefaults.standard.array(forKey: colorKey) as? [Double],
                  components.count == 4
            else {
                return .systemRed
            }
            return NSColor(
                calibratedRed: CGFloat(components[0]),
                green: CGFloat(components[1]),
                blue: CGFloat(components[2]),
                alpha: CGFloat(components[3])
            )
        }
        set {
            guard let color = newValue.usingColorSpace(.deviceRGB) else { return }
            UserDefaults.standard.set(
                [
                    Double(color.redComponent),
                    Double(color.greenComponent),
                    Double(color.blueComponent),
                    Double(color.alphaComponent)
                ],
                forKey: colorKey
            )
        }
    }

    static var width: CGFloat {
        get {
            let storedWidth = UserDefaults.standard.double(forKey: widthKey)
            guard storedWidth > 0 else { return 4 }
            return min(24, max(1, CGFloat(storedWidth)))
        }
        set {
            UserDefaults.standard.set(Double(min(24, max(1, newValue))), forKey: widthKey)
        }
    }

    static var fontSize: CGFloat {
        get {
            let storedSize = UserDefaults.standard.double(forKey: fontSizeKey)
            guard storedSize > 0 else { return 28 }
            return min(96, max(12, CGFloat(storedSize)))
        }
        set {
            UserDefaults.standard.set(Double(min(96, max(12, newValue))), forKey: fontSizeKey)
        }
    }
}
