import AppKit

@MainActor
final class PinnedImageController: NSObject, NSWindowDelegate {
    private var panels: [NSPanel] = []

    func pin(_ image: CGImage) {
        let aspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
        let width: CGFloat = min(520, CGFloat(image.width))
        let height = min(420, width / aspect)
        let panel = PinnedPanel(
            contentRect: CGRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentAspectRatio = CGSize(width: image.width, height: image.height)
        panel.minSize = CGSize(width: 120, height: 80)
        panel.delegate = self
        panel.contentView = PinnedContentView(image: image, panel: panel)
        panel.center()
        panel.orderFrontRegardless()
        panels.append(panel)
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel else { return }
        panels.removeAll { $0 === panel }
    }
}

private final class PinnedPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}

@MainActor
private final class PinnedContentView: NSView {
    private let pinnedImage: NSImage
    private weak var panel: NSPanel?

    init(image: CGImage, panel: NSPanel) {
        pinnedImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        self.panel = panel
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        let imageView = NSImageView(image: pinnedImage)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close pinned image")!, target: self, action: #selector(closePinned))
        close.isBordered = false
        close.contentTintColor = .white
        close.translatesAutoresizingMaskIntoConstraints = false
        addSubview(close)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor), imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor), imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), close.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            close.widthAnchor.constraint(equalToConstant: 24), close.heightAnchor.constraint(equalToConstant: 24)
        ])

        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copyImage), keyEquivalent: "")
        menu.addItem(withTitle: "Share…", action: #selector(shareImage), keyEquivalent: "")
        let opacity = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu()
        for value in [100, 75, 50] {
            let item = NSMenuItem(title: "\(value)%", action: #selector(setOpacity(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = value
            opacityMenu.addItem(item)
        }
        opacity.submenu = opacityMenu
        menu.addItem(opacity)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close", action: #selector(closePinned), keyEquivalent: "")
        for item in menu.items where item.target == nil { item.target = self }
        self.menu = menu
    }

    required init?(coder: NSCoder) { nil }

    @objc private func copyImage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([pinnedImage])
    }

    @objc private func shareImage() {
        NSSharingServicePicker(items: [pinnedImage]).show(relativeTo: bounds, of: self, preferredEdge: .minY)
    }

    @objc private func setOpacity(_ sender: NSMenuItem) {
        panel?.alphaValue = CGFloat((sender.representedObject as? Int ?? 100)) / 100
    }

    @objc private func closePinned() { panel?.close() }
}
