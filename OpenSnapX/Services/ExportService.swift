import AppKit
import UniformTypeIdentifiers

@MainActor
final class ExportService {
    func copy(_ image: CGImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))])
    }

    func copyText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func save(_ image: CGImage, suggestedName: String? = nil, format: ExportFormat = .png) async throws -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName ?? defaultFilename(format: format)
        panel.allowedContentTypes = [format == .png ? .png : .jpeg]
        guard await panel.begin() == .OK, let url = panel.url else { return nil }
        try ImageCodec.data(from: image, format: format).write(to: url, options: .atomic)
        return url
    }

    func share(_ image: CGImage, relativeTo rect: NSRect, of view: NSView) {
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        NSSharingServicePicker(items: [nsImage]).show(relativeTo: rect, of: view, preferredEdge: .minY)
    }

    func defaultFilename(format: ExportFormat = .png, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "OpenSnapX \(formatter.string(from: date)).\(format == .png ? "png" : "jpg")"
    }
}
