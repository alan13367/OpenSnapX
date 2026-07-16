import AppKit

@MainActor
final class CapturePaletteWindowController: NSWindowController {
    var onCapture: ((CaptureMode, Int) -> Void)?
    private let delay = NSPopUpButton()

    init() {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 520, height: 150), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Capture with OpenSnapX"
        panel.level = .floating
        super.init(window: panel)
        configure()
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        showWindow(nil); window?.center(); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    private func configure() {
        guard let content = window?.contentView else { return }
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.distribution = .fillEqually
        buttons.spacing = 8
        for mode in CaptureMode.allCases {
            let button = PaletteButton(mode: mode) { [weak self] mode in self?.capture(mode) }
            button.title = mode.displayName.replacingOccurrences(of: "Capture ", with: "")
            button.bezelStyle = .regularSquare
            buttons.addArrangedSubview(button)
        }
        delay.addItems(withTitles: ["No delay", "3 seconds", "5 seconds", "10 seconds"])
        let stack = NSStackView(views: [buttons, delay])
        stack.orientation = .vertical
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
    }

    private func capture(_ mode: CaptureMode) {
        let value = [0, 3, 5, 10][delay.indexOfSelectedItem]
        close()
        onCapture?(mode, value)
    }
}

@MainActor
private final class PaletteButton: NSButton {
    private let mode: CaptureMode
    private let closure: (CaptureMode) -> Void
    init(mode: CaptureMode, action: @escaping (CaptureMode) -> Void) {
        self.mode = mode; closure = action
        super.init(frame: .zero); target = self; self.action = #selector(invoke)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func invoke() { closure(mode) }
}
