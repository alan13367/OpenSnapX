import AppKit
import CoreGraphics
import CoreImage
import CoreText
import Foundation

protocol ImageRenderer: Sendable {
    func render(source: ImagePayload, session: CaptureSession, options: ExportOptions) throws -> ImagePayload
}

struct CoreGraphicsImageRenderer: ImageRenderer {
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    func render(source: ImagePayload, session: CaptureSession, options: ExportOptions) throws -> ImagePayload {
        let sourceImage = try ImageCodec.resized(source.image, to: session.manifest.outputPixelSize)
        let cropAnnotation = session.annotations.last(where: { $0.kind == .crop })
        let sourceBounds = CGRect(x: 0, y: 0, width: sourceImage.width, height: sourceImage.height)
        let crop = cropAnnotation?.frame.cgRect.intersection(sourceBounds).integral ?? sourceBounds
        guard crop.width > 0, crop.height > 0 else {
            throw OpenSnapXError.captureFailed("The crop is empty.")
        }
        let cropped: CGImage
        if crop == sourceBounds {
            cropped = sourceImage
        } else {
            guard let result = sourceImage.cropping(to: CGRect(
                x: crop.minX,
                y: sourceBounds.height - crop.maxY,
                width: crop.width,
                height: crop.height
            )) else { throw OpenSnapXError.captureFailed("The crop is empty.") }
            cropped = result
        }

        let visibleAnnotations = session.annotations.filter { $0.kind != .crop }
        let annotated = visibleAnnotations.isEmpty
            ? cropped
            : try drawAnnotations(
                on: cropped,
                annotations: visibleAnnotations,
                cropOrigin: crop.origin
            )
        let final = session.manifest.backdrop.isEnabled
            ? try drawBackdrop(around: annotated, configuration: session.manifest.backdrop)
            : annotated
        return ImagePayload(image: final)
    }

    private func drawAnnotations(on source: CGImage, annotations: [Annotation], cropOrigin: CGPoint) throws -> CGImage {
        guard let colorSpace = source.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: source.width,
                height: source.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { throw OpenSnapXError.captureFailed("Could not create the annotation renderer.") }

        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        context.draw(source, in: bounds)

        for annotation in annotations where annotation.kind == .blur || annotation.kind == .pixelate {
            applyEffect(annotation, cropOrigin: cropOrigin, source: source, to: context)
        }

        for annotation in annotations where annotation.kind != .blur && annotation.kind != .pixelate {
            drawVector(annotation, cropOrigin: cropOrigin, canvasHeight: bounds.height, in: context)
        }
        guard let result = context.makeImage() else { throw OpenSnapXError.captureFailed("Could not finish annotation rendering.") }
        return result
    }

