import AppKit

extension RGBAColor {
    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    var cgColor: CGColor { nsColor.cgColor }

    init(_ color: NSColor) {
        let value = color.usingColorSpace(.sRGB) ?? color
        red = value.redComponent
        green = value.greenComponent
        blue = value.blueComponent
        alpha = value.alphaComponent
    }
}

