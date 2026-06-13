import AppKit

final class SettingsPopover {
    var onChange: ((ClawdexConfig) -> Void)?

    private let popover = NSPopover()
    private let controller = SettingsViewController()

    init() {
        popover.behavior = .transient
        popover.contentViewController = controller
        controller.onChange = { [weak self] config in self?.onChange?(config) }
    }

    func show(from view: NSView, rect: NSRect, config: ClawdexConfig) {
        controller.setConfig(config)
        if popover.isShown {
            popover.close()
        } else {
            popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        }
    }
}

private final class SettingsViewController: NSViewController {
    var onChange: ((ClawdexConfig) -> Void)?

    private var config = ClawdexConfig()
    private let messagesControl = NSSegmentedControl(
        labels: ["All", "Final only", "None"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let switchboardControl = NSSegmentedControl(
        labels: ["Yes", "No"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 230, height: 102))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 11
        stack.translatesAutoresizingMaskIntoConstraints = false

        messagesControl.target = self
        messagesControl.action = #selector(messagesChanged)
        switchboardControl.target = self
        switchboardControl.action = #selector(switchboardChanged)

        stack.addArrangedSubview(row(label: "Show messages", control: messagesControl))
        stack.addArrangedSubview(row(label: "Show switchboard", control: switchboardControl))
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14)
        ])
        view = root
    }

    func setConfig(_ config: ClawdexConfig) {
        self.config = config
        messagesControl.selectedSegment = MessageVisibility.allCases.firstIndex(of: config.messageVisibility) ?? 0
        switchboardControl.selectedSegment = config.showSwitchboard ? 0 : 1
    }

    @objc private func messagesChanged() {
        let selected = MessageVisibility.allCases[safe: messagesControl.selectedSegment] ?? .all
        config.messageVisibility = selected
        onChange?(config)
    }

    @objc private func switchboardChanged() {
        config.showSwitchboard = switchboardControl.selectedSegment == 0
        onChange?(config)
    }

    private func row(label text: String, control: NSControl) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        let stack = NSStackView(views: [label, control])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
