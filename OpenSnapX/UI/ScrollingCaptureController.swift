import AppKit

@MainActor
final class ScrollingCaptureController {
    private let captureService: any CaptureService
    private let engine: any ScrollingCaptureEngine
    private var panel: NSPanel?
    private var statusLabel: NSTextField?
    private var captureTask: Task<Void, Never>?
    private var frames: [ImagePayload] = []
    private var fingerprints: [UInt64] = []
    private var continuation: CheckedContinuation<ImagePayload, Error>?
    private var request: CaptureRequest?
    private var finished = false

    init(captureService: any CaptureService, engine: any ScrollingCaptureEngine) {
        self.captureService = captureService
        self.engine = engine
    }

    func start(request: CaptureRequest) async throws -> ImagePayload {
        cancel()
        self.request = request
        frames = []
        fingerprints = []
        finished = false
        showHUD()
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            captureTask = Task { [weak self] in await self?.captureLoop() }
        }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        captureTask?.cancel()
        captureTask = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        do {
            guard !frames.isEmpty else { throw OpenSnapXError.selectionCancelled }
            let image = try engine.stitch(frames)
            continuation?.resume(returning: image)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func cancel() {
        guard !finished, continuation != nil || panel != nil else { return }
        finished = true
        captureTask?.cancel()
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        continuation?.resume(throwing: OpenSnapXError.selectionCancelled)
        continuation = nil
    }

    private func captureLoop() async {
        guard let request else { return }
        var failedMatches = 0
        while !Task.isCancelled, frames.count < 80 {
            do {
                let result = try await captureService.capture(request)
                let payload = ImagePayload(image: result.image)
                let fingerprint = fingerprint(result.image)
                if fingerprints.last != fingerprint {
                    if let previous = frames.last {
                        do {
                            _ = try engine.match(previous: previous, next: payload)
                            failedMatches = 0
                            frames.append(payload)
                            fingerprints.append(fingerprint)
                        } catch {
                            failedMatches += 1
                            statusLabel?.stringValue = "Overlap not found — scroll more slowly (\(frames.count) frames kept)"
                        }
                    } else {
                        frames.append(payload)
                        fingerprints.append(fingerprint)
                    }
                    if failedMatches == 0 { statusLabel?.stringValue = "Scroll naturally • \(frames.count) frames captured" }
                }
            } catch {
                statusLabel?.stringValue = error.localizedDescription
            }
            try? await Task.sleep(for: .milliseconds(420))
        }
        if frames.count >= 80 { statusLabel?.stringValue = "Maximum length reached — choose Finish" }
    }

    private func showHUD() {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 430, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        let status = NSTextField(labelWithString: "Start scrolling • 0 frames captured")
        status.lineBreakMode = .byTruncatingTail
        let finishButton = NSButton(title: "Finish", target: self, action: #selector(finishAction))
        finishButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelAction))
        let stack = NSStackView(views: [status, NSView(), finishButton, cancelButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor), stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor), stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
        ])
        panel.contentView = effect
        if let screen = DisplayGeometry.screen(containing: NSEvent.mouseLocation) ?? NSScreen.main {
            panel.setFrameOrigin(CGPoint(x: screen.visibleFrame.midX - 215, y: screen.visibleFrame.maxY - 86))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        statusLabel = status
    }

    @objc private func finishAction() { finish() }
    @objc private func cancelAction() { cancel() }

    private func fingerprint(_ image: CGImage) -> UInt64 {
        let width = 32
        let height = 32
        var bytes = [UInt8](repeating: 0, count: width * height)
        guard let space = CGColorSpace(name: CGColorSpace.linearGray),
              let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }
}

