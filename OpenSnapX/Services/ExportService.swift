import AppKit
import UniformTypeIdentifiers

@MainActor
final class ExportService {
    private var copyRequestID = 0

    func copy(_ image: CGImage, displayScale: Double = 1) async {
        copyRequestID &+= 1
        let requestID = copyRequestID
        let dpi = ImageCodec.dpi(forDisplayScale: displayScale)
        let payload = ImagePayload(image: image)
        let data = try? await Task.detached(priority: .userInitiated) {
            try ImageCodec.data(from: payload.image, format: .png, dpi: dpi)
        }.value
        guard requestID == copyRequestID, !Task.isCancelled else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let data {
            pasteboard.setData(data, forType: .png)
        } else {
            pasteboard.writeObjects([NSImage(
                cgImage: image,
                size: logicalSize(of: image, displayScale: displayScale)
            )])
        }
    }

    func copyText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func save(
        _ image: CGImage,
        suggestedName: String? = nil,
        format: ExportFormat = .png,
        displayScale: Double = 1
    ) async throws -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName ?? defaultFilename(format: format)
        panel.allowedContentTypes = [format == .png ? .png : .jpeg]
        guard await panel.begin() == .OK, let url = panel.url else { return nil }
        let dpi = ImageCodec.dpi(forDisplayScale: displayScale)
        let payload = ImagePayload(image: image)
        try await Task.detached(priority: .userInitiated) {
            let data = try ImageCodec.data(
                from: payload.image,
                format: format,
                dpi: dpi
            )
            try data.write(to: url, options: .atomic)
        }.value
        return url
    }

    func share(_ image: CGImage, displayScale: Double = 1, relativeTo rect: NSRect, of view: NSView) {
        let nsImage = NSImage(
            cgImage: image,
            size: logicalSize(of: image, displayScale: displayScale)
        )
        NSSharingServicePicker(items: [nsImage]).show(relativeTo: rect, of: view, preferredEdge: .minY)
    }

    func defaultFilename(format: ExportFormat = .png, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "OpenSnapX \(formatter.string(from: date)).\(format == .png ? "png" : "jpg")"
    }

    private func logicalSize(of image: CGImage, displayScale: Double) -> NSSize {
        let scale = max(1, displayScale)
        return NSSize(
            width: Double(image.width) / scale,
            height: Double(image.height) / scale
        )
    }
}
