import AppKit

/// Short-lived mouse positions; old points and large jumps never connect.
struct MouseTrail {
    struct Sample { let point: NSPoint; let time: TimeInterval }
    private(set) var samples: [Sample] = []
    static let lifetime: TimeInterval = 0.24

    mutating func update(_ point: NSPoint, now: TimeInterval) {
        samples.removeAll { now - $0.time > Self.lifetime }
        if let last = samples.last {
            let distance = hypot(point.x - last.point.x, point.y - last.point.y)
            if distance > 240 { samples.removeAll() }
            else if distance < 0.5 { return }
        }
        samples.append(Sample(point: point, time: now))
        if samples.count > 64 { samples.removeFirst(samples.count - 64) }
    }
    mutating func clear() { samples.removeAll() }
}

final class MouseTrailController {
    private var timer: Timer?
    private let panel = MouseTrailPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let trailView = MouseTrailView()
    private var refreshed: TimeInterval = 0
    private var kittyPID: pid_t = 0
    private var kittyFrames: [NSRect] = []

    init() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = trailView
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled else { stop(); return }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate(); timer = nil
        hide()
    }

    private func hide() {
        trailView.trail.clear()
        trailView.needsDisplay = true
        panel.orderOut(nil)
    }

    static func appKitRect(_ rect: CGRect, desktopTop: CGFloat) -> NSRect {
        NSRect(x: rect.minX, y: desktopTop - rect.maxY, width: rect.width, height: rect.height)
    }

    private func tick() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == "net.kovidgoyal.kitty" else { hide(); return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - refreshed > 0.25 || kittyPID != app.processIdentifier {
            refreshed = now; kittyPID = app.processIdentifier
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            kittyFrames = windows.compactMap { window in
                guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == kittyPID,
                      (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                      let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
                return Self.appKitRect(rect, desktopTop: top)
            }
        }
        let point = NSEvent.mouseLocation
        guard kittyFrames.contains(where: { $0.contains(point) }),
              let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { hide(); return }
        if panel.frame != screen.frame {
            trailView.trail.clear()
            panel.setFrame(screen.frame, display: false)
        }
        trailView.now = now
        trailView.trail.update(NSPoint(x: point.x - screen.frame.minX, y: point.y - screen.frame.minY), now: now)
        trailView.refresh()
        if trailView.trail.samples.count > 1 {
            if !panel.isVisible { panel.orderFrontRegardless() }
        } else { panel.orderOut(nil) }
    }
}

private final class MouseTrailPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class MouseTrailView: NSView {
    var trail = MouseTrail()
    var now: TimeInterval = 0
    private var previousBounds = NSRect.zero
    override var isOpaque: Bool { false }

    func refresh() {
        let current = trail.samples.reduce(NSRect.null) { rect, sample in
            rect.union(NSRect(x: sample.point.x - 18, y: sample.point.y - 18, width: 36, height: 36))
        }
        if !previousBounds.isEmpty { setNeedsDisplay(previousBounds) }
        if !current.isNull { setNeedsDisplay(current) }
        previousBounds = current.isNull ? .zero : current
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)
        let points = trail.samples
        guard points.count > 1 else { return }
        for index in 1..<points.count {
            let sample = points[index]
            let fade = max(0, 1 - (now - sample.time) / MouseTrail.lifetime)
            let color = NSColor(calibratedHue: 0.59 + 0.12 * sin(now * 0.7 + Double(index) * 0.04),
                                saturation: 0.65, brightness: 1, alpha: 1)
            let path = NSBezierPath()
            path.move(to: points[index - 1].point)
            path.line(to: sample.point)
            path.lineCapStyle = .round
            color.withAlphaComponent(0.12 * fade).setStroke()
            path.lineWidth = 13 * fade; path.stroke()
            color.withAlphaComponent(0.75 * fade).setStroke()
            path.lineWidth = 4 * fade; path.stroke()
        }
    }
}
