import AppKit
import Darwin

@MainActor
protocol AgentSkillInstalling: AnyObject {
    func install(scope: AgentSkillInstallScope, presentingWindow: NSWindow?) throws -> URL?
}

@MainActor
final class LocalAgentSkillInstaller: AgentSkillInstalling {
    private let fileManager: FileManager
    private let bundle: Bundle

    init(fileManager: FileManager = .default, bundle: Bundle = .main) {
        self.fileManager = fileManager
        self.bundle = bundle
    }

    func install(scope: AgentSkillInstallScope, presentingWindow: NSWindow?) throws -> URL? {
        guard let sourceURL = bundle.url(forResource: "opensnapx-ocr", withExtension: nil) else {
            throw AgentSkillInstallerError.missingBundledSkill
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Install Here"

        switch scope {
        case .global:
            panel.title = "Install OpenSnapX OCR Skill Globally"
            panel.message = "Choose your global .agents/skills folder. OpenSnapX will install opensnapx-ocr inside it."
            panel.directoryURL = Self.globalSkillsDirectory
        case .project:
            panel.title = "Install OpenSnapX OCR Skill in a Project"
            panel.message = "Choose the project root. OpenSnapX will install .agents/skills/opensnapx-ocr inside it."
            panel.directoryURL = Self.userHomeDirectory
        }

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return nil }
        let destination: URL
        switch scope {
        case .global:
            if selectedURL.lastPathComponent == "opensnapx-ocr",
               selectedURL.deletingLastPathComponent().lastPathComponent == "skills" {
                destination = selectedURL
            } else if selectedURL.lastPathComponent == "skills",
                      selectedURL.deletingLastPathComponent().lastPathComponent == ".agents" {
                destination = selectedURL.appendingPathComponent("opensnapx-ocr", isDirectory: true)
            } else if selectedURL.lastPathComponent == ".agents" {
                destination = selectedURL
                    .appendingPathComponent("skills", isDirectory: true)
                    .appendingPathComponent("opensnapx-ocr", isDirectory: true)
            } else {
                destination = selectedURL
                    .appendingPathComponent(".agents", isDirectory: true)
                    .appendingPathComponent("skills", isDirectory: true)
                    .appendingPathComponent("opensnapx-ocr", isDirectory: true)
            }
        case .project:
            destination = selectedURL
                .appendingPathComponent(".agents", isDirectory: true)
                .appendingPathComponent("skills", isDirectory: true)
                .appendingPathComponent("opensnapx-ocr", isDirectory: true)
        }

        let destinationExists = fileManager.fileExists(atPath: destination.path)
        if destinationExists {
            let confirmation = NSAlert()
            confirmation.messageText = "Update the existing OpenSnapX OCR skill?"
            confirmation.informativeText = destination.path
            confirmation.addButton(withTitle: "Update")
            confirmation.addButton(withTitle: "Cancel")
            guard confirmation.runModal() == .alertFirstButtonReturn else { return nil }
        }

        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let stagingURL = parent.appendingPathComponent(
            ".opensnapx-ocr-install-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: stagingURL) }
        try fileManager.copyItem(at: sourceURL, to: stagingURL)
        for scriptName in ["connect.sh", "call.sh"] {
            let script = stagingURL.appendingPathComponent("scripts/\(scriptName)")
            guard fileManager.fileExists(atPath: script.path) else {
                throw AgentSkillInstallerError.missingBundledSkill
            }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        }

        guard destinationExists else {
            try fileManager.moveItem(at: stagingURL, to: destination)
            return destination
        }

        let backupURL = parent.appendingPathComponent(
            ".opensnapx-ocr-backup-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.moveItem(at: destination, to: backupURL)
        do {
            try fileManager.moveItem(at: stagingURL, to: destination)
            try? fileManager.removeItem(at: backupURL)
        } catch {
            if !fileManager.fileExists(atPath: destination.path) {
                try? fileManager.moveItem(at: backupURL, to: destination)
            }
            throw error
        }
        return destination
    }

    static var globalSkillsDirectory: URL {
        userHomeDirectory
            .appendingPathComponent(".agents", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
    }

    private static var userHomeDirectory: URL {
        guard let passwordEntry = getpwuid(getuid()),
              let homePath = passwordEntry.pointee.pw_dir else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: String(cString: homePath), isDirectory: true)
    }

    static func mcpConfiguration(for skillURL: URL) -> String {
        let connector = skillURL.appendingPathComponent("scripts/connect.sh").path
        let configuration: [String: Any] = [
            "mcpServers": [
                "opensnapx": [
                    "command": connector
                ]
            ]
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: configuration,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

private enum AgentSkillInstallerError: LocalizedError {
    case missingBundledSkill

    var errorDescription: String? {
        switch self {
        case .missingBundledSkill:
            "The bundled opensnapx-ocr agent skill could not be found."
        }
    }
}
