import AppKit
import QuartzCore

enum GitHubScorebugTone: Equatable {
    case ready, pending, failed, neutral
    func fill(dark: Bool) -> NSColor {
        NSColor(white: dark ? 0.17 : 0.79, alpha: 1)
    }
    func indicator(dark: Bool) -> NSColor {
        switch self {
        case .ready: return dark ? NSColor(calibratedRed: 0.27, green: 0.79, blue: 0.43, alpha: 1)
                                 : NSColor(calibratedRed: 0.12, green: 0.49, blue: 0.25, alpha: 1)
        case .pending: return dark ? NSColor(calibratedRed: 0.96, green: 0.77, blue: 0.20, alpha: 1)
                                   : NSColor(calibratedRed: 0.71, green: 0.48, blue: 0.02, alpha: 1)
        case .failed: return dark ? NSColor(calibratedRed: 0.97, green: 0.37, blue: 0.33, alpha: 1)
                                  : NSColor(calibratedRed: 0.80, green: 0.18, blue: 0.15, alpha: 1)
        case .neutral: return NSColor(white: dark ? 0.56 : 0.43, alpha: 1)
        }
    }
}

struct GitHubScorebugSegment {
    let id: String
    let frame: NSRect
    let tone: GitHubScorebugTone
}

/// A two-line ticker with a status segment for each recent PR.
final class GitHubScorebugWindow: NSPanel {
    struct Item {
        var id: String
        var title: String
        var status: String
        var number: Int? = nil
        var stackPosition: String? = nil
        var unresolvedReviewCount: Int? = nil
        var createdAt: Date? = nil
        var updatedAt: Date? = nil
        var tone: GitHubScorebugTone = .neutral

        var headline: String {
            (number.map { "#\($0) · " } ?? "") + title
        }
        var reviewText: String {
            guard let count = unresolvedReviewCount, count >= 0 else { return "— unresolved" }
            return "\(count) unresolved"
        }
        func metadata(now: Date = Date()) -> String {
            let relative: String
            if let updatedAt {
                let seconds = max(0, now.timeIntervalSince(updatedAt))
                if seconds < 60 { relative = "just now" }
                else if seconds < 3600 { relative = "\(Int(seconds / 60))m ago" }
                else if seconds < 86400 { relative = "\(Int(seconds / 3600))h ago" }
                else { relative = "\(Int(seconds / 86400))d ago" }
            } else { relative = "—" }
            let opened: String
            if let createdAt {
                let formatter = DateFormatter()
                formatter.dateFormat = Calendar.current.component(.year, from: createdAt) == Calendar.current.component(.year, from: now) ? "MMM d" : "MMM d, yyyy"
                opened = formatter.string(from: createdAt)
            } else { opened = "—" }
            return "Updated \(relative) · opened \(opened)"
        }
    }
    private let floor = ScorebugView()
    let button = GitHubScorebugButton()
    private(set) var items: [Item] = []
    private(set) var currentIndex = 0
    var currentItem: Item? { items.indices.contains(currentIndex) ? items[currentIndex] : nil }
    var statusSegments: [GitHubScorebugSegment] { floor.statusSegments }
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
        let previousCount = self.items.count
        self.items = Array(items.prefix(4))
        currentIndex = self.items.firstIndex { $0.id == previous } ?? 0
        render(animated: false)
        // Webhook refreshes must not restart the dwell and starve the carousel.
        if currentItem?.id != previous || (previousCount > 1) != (self.items.count > 1) || timer == nil { restartTimer() }
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
        guard isVisible, !paused, !items.isEmpty else { return }
        let interval = items.count > 1 ? rotationInterval : 60
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.items.count > 1 { self.advance() } else { self.render(animated: false) }
        }
        timer.tolerance = min(0.5, interval / 10)
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    private func render(animated: Bool) {
        floor.items = items; floor.currentIndex = currentIndex
        floor.needsLayout = true; floor.needsDisplay = true
        guard let item = currentItem else {
            button.attributedTitle = NSAttributedString(string: "")
            button.item = nil
            button.isEnabled = false; button.toolTip = nil; return
        }
        button.isEnabled = true
        button.identifier = NSUserInterfaceItemIdentifier(item.id)
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let transition = CATransition(); transition.type = .push; transition.subtype = .fromTop
            transition.duration = 0.3
            button.layer?.add(transition, forKey: "rotate")
        }
        button.item = item
        button.attributedTitle = NSAttributedString(string: item.headline + "\n" + item.metadata())
        let position = item.stackPosition.map { " · stack \($0)" } ?? ""
        button.toolTip = "\(item.headline)\(position) · \(item.status) · \(item.reviewText) review conversations · \(item.metadata()) · Open on GitHub"
        button.setAccessibilityLabel("GitHub: \(item.headline)\(position), \(item.status), \(item.reviewText) review conversations, \(item.metadata()). Open PR on GitHub.")
        floor.tone = item.tone
        floor.needsLayout = true; floor.needsDisplay = true
    }
    @objc private func selected() { if let item = currentItem { onSelect?(item.id) } }
}