    private func applyEffect(_ annotation: Annotation, cropOrigin: CGPoint, source: CGImage, to context: CGContext) {
        let frame = annotation.frame.cgRect.offsetBy(dx: -cropOrigin.x, dy: -cropOrigin.y)
        let imageBounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let topLeftFrame = frame.intersection(imageBounds)
        guard !topLeftFrame.isEmpty else { return }
        let ciRect = CGRect(
            x: topLeftFrame.minX,
            y: imageBounds.height - topLeftFrame.maxY,
            width: topLeftFrame.width,
            height: topLeftFrame.height
        )
        var region = CIImage(cgImage: source).cropped(to: ciRect)
        if annotation.kind == .blur {
            region = region.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 12]).cropped(to: ciRect)
        } else {
            region = region.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: 14]).cropped(to: ciRect)
        }
        guard let effect = ciContext.createCGImage(region, from: ciRect) else { return }
        context.saveGState()
        context.clip(to: ciRect)
        context.draw(effect, in: ciRect)
        context.restoreGState()
    }

    private func drawVector(_ annotation: Annotation, cropOrigin: CGPoint, canvasHeight: CGFloat, in context: CGContext) {
        let topLeftFrame = annotation.frame.cgRect.offsetBy(dx: -cropOrigin.x, dy: -cropOrigin.y)
        let frame = CGRect(
            x: topLeftFrame.minX,
            y: canvasHeight - topLeftFrame.maxY,
            width: topLeftFrame.width,
            height: topLeftFrame.height
        )
        let style = annotation.style
        context.saveGState()
        context.setAlpha(style.opacity)
        context.setStrokeColor(style.strokeColor.cgColor)
        context.setLineWidth(style.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        if let fill = style.fillColor { context.setFillColor(fill.cgColor) }

        switch annotation.kind {
        case .line, .arrow:
            let start = annotation.points.first?.cgPoint ?? CGPoint(x: frame.minX, y: frame.minY)
            let end = annotation.points.last?.cgPoint ?? CGPoint(x: frame.maxX, y: frame.maxY)
            let shiftedStart = CGPoint(x: start.x - cropOrigin.x, y: canvasHeight - (start.y - cropOrigin.y))
            let shiftedEnd = CGPoint(x: end.x - cropOrigin.x, y: canvasHeight - (end.y - cropOrigin.y))
            context.move(to: shiftedStart)
            context.addLine(to: shiftedEnd)
            context.strokePath()
            if annotation.kind == .arrow, style.arrowHead != .none {
                drawArrowHead(from: shiftedStart, to: shiftedEnd, width: style.lineWidth, in: context)
                if style.arrowHead == .both { drawArrowHead(from: shiftedEnd, to: shiftedStart, width: style.lineWidth, in: context) }
            }
        case .rectangle:
            if style.fillColor != nil { context.fill(frame) }
            context.stroke(frame)
        case .ellipse:
            if style.fillColor != nil { context.fillEllipse(in: frame) }
            context.strokeEllipse(in: frame)
        case .pen, .highlighter:
            guard let first = annotation.points.first else { break }
            context.setAlpha(annotation.kind == .highlighter ? min(style.opacity, 0.38) : style.opacity)
            context.move(to: CGPoint(x: first.x - cropOrigin.x, y: canvasHeight - (first.y - cropOrigin.y)))
            for point in annotation.points.dropFirst() {
                context.addLine(to: CGPoint(x: point.x - cropOrigin.x, y: canvasHeight - (point.y - cropOrigin.y)))
            }
            context.strokePath()
        case .redact:
            context.setFillColor((style.fillColor ?? .black).cgColor)
            context.fill(frame)
        case .counter:
            context.setFillColor(style.strokeColor.cgColor)
            context.fillEllipse(in: frame)
            drawText(String(annotation.counter ?? 1), in: frame, color: .white, size: style.fontSize, context: context)
        case .text:
            drawRichText(annotation, in: frame, context: context)
        case .blur, .pixelate, .crop:
            break
        }
        context.restoreGState()
    }

    private func drawArrowHead(from start: CGPoint, to end: CGPoint, width: CGFloat, in context: CGContext) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = max(14, width * 4)
        let spread = CGFloat.pi / 7
        context.move(to: end)
        context.addLine(to: CGPoint(x: end.x - length * cos(angle - spread), y: end.y - length * sin(angle - spread)))
        context.move(to: end)
        context.addLine(to: CGPoint(x: end.x - length * cos(angle + spread), y: end.y - length * sin(angle + spread)))
        context.strokePath()
    }

    private func drawText(_ text: String, in frame: CGRect, color: RGBAColor, size: Double, context: CGContext) {
        context.saveGState()
        let font = CTFontCreateWithName("SF Pro" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color.cgColor
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let typographicWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        context.textPosition = CGPoint(
            x: frame.minX + max(0, (frame.width - typographicWidth) / 2),
            y: frame.minY + max(0, (frame.height - size) / 2)
        )
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func drawRichText(_ annotation: Annotation, in frame: CGRect, context: CGContext) {
        let fallback = RichTextStyle(
            fontFamily: "SF Pro",
            fontSize: annotation.style.fontSize,
            foregroundColor: annotation.style.strokeColor
        )
        let document = annotation.richText ?? RichTextDocument(
            string: annotation.text ?? "",
            runs: []
        )
        guard !document.string.isEmpty, frame.width > 0, frame.height > 0 else { return }

        let attributed = NSMutableAttributedString(
            string: document.string,
            attributes: coreTextAttributes(for: fallback)
        )
        for run in document.runs {
            let location = min(max(0, run.location), attributed.length)
            let length = min(max(0, run.length), attributed.length - location)
            guard length > 0 else { continue }
            attributed.setAttributes(
                coreTextAttributes(for: run.style),
                range: NSRange(location: location, length: length)
            )
        }

        let textFrame = frame.insetBy(dx: 2, dy: 2)
        guard textFrame.width > 0, textFrame.height > 0 else { return }
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: textFrame, transform: nil)
        let coreTextFrame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: attributed.length),
            path,
            nil
        )

        context.saveGState()
        context.clip(to: frame)
        context.textMatrix = .identity
        drawTextDecorations(in: coreTextFrame, context: context, drawBackgrounds: true)
        CTFrameDraw(coreTextFrame, context)
        drawTextDecorations(in: coreTextFrame, context: context, drawBackgrounds: false)
        context.restoreGState()
    }

    private func coreTextAttributes(for style: RichTextStyle) -> [NSAttributedString.Key: Any] {
        let baseFont = CTFontCreateWithName(style.fontFamily as CFString, max(1, style.fontSize), nil)
        var traits: CTFontSymbolicTraits = []
        if style.isBold { traits.insert(.traitBold) }
        if style.isItalic { traits.insert(.traitItalic) }
        let font = CTFontCreateCopyWithSymbolicTraits(
            baseFont,
            max(1, style.fontSize),
            nil,
            traits,
            traits
        ) ?? baseFont

        var alignment: CTTextAlignment
        switch style.alignment {
        case .left: alignment = .left
        case .center: alignment = .center
        case .right: alignment = .right
        case .justified: alignment = .justified
        }
        let paragraph = withUnsafePointer(to: &alignment) { pointer in
            var setting = CTParagraphStyleSetting(
                spec: .alignment,
                valueSize: MemoryLayout<CTTextAlignment>.size,
                value: pointer
            )
            return CTParagraphStyleCreate(&setting, 1)
        }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: style.foregroundColor.cgColor,
            .paragraphStyle: paragraph,
            .underlineStyle: style.isUnderlined ? NSUnderlineStyle.single.rawValue : 0,
            Self.strikeMarkerKey: style.isStruckThrough
        ]
        if let background = style.backgroundColor {
            attributes[Self.backgroundMarkerKey] = background.cgColor
        }
        return attributes
    }

    private func drawTextDecorations(in frame: CTFrame, context: CGContext, drawBackgrounds: Bool) {
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        guard !lines.isEmpty else { return }
        var origins = Array(repeating: CGPoint.zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

        for (lineIndex, line) in lines.enumerated() {
            for runValue in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
                let attributes = CTRunGetAttributes(runValue) as NSDictionary
                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                var leading: CGFloat = 0
                let width = CGFloat(CTRunGetTypographicBounds(
                    runValue,
                    CFRange(location: 0, length: 0),
                    &ascent,
                    &descent,
                    &leading
                ))
                guard width > 0 else { continue }
                let range = CTRunGetStringRange(runValue)
                let xOffset = CTLineGetOffsetForStringIndex(line, range.location, nil)
                let origin = origins[lineIndex]

                if drawBackgrounds,
                   let colorValue = attributes[Self.backgroundMarkerKey.rawValue] {
                    let color = colorValue as! CGColor
                    context.setFillColor(color)
                    context.fill(CGRect(
                        x: origin.x + xOffset,
                        y: origin.y - descent,
                        width: width,
                        height: ascent + descent + leading
                    ))
                } else if !drawBackgrounds,
                          (attributes[Self.strikeMarkerKey.rawValue] as? Bool) == true {
                    let color: CGColor
                    if let colorValue = attributes[kCTForegroundColorAttributeName] {
                        color = colorValue as! CGColor
                    } else {
                        color = CGColor(gray: 0, alpha: 1)
                    }
                    context.setStrokeColor(color)
                    context.setLineWidth(max(1, ascent / 14))
                    let y = origin.y + ascent * 0.32
                    context.move(to: CGPoint(x: origin.x + xOffset, y: y))
                    context.addLine(to: CGPoint(x: origin.x + xOffset + width, y: y))
                    context.strokePath()
                }
            }
        }
    }

    private static let backgroundMarkerKey = NSAttributedString.Key("OpenSnapXRichTextBackground")
    private static let strikeMarkerKey = NSAttributedString.Key("OpenSnapXRichTextStrikethrough")

    private func drawBackdrop(around image: CGImage, configuration: BackdropConfiguration) throws -> CGImage {
        let padding = max(0, configuration.padding)
        let naturalSize = CGSize(width: Double(image.width) + padding * 2, height: Double(image.height) + padding * 2)
        var outputSize = naturalSize
        switch configuration.aspect {
        case .automatic: break
        case .square:
            let side = max(naturalSize.width, naturalSize.height)
            outputSize = CGSize(width: side, height: side)
        case .fourByThree:
            outputSize = fittedCanvas(content: naturalSize, aspect: 4.0 / 3.0)
        case .sixteenByNine:
            outputSize = fittedCanvas(content: naturalSize, aspect: 16.0 / 9.0)
        }
        guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: Int(ceil(outputSize.width)),
                height: Int(ceil(outputSize.height)),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { throw OpenSnapXError.captureFailed("Could not create the backdrop renderer.") }
        let canvas = CGRect(origin: .zero, size: outputSize)
        if configuration.useGradient,
           let gradient = CGGradient(colorsSpace: colorSpace, colors: [configuration.startColor.cgColor, configuration.endColor.cgColor] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: canvas.maxX, y: canvas.maxY), options: [])
        } else {
            context.setFillColor(configuration.startColor.cgColor)
            context.fill(canvas)
        }
        let imageRect = CGRect(
            x: (outputSize.width - Double(image.width)) / 2,
            y: (outputSize.height - Double(image.height)) / 2,
            width: Double(image.width),
            height: Double(image.height)
        )
        let path = CGPath(roundedRect: imageRect, cornerWidth: configuration.cornerRadius, cornerHeight: configuration.cornerRadius, transform: nil)
        if configuration.shadowRadius > 0 {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -6), blur: configuration.shadowRadius, color: NSColor.black.withAlphaComponent(0.32).cgColor)
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(path)
            context.fillPath()
            context.restoreGState()
        }
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.draw(image, in: imageRect)
        context.restoreGState()
        guard let result = context.makeImage() else { throw OpenSnapXError.captureFailed("Could not finish the backdrop.") }
        return result
    }

    private func fittedCanvas(content: CGSize, aspect: Double) -> CGSize {
        if content.width / content.height > aspect {
            return CGSize(width: content.width, height: content.width / aspect)
        }
        return CGSize(width: content.height * aspect, height: content.height)
    }
}
