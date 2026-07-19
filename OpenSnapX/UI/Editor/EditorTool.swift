enum EditorTool: String, CaseIterable {
    case select
    case arrow
    case line
    case rectangle
    case ellipse
    case text
    case pen
    case highlighter
    case counter
    case blur
    case pixelate
    case redact
    case crop

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .text: "textformat"
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .counter: "1.circle"
        case .blur: "drop.halffull"
        case .pixelate: "square.grid.3x3"
        case .redact: "rectangle.fill"
        case .crop: "crop"
        }
    }

    var annotationKind: AnnotationKind? { AnnotationKind(rawValue: rawValue) }

    var hint: String {
        switch self {
        case .select: "Select and resize edits"
        case .arrow: "Draw an arrow"
        case .line: "Draw a line"
        case .rectangle: "Draw a rectangle"
        case .ellipse: "Draw an ellipse"
        case .text: "Add text"
        case .pen: "Draw freehand"
        case .highlighter: "Highlight an area"
        case .counter: "Add a step number"
        case .blur: "Blur an area"
        case .pixelate: "Pixelate an area"
        case .redact: "Redact an area"
        case .crop: "Crop the image"
        }
    }

    var usesStrokeWidth: Bool {
        switch self {
        case .arrow, .line, .rectangle, .ellipse, .pen, .highlighter: true
        case .select, .text, .counter, .blur, .pixelate, .redact, .crop: false
        }
    }
}
