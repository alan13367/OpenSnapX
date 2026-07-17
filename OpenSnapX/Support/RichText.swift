import AppKit

@MainActor
enum RichTextBridge {
    static func attributedString(for annotation: Annotation) -> NSMutableAttributedString {
        let fallback = defaultStyle(for: annotation)
        guard let document = annotation.richText else {
            return NSMutableAttributedString(
                string: annotation.text ?? "",
                attributes: attributes(for: fallback)
            )
        }

        let attributed = NSMutableAttributedString(
            string: document.string,
            attributes: attributes(for: fallback)
        )
        let utf16Length = attributed.length
        for run in document.runs {
            let location = min(max(0, run.location), utf16Length)
            let length = min(max(0, run.length), utf16Length - location)
            guard length > 0 else { continue }
            attributed.setAttributes(
                attributes(for: run.style),
                range: NSRange(location: location, length: length)
            )
        }
        return attributed
    }

    static func document(from attributedString: NSAttributedString, fallback: RichTextStyle) -> RichTextDocument {
        guard attributedString.length > 0 else {
            return RichTextDocument(string: attributedString.string, runs: [])
        }

        var runs: [RichTextRun] = []
        attributedString.enumerateAttributes(
            in: NSRange(location: 0, length: attributedString.length),
            options: []
        ) { values, range, _ in
            let style = style(from: values, fallback: fallback)
            if let last = runs.last,
               last.location + last.length == range.location,
               last.style == style {
                runs[runs.count - 1].length += range.length
            } else {
                runs.append(RichTextRun(location: range.location, length: range.length, style: style))
            }
        }
        return RichTextDocument(string: attributedString.string, runs: runs)
    }

    static func defaultStyle(for annotation: Annotation) -> RichTextStyle {
        RichTextStyle(
            fontFamily: NSFont.systemFont(ofSize: annotation.style.fontSize).familyName ?? "SF Pro",
            fontSize: annotation.style.fontSize,
            foregroundColor: annotation.style.strokeColor
        )
    }

    static func attributes(for style: RichTextStyle) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = nsAlignment(style.alignment)
        var values: [NSAttributedString.Key: Any] = [
            .font: font(for: style),
            .foregroundColor: style.foregroundColor.nsColor,
            .paragraphStyle: paragraph,
            .underlineStyle: style.isUnderlined ? NSUnderlineStyle.single.rawValue : 0,
            .strikethroughStyle: style.isStruckThrough ? NSUnderlineStyle.single.rawValue : 0
        ]
        if let backgroundColor = style.backgroundColor {
            values[.backgroundColor] = backgroundColor.nsColor
        }
        return values
    }

    static func style(from values: [NSAttributedString.Key: Any], fallback: RichTextStyle) -> RichTextStyle {
        var result = fallback
        if let font = values[.font] as? NSFont {
            result.fontFamily = font.familyName ?? font.fontName
            result.fontSize = font.pointSize
            let traits = NSFontManager.shared.traits(of: font)
            result.isBold = traits.contains(.boldFontMask)
            result.isItalic = traits.contains(.italicFontMask)
        }
        if let color = values[.foregroundColor] as? NSColor {
            result.foregroundColor = RGBAColor(color)
        }
        result.backgroundColor = (values[.backgroundColor] as? NSColor).map(RGBAColor.init)
        result.isUnderlined = (values[.underlineStyle] as? Int ?? 0) != 0
        result.isStruckThrough = (values[.strikethroughStyle] as? Int ?? 0) != 0
        if let paragraph = values[.paragraphStyle] as? NSParagraphStyle {
            result.alignment = richAlignment(paragraph.alignment)
        }
        return result
    }

    static func font(for style: RichTextStyle) -> NSFont {
        var traits: NSFontTraitMask = []
        if style.isBold { traits.insert(.boldFontMask) }
        if style.isItalic { traits.insert(.italicFontMask) }
        if let font = NSFontManager.shared.font(
            withFamily: style.fontFamily,
            traits: traits,
            weight: style.isBold ? 9 : 5,
            size: max(1, style.fontSize)
        ) {
            return font
        }
        var font = NSFont.systemFont(ofSize: max(1, style.fontSize), weight: style.isBold ? .bold : .regular)
        if style.isItalic {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }

    private static func nsAlignment(_ alignment: RichTextAlignment) -> NSTextAlignment {
        switch alignment {
        case .left: .left
        case .center: .center
        case .right: .right
        case .justified: .justified
        }
    }

    private static func richAlignment(_ alignment: NSTextAlignment) -> RichTextAlignment {
        switch alignment {
        case .center: .center
        case .right: .right
        case .justified: .justified
        default: .left
        }
    }
}