/// One native click target with independently laid-out text so a long title
/// never crowds out the stack position or unresolved review count.
final class GitHubScorebugButton: NSButton {
    private let commentIcon = ScorebugCommentIcon()
    var item: GitHubScorebugWindow.Item? { didSet { commentIcon.isHidden = item == nil; needsDisplay = true; needsLayout = true } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        commentIcon.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil)
        commentIcon.contentTintColor = .secondaryLabelColor
        addSubview(commentIcon)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        commentIcon.frame = NSRect(x: bounds.maxX - 13, y: isFlipped ? bounds.maxY - 14 : 3, width: 12, height: 12)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let item else { return }
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let secondaryFont = NSFont.systemFont(ofSize: 11)
        let top: CGFloat = isFlipped ? 2 : bounds.maxY - 15
        let bottom: CGFloat = isFlipped ? bounds.maxY - 15 : 2
        let count = item.unresolvedReviewCount.map(String.init) ?? "—"
        let reviewWidth = ceil((count as NSString).size(withAttributes: [.font: secondaryFont]).width) + 1
        var end = bounds.maxX - 17
        draw(count, rect: NSRect(x: end - reviewWidth, y: bottom, width: reviewWidth, height: 14), font: secondaryFont, color: .secondaryLabelColor, alignment: .right)
        end -= reviewWidth + 10
        if let position = item.stackPosition {
            let text = "\(position) ·"
            let width = ceil((text as NSString).size(withAttributes: [.font: secondaryFont]).width) + 1
            draw(text, rect: NSRect(x: end - width, y: bottom, width: width, height: 14), font: secondaryFont, color: .secondaryLabelColor)
            end -= width + 5
        }
        var start: CGFloat = 0
        if let number = item.number {
            let text = "#\(number) ·"
            let width = min(bounds.width * 0.3, ceil((text as NSString).size(withAttributes: [.font: font]).width) + 1)
            draw(text, rect: NSRect(x: 0, y: top, width: width, height: 14), font: font)
            start = width + 5
        }
        draw(item.title, rect: NSRect(x: start, y: top, width: max(0, bounds.maxX - start), height: 14), font: font)
        draw(item.metadata(), rect: NSRect(x: 0, y: bottom, width: max(0, end), height: 14), font: secondaryFont, color: .secondaryLabelColor)
    }
    private func draw(_ text: String, rect: NSRect, font: NSFont, color: NSColor = .labelColor, alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail; paragraph.alignment = alignment
        (text as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }
}

private final class ScorebugCommentIcon: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class ScorebugView: NSView {
    var tone: GitHubScorebugTone = .neutral
    var items: [GitHubScorebugWindow.Item] = []
    var currentIndex = 0
    var statusSegments: [GitHubScorebugSegment] {
        guard !items.isEmpty, bounds.width > 0 else { return [] }
        let gap: CGFloat = 1
        let width = max(0, (bounds.width - gap * CGFloat(items.count - 1)) / CGFloat(items.count))
        return items.enumerated().map { index, item in
            GitHubScorebugSegment(id: item.id,
                frame: NSRect(x: bounds.minX + CGFloat(index) * (width + gap), y: bounds.minY,
                              width: width, height: index == currentIndex ? 5 : 2), tone: item.tone)
        }
    }
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
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { button?.performClick(nil) }
    override func layout() {
        super.layout()
        button?.frame = NSRect(x: 25, y: 6, width: max(0, bounds.width - 33), height: max(0, bounds.height - 8))
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        tone.fill(dark: dark).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        tone.indicator(dark: dark).setFill()
        NSBezierPath(ovalIn: NSRect(x: 9, y: bounds.midY - 4, width: 8, height: 8)).fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).addClip()
        for segment in statusSegments {
            segment.tone.indicator(dark: dark).setFill()
            segment.frame.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
