import AppKit
import QuartzCore

/// A two-line broadcast-style ticker, cycling through recent GitHub chains.
final class GitHubScorebugWindow: NSPanel {
    struct Item {
        var id: String
        var title: String
        var glyph: String
        var status: String
        var compactStatus: String? = nil
    }
    private let floor = ScorebugView()
    let button = NSButton()
    private(set) var items: [Item] = []
    private(set) var currentIndex = 0
    var currentItem: Item? { items.indices.contains(currentIndex) ? items[currentIndex] : nil }
    private var timer: Timer?
    private let rotationInterval: TimeInterval
    private var paused = false
    var onSelect: ((String) -> Void)?

    init(rotationInterval: TimeInterval = 8) {
        self.rotationInterval = rotationInterval
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: CompanionLayout.floorHeight),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = true
        level = .floating; alphaValue = 1; hidesOnDeactivate = false; isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        contentView = floor
        button.isBordered = false; button.target = self; button.action = #selector(selected)
        button.lineBreakMode = .byTruncatingTail
        button.cell?.wraps = false; button.cell?.usesSingleLineMode = false
        button.wantsLayer = true
        floor.addSubview(button); floor.button = button
        floor.onHover = { [weak self] hovered in
            self?.paused = hovered; self?.restartTimer()
        }
    }
    deinit { timer?.invalidate() }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func setItems(_ items: [Item]) {
        let previous = currentItem?.id
        self.items = Array(items.prefix(4))
        currentIndex = self.items.firstIndex { $0.id == previous } ?? 0
        render(animated: false)
        // Webhook refreshes must not restart the dwell and starve the carousel.
        if currentItem?.id != previous || self.items.count < 2 || timer == nil { restartTimer() }
    }
    override func orderFrontRegardless() { super.orderFrontRegardless(); if timer == nil { restartTimer() } }
    override func orderOut(_ sender: Any?) { stopTimer(); super.orderOut(sender) }
    override func close() { stopTimer(); super.close() }

    func advance() {
        guard isVisible, !paused, items.count > 1 else { return }
        currentIndex = (currentIndex + 1) % items.count
        render(animated: true)
    }
    private func stopTimer() { timer?.invalidate(); timer = nil }
    private func restartTimer() {
        stopTimer()
        guard isVisible, !paused, items.count > 1 else { return }
        let timer = Timer(timeInterval: rotationInterval, repeats: true) { [weak self] _ in self?.advance() }
        timer.tolerance = min(0.5, rotationInterval / 10)
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    private func render(animated: Bool) {
        guard let item = currentItem else {
            button.attributedTitle = NSAttributedString(string: "")
            button.isEnabled = false; button.toolTip = nil; return
        }
        button.isEnabled = true
        button.identifier = NSUserInterfaceItemIdentifier(item.id)
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let transition = CATransition(); transition.type = .push; transition.subtype = .fromTop
            transition.duration = 0.3
            button.layer?.add(transition, forKey: "rotate")
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center; paragraph.lineBreakMode = .byTruncatingTail
        let title = NSMutableAttributedString(string: item.title + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
        ])
        let position = items.count > 1 ? "  ·  \(currentIndex + 1)/\(items.count)" : ""
        title.append(NSAttributedString(string: "\(item.glyph) \(item.compactStatus ?? item.status)\(position)", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph
        ]))
        button.attributedTitle = title
        button.toolTip = "\(item.title) · \(item.status) · Open on GitHub"
        button.setAccessibilityLabel("GitHub: \(item.title), \(item.status), \(currentIndex + 1) of \(items.count). Open PR on GitHub.")
        floor.needsLayout = true
    }
    @objc private func selected() { if let item = currentItem { onSelect?(item.id) } }
}

private final class ScorebugView: NSView {
    weak var button: NSButton?
    var onHover: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.masksToBounds = true; layer?.cornerRadius = 8
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func layout() { super.layout(); button?.frame = bounds.insetBy(dx: 8, dy: 2) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
}
