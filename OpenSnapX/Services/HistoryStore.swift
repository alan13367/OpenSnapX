import CoreGraphics
import Foundation

protocol HistoryStore: Sendable {
    func create(from result: CaptureResult) async throws -> CaptureSession
    func list() async -> [CaptureSession]
    func load(id: UUID) async throws -> (CaptureSession, ImagePayload)
    func save(_ session: CaptureSession) async throws
    func delete(id: UUID) async throws
    func cleanup(retentionDays: Int) async
    func thumbnail(id: UUID) async throws -> ImagePayload
}

actor LocalHistoryStore: HistoryStore {
    private let fileManager: FileManager
    private let rootURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default, rootURL: URL? = nil) {
        self.fileManager = fileManager
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.rootURL = applicationSupport
                .appendingPathComponent("OpenSnapX", isDirectory: true)
                .appendingPathComponent("History", isDirectory: true)
        }
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func create(from result: CaptureResult) async throws -> CaptureSession {
        try ensureRoot()
        let session = CaptureSession(captureResult: result)
        let temporaryURL = rootURL.appendingPathComponent(".\(result.id.uuidString).tmp", isDirectory: true)
        let finalURL = packageURL(for: result.id)

        try? fileManager.removeItem(at: temporaryURL)
        try fileManager.createDirectory(at: temporaryURL, withIntermediateDirectories: true)
        do {
            try ImageCodec.write(
                result.image,
                to: temporaryURL.appendingPathComponent("source.png"),
                format: .png
            )
            let thumbnail = try ImageCodec.thumbnail(from: result.image)
            try ImageCodec.write(
                thumbnail,
                to: temporaryURL.appendingPathComponent("thumbnail.jpg"),
                format: .jpeg,
                quality: 0.82
            )
            try writeMetadata(session, into: temporaryURL)
            try? fileManager.removeItem(at: finalURL)
            try fileManager.moveItem(at: temporaryURL, to: finalURL)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
        return session
    }

    func list() async -> [CaptureSession] {
        guard (try? ensureRoot()) != nil else { return [] }
        let urls = (try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.compactMap { try? readSession(at: $0) }
            .sorted { $0.manifest.createdAt > $1.manifest.createdAt }
    }

    func load(id: UUID) async throws -> (CaptureSession, ImagePayload) {
        let url = packageURL(for: id)
        let session = try readSession(at: url)
        let image = try ImageCodec.image(at: url.appendingPathComponent("source.png"))
        return (session, ImagePayload(image: image))
    }

    func save(_ session: CaptureSession) async throws {
        let url = packageURL(for: session.id)
        guard fileManager.fileExists(atPath: url.path) else { throw OpenSnapXError.invalidHistoryEntry }
        var updated = session
        updated.manifest.modifiedAt = Date()
        try writeMetadata(updated, into: url)
    }

    func delete(id: UUID) async throws {
        let url = packageURL(for: id)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    func cleanup(retentionDays: Int) async {
        guard retentionDays > 0 else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? .distantPast
        for session in await list() where session.manifest.createdAt < cutoff {
            try? fileManager.removeItem(at: packageURL(for: session.id))
        }
        guard let partials = try? fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) else { return }
        for url in partials where url.lastPathComponent.hasPrefix(".") && url.pathExtension == "tmp" {
            try? fileManager.removeItem(at: url)
        }
    }

    func thumbnail(id: UUID) async throws -> ImagePayload {
        ImagePayload(image: try ImageCodec.image(at: packageURL(for: id).appendingPathComponent("thumbnail.jpg")))
    }

    private func packageURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent("\(id.uuidString).opensnapx", isDirectory: true)
    }

    private func ensureRoot() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    private func writeMetadata(_ session: CaptureSession, into directory: URL) throws {
        try encoder.encode(session.manifest)
            .write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        try encoder.encode(session.annotations)
            .write(to: directory.appendingPathComponent("annotations.json"), options: .atomic)
        try encoder.encode(session.ocrResults)
            .write(to: directory.appendingPathComponent("ocr.json"), options: .atomic)
    }

    private func readSession(at directory: URL) throws -> CaptureSession {
        let manifest = try decoder.decode(
            CaptureManifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        )
        guard manifest.schemaVersion == CaptureManifest.currentSchemaVersion,
              fileManager.fileExists(atPath: directory.appendingPathComponent("source.png").path) else {
            throw OpenSnapXError.invalidHistoryEntry
        }
        let annotations = (try? decoder.decode(
            [Annotation].self,
            from: Data(contentsOf: directory.appendingPathComponent("annotations.json"))
        )) ?? []
        let ocr = (try? decoder.decode(
            [OCRResult].self,
            from: Data(contentsOf: directory.appendingPathComponent("ocr.json"))
        )) ?? []
        return CaptureSession(manifest: manifest, annotations: annotations, ocrResults: ocr)
    }
}
