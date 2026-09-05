enum MarkupTool: String, CaseIterable {
    case select
    case pen
    case highlighter
    case arrow
    case rectangle
    case ellipse
    case mosaic
    case redaction
    case marker
    case check
    case text

    var symbolName: String {
        switch self {
        case .select: return "cursorarrow"
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .mosaic: return "checkerboard.rectangle"
        case .redaction: return "rectangle.fill"
        case .marker: return "mappin.circle"
        case .check: return "checkmark.circle"
        case .text: return "textformat"
        }
    }

    var title: String {
        switch self {
        case .select: return "Select"
        case .pen: return "Pen"
        case .highlighter: return "Highlight"
        case .arrow: return "Arrow"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .mosaic: return "Blur"
        case .redaction: return "Redact"
        case .marker: return "Marker"
        case .check: return "Check"
        case .text: return "Text"
        }
    }

    var shortcut: String {
        switch self {
        case .select: return "V"
        case .pen: return "P"
        case .highlighter: return "H"
        case .arrow: return "A"
        case .rectangle: return "R"
        case .ellipse: return "O"
        case .mosaic: return "B"
        case .redaction: return "X"
        case .marker: return "N"
        case .check: return "K"
        case .text: return "T"
        }
    }
}
