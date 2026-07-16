import AppKit

@MainActor
final class HistoryWindowController: NSWindowController, NSCollectionViewDataSource, NSCollectionViewDelegate {
    var onOpen: ((UUID) -> Void)?
    var onCopy: ((UUID) -> Void)?
    var onPin: ((UUID) -> Void)?
    var onDelete: ((UUID) -> Void)?

    private var sessions: [CaptureSession] = []
    private var thumbnails: [UUID: CGImage] = [:]
    private let collectionView = NSCollectionView()
    private let emptyLabel = NSTextField(labelWithString: "No recent captures")

    init() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 860, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenSnapX History"
        window.minSize = CGSize(width: 560, height: 360)
        super.init(window: window)
        configure()
    }

    required init?(coder: NSCoder) { nil }

    func update(_ sessions: [CaptureSession], thumbnails: [UUID: CGImage] = [:]) {
        self.sessions = sessions
        self.thumbnails = thumbnails
        collectionView.reloadData()
        emptyLabel.isHidden = !sessions.isEmpty
    }

    func show() {
        ApplicationPresentation.activateRegularApplication()
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { sessions.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: HistoryItem.identifier, for: indexPath) as! HistoryItem
        let session = sessions[indexPath.item]
        item.configure(session: session, image: thumbnails[session.id])
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let index = indexPaths.first?.item, sessions.indices.contains(index) else { return }
        onOpen?(sessions[index].id)
    }

    private func configure() {
        guard let content = window?.contentView else { return }
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = CGSize(width: 190, height: 156)
        layout.sectionInset = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        layout.minimumInteritemSpacing = 14
        layout.minimumLineSpacing = 14
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.register(HistoryItem.self, forItemWithIdentifier: HistoryItem.identifier)
        collectionView.backgroundColors = [.windowBackgroundColor]

        let scroll = NSScrollView()
        scroll.documentView = collectionView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        emptyLabel.font = .systemFont(ofSize: 18, weight: .medium)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor), scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor), emptyLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])

        let toolbar = NSToolbar(identifier: "HistoryToolbar")
        toolbar.delegate = self
        window?.toolbar = toolbar
    }

    private func selectedID() -> UUID? {
        guard let index = collectionView.selectionIndexPaths.first?.item, sessions.indices.contains(index) else { return nil }
        return sessions[index].id
    }

    @objc private func openSelected() { if let id = selectedID() { onOpen?(id) } }
    @objc private func copySelected() { if let id = selectedID() { onCopy?(id) } }
    @objc private func pinSelected() { if let id = selectedID() { onPin?(id) } }
    @objc private func deleteSelected() { if let id = selectedID() { onDelete?(id) } }
}

extension HistoryWindowController: NSToolbarDelegate {
    nonisolated func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.open, .copy, .pin, .delete, .flexibleSpace]
    }

    nonisolated func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.open, .copy, .pin, .flexibleSpace, .delete]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier {
        case .open: item.label = "Open"; item.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "Open"); item.action = #selector(openSelected)
        case .copy: item.label = "Copy"; item.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy"); item.action = #selector(copySelected)
        case .pin: item.label = "Pin"; item.image = NSImage(systemSymbolName: "pin", accessibilityDescription: "Pin"); item.action = #selector(pinSelected)
        case .delete: item.label = "Delete"; item.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete"); item.action = #selector(deleteSelected)
        default: return nil
        }
        item.target = self
        return item
    }
}

private extension NSToolbarItem.Identifier {
    static let open = NSToolbarItem.Identifier("Open")
    static let copy = NSToolbarItem.Identifier("Copy")
    static let pin = NSToolbarItem.Identifier("Pin")
    static let delete = NSToolbarItem.Identifier("Delete")
}

@MainActor
private final class HistoryItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("HistoryItem")
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let thumbnailView = NSImageView()

    override func loadView() {
        view = NSVisualEffectView()
        (view as? NSVisualEffectView)?.material = .contentBackground
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.borderColor = NSColor.separatorColor.cgColor
        view.layer?.borderWidth = 1
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = 7
        thumbnailView.layer?.masksToBounds = true
        thumbnailView.heightAnchor.constraint(equalToConstant: 92).isActive = true
        thumbnailView.widthAnchor.constraint(equalToConstant: 168).isActive = true
        let stack = NSStackView(views: [thumbnailView, titleLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor), stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -8)
        ])
    }

    override var isSelected: Bool {
        didSet { view.layer?.borderColor = isSelected ? NSColor.controlAccentColor.cgColor : NSColor.separatorColor.cgColor; view.layer?.borderWidth = isSelected ? 2 : 1 }
    }

    func configure(session: CaptureSession, image: CGImage?) {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        titleLabel.stringValue = formatter.localizedString(for: session.manifest.createdAt, relativeTo: Date())
        detailLabel.stringValue = "\(session.manifest.pixelWidth) × \(session.manifest.pixelHeight)"
        detailLabel.textColor = .secondaryLabelColor
        if let image {
            thumbnailView.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        } else {
            thumbnailView.image = NSImage(systemSymbolName: "photo", accessibilityDescription: "Screenshot")
        }
        view.setAccessibilityLabel("Screenshot from \(titleLabel.stringValue), \(detailLabel.stringValue)")
    }
}
