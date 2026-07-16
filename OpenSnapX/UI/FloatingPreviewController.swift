import AppKit

@MainActor
final class FloatingPreviewController {
    struct Actions {
        var edit: () -> Void
        var copy: () -> Void
        var save: () -> Void
        var share: (NSView) -> Void
        var pin: () -> Void
        var dismiss: () -> Void
    }

    private var panels: [UUID: NSPanel] = [:]
    private var dismissalTasks: [UUID: Task<Void, Never>] = [:]

    func show(id: UUID, image: CGImage, duration: TimeInterval, actions: Actions) {
        dismiss(id: id)
        let imageAspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
        let width: CGFloat = 300
        let imageHeight = min(210, max(110, width / imageAspect))
        let panel = PreviewPanel(
            contentRect: CGRect(x: 0, y: 0, width: width, height: imageHeight + 48),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        let view = PreviewContentView(image: image, actions: actions)
        panel.contentView = view
        position(panel, stackIndex: panels.count)
        panels[id] = panel
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 1
        }

        guard duration > 0 else { return }
        dismissalTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.dismiss(id: id)
        }
    }

    func dismiss(id: UUID) {
        dismissalTasks[id]?.cancel()
        dismissalTasks[id] = nil
        guard let panel = panels.removeValue(forKey: id) else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil); panel.close() }
        })
    }

    private func position(_ panel: NSPanel, stackIndex: Int) {
        let mouseScreen = DisplayGeometry.screen(containing: NSEvent.mouseLocation) ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = mouseScreen?.visibleFrame else { return }
        let x = visible.maxX - panel.frame.width - 18
        let y = visible.minY + 18 + CGFloat(stackIndex) * 22
        panel.setFrameOrigin(CGPoint(x: x, y: y))
    }
}

private final class PreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class PreviewContentView: NSVisualEffectView {
    private let actions: FloatingPreviewController.Actions

    init(image: CGImage, actions: FloatingPreviewController.Actions) {
        self.actions = actions
        super.init(frame: .zero)
        material = .hudWindow
        state = .active
        blendingMode = .behindWindow
        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.masksToBounds = true

        let imageView = DraggableImageView(image: image)
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.08).cgColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.onClick = actions.edit
        addSubview(imageView)

        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 4
        controls.edgeInsets = NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 6)
        controls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controls)

        controls.addArrangedSubview(button("doc.on.doc", help: "Copy", action: actions.copy))
        controls.addArrangedSubview(button("square.and.pencil", help: "Annotate", action: actions.edit))
        controls.addArrangedSubview(button("pin", help: "Pin", action: actions.pin))
        controls.addArrangedSubview(button("square.and.arrow.up", help: "Share", action: { [weak self] in
            guard let self else { return }
            actions.share(self)
        }))
        controls.addArrangedSubview(button("square.and.arrow.down", help: "Save", action: actions.save))
        controls.addArrangedSubview(NSView())
        controls.addArrangedSubview(button("xmark", help: "Dismiss", action: actions.dismiss))

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: controls.topAnchor),
            controls.leadingAnchor.constraint(equalTo: leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor),
            controls.bottomAnchor.constraint(equalTo: bottomAnchor),
            controls.heightAnchor.constraint(equalToConstant: 42)
        ])
    }

    required init?(coder: NSCoder) { nil }

    private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> NSButton {
        let button = ActionButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: help)!, action: action)
        button.toolTip = help
        button.isBordered = false
        button.bezelStyle = .inline
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.setAccessibilityLabel(help)
        return button
    }
}

@MainActor
private final class ActionButton: NSButton {
    private let closure: () -> Void

    init(image: NSImage, action: @escaping () -> Void) {
        closure = action
        super.init(frame: .zero)
        self.image = image
        target = self
        self.action = #selector(invoke)
    }

    required init?(coder: NSCoder) { nil }
    @objc private func invoke() { closure() }
}

@MainActor
private final class DraggableImageView: NSImageView, NSDraggingSource {
    var onClick: (() -> Void)?
    private let dragImage: NSImage
    private var mouseDownPoint: CGPoint = .zero

    init(image: CGImage) {
        dragImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        super.init(frame: .zero)
        self.image = dragImage
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 0, bounds.height > 0,
              dragImage.size.width > 0, dragImage.size.height > 0 else { return }
        let scale = min(
            bounds.width / dragImage.size.width,
            bounds.height / dragImage.size.height
        )
        let size = CGSize(
            width: dragImage.size.width * scale,
            height: dragImage.size.height * scale
        )
        let destination = CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        NSGraphicsContext.current?.imageInterpolation = .high
        dragImage.draw(
            in: destination,
            from: CGRect(origin: .zero, size: dragImage.size),
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard hypot(event.locationInWindow.x - mouseDownPoint.x, event.locationInWindow.y - mouseDownPoint.y) > 4 else { return }
        let item = NSDraggingItem(pasteboardWriter: dragImage)
        item.setDraggingFrame(bounds, contents: dragImage)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) { onClick?() }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

