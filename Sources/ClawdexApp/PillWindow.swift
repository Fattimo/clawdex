import AppKit

/// A compact status pill in the switchboard — one per active agent session.
///
/// Shows a colored dot + the project name, in that session's stable accent
/// color (the same color its speech bubble uses, so the two read as one
/// system). "Lit" means the session has finished its turn — drawn bright with
/// an accent tint and ring. "Dim" means it's still working or waiting on a
/// tool — the pill recedes. Clicking reopens that project in the app the
/// session was launched from (Claude Desktop, Zed, VS Code, …), or a Codex
/// thread deep-link; hovering reveals a tiny ✕ for dismissing a stale pill.
///
/// Added as a child window of the pet so it follows drags; the switchboard
/// stacks these vertically beside the pet.
final class PillWindow: NSPanel {
    private let view = PillView()

    static let height: CGFloat = 24
    static let maxLabelWidth: CGFloat = 160

    /// Invoked when the pill is clicked (reopen the project in its launching app).
    var onClick: (() -> Void)?
    /// Invoked when the hover-revealed ✕ is clicked.
    var onClose: (() -> Void)?

    /// Alpha the pill settles at — full when lit, faded back when dim so an
    /// inactive session clearly recedes.
    private var restingAlpha: CGFloat = 1

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 80, height: Self.height),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        ignoresMouseEvents = false          // clickable: reopen in launching app
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        alphaValue = 0

        view.onClick = { [weak self] in self?.onClick?() }
        view.onClose = { [weak self] in self?.onClose?() }
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Set the pill's label / state and resize to fit. Returns the new size.
    var halfDot: PillHalfDot? {
        get { view.halfDot }
        set { view.halfDot = newValue }
    }

    @discardableResult
    func setContent(label text: String, lit: Bool, accent: NSColor, fixedWidth: CGFloat? = nil, neutral: Bool = false) -> NSSize {
        view.title = text
        view.lit = lit && !neutral
        view.neutral = neutral
        view.accent = accent
        // A neutral (inert) pill fades its capsule, not the window, so its
        // label stays at full strength. Working pills fade the whole window.
        view.bodyAlpha = neutral ? 0.85 : 1.0

        let tw = min(Self.maxLabelWidth,
                     ceil((text as NSString).size(withAttributes: [.font: PillView.font]).width) + 1)
        let w = PillView.padL + PillView.dotSize + PillView.dotGap + tw + PillView.padR
        let size = NSSize(width: fixedWidth ?? w, height: Self.height)
        view.toolTip = text
        view.setAccessibilityLabel(text)
        setContentSize(size)
        view.frame = NSRect(origin: .zero, size: size)
        view.needsDisplay = true

        // Settle to the state's resting alpha. Animate only if already shown so
        // a lit→dim transition fades smoothly; first show is handled by fadeIn.
        restingAlpha = (lit || neutral) ? 1.0 : 0.55
        if alphaValue > 0.01 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                animator().alphaValue = restingAlpha
            }
        }
        return size
    }

    func fadeIn() {
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            animator().alphaValue = restingAlpha
        }
    }

    func fadeOut(_ completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            completion?()
        })
    }
}

/// Capsule with a status dot + label. Lit = accent-tinted, ringed, solid dot;
/// dim = neutral capsule, hollow dot, muted text; inert (neutral) = faded
/// capsule with full-strength text.
/// Which half of a working pill's dot is filled while its subagents run.
enum PillHalfDot: Equatable {
    case left, right
    var flipped: PillHalfDot { self == .left ? .right : .left }
    var marker: String { self == .left ? "◐" : "◑" }
}

final class PillView: NSView {
    static let padL: CGFloat = 9
    static let padR: CGFloat = 11
    static let dotSize: CGFloat = 8
    static let dotGap: CGFloat = 7
    static let closeSize: CGFloat = 10
    static let font = NSFont.systemFont(ofSize: 12, weight: .medium)

    var title = "" { didSet { needsDisplay = true } }
    var lit = false { didSet { needsDisplay = true } }
    var neutral = false { didSet { needsDisplay = true } }
    /// Set while subagents are running; drawn only on a working (dim) pill.
    var halfDot: PillHalfDot? { didSet { if halfDot != oldValue { needsDisplay = true } } }
    var accent: NSColor = .systemBlue { didSet { needsDisplay = true } }
    /// Opacity of the capsule, border, dot and close glyph — never the label.
    var bodyAlpha: CGFloat = 1 { didSet { if bodyAlpha != oldValue { needsDisplay = true } } }
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?

    private var isHovering = false {
        didSet {
            guard oldValue != isHovering else { return }
            needsDisplay = true
        }
    }
    private var trackingArea: NSTrackingArea?

    private func closeRect() -> NSRect {
        NSRect(x: bounds.maxX - Self.padR,
               y: bounds.midY - Self.closeSize / 2,
               width: Self.closeSize,
               height: Self.closeSize)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isHovering && closeRect().insetBy(dx: -2, dy: -2).contains(point) {
            onClose?()
        } else {
            onClick?()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Neutral capsule fill, before any accent wash.
    static func baseFill(lit: Bool, dark: Bool) -> NSColor {
        if lit {
            return dark ? NSColor(white: 0.20, alpha: 0.97) : NSColor(white: 0.98, alpha: 0.97)
        }
        return dark ? NSColor(white: 0.13, alpha: 0.92) : NSColor(white: 0.91, alpha: 0.92)
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = r.height / 2
        let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.setAlpha(bodyAlpha)
        ctx?.beginTransparencyLayer(auxiliaryInfo: nil)

        // Capsule fill: bright neutral + accent wash when lit; flatter and
        // greyer when dim so the pill reads as switched-off.
        Self.baseFill(lit: lit, dark: dark).setFill(); path.fill()
        if !neutral {
            accent.withAlphaComponent(lit ? (dark ? 0.30 : 0.16) : (dark ? 0.12 : 0.07)).setFill()
            path.fill()
        }

        // Border: accent + thicker when lit, faint hairline when dim.
        (lit ? accent.withAlphaComponent(0.9) : NSColor.separatorColor.withAlphaComponent(0.5)).setStroke()
        path.lineWidth = lit ? 1.5 : 1
        path.stroke()

        // Status dot — solid accent when lit; a plain grey ring when dim, so
        // colour only appears on a session that needs you.
        let cy = bounds.midY
        let dotRect = NSRect(x: Self.padL, y: cy - Self.dotSize / 2,
                             width: Self.dotSize, height: Self.dotSize)
        let dot = NSBezierPath(ovalIn: dotRect)
        if let halfDot, !neutral {
            // Half-filled while subagents work, whether the main turn is
            // still going or already waiting on you; swaps sides as they
            // make progress. A ready pill keeps its lit capsule.
            NSGraphicsContext.saveGraphicsState()
            let half = NSRect(x: halfDot == .left ? dotRect.minX : dotRect.midX, y: dotRect.minY,
                              width: dotRect.width / 2, height: dotRect.height)
            NSBezierPath(rect: half).addClip()
            accent.setFill(); dot.fill()
            NSGraphicsContext.restoreGraphicsState()
            accent.withAlphaComponent(lit ? 1 : 0.9).setStroke()
            dot.lineWidth = 1.5
            dot.stroke()
        } else if lit || neutral {
            accent.setFill(); dot.fill()
        } else {
            accent.withAlphaComponent(0.6).setStroke()
            dot.lineWidth = 1.5
            dot.stroke()
        }

        ctx?.endTransparencyLayer()
        ctx?.setAlpha(1)

        // Label — full-strength when lit or inert, muted while working.
        let textColor: NSColor = lit ? (dark ? .white : .labelColor) : (neutral ? .labelColor : .tertiaryLabelColor)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: textColor, .paragraphStyle: paragraph]
        let tx = Self.padL + Self.dotSize + Self.dotGap
        let tsize = (title as NSString).size(withAttributes: attrs)
        let avail = bounds.width - tx - Self.padR - (isHovering ? Self.closeSize + 3 : 0)
        let drawRect = NSRect(x: tx, y: cy - tsize.height / 2, width: max(0, avail), height: tsize.height)
        (title as NSString).draw(in: drawRect, withAttributes: attrs)

        if isHovering {
            ctx?.setAlpha(bodyAlpha)
            defer { ctx?.setAlpha(1) }
            let close = closeRect()
            let inset = close.insetBy(dx: 2.8, dy: 2.8)
            let x = NSBezierPath()
            x.lineWidth = 1.2
            x.lineCapStyle = .round
            x.move(to: NSPoint(x: inset.minX, y: inset.minY))
            x.line(to: NSPoint(x: inset.maxX, y: inset.maxY))
            x.move(to: NSPoint(x: inset.minX, y: inset.maxY))
            x.line(to: NSPoint(x: inset.maxX, y: inset.minY))
            (lit ? accent.withAlphaComponent(0.9) : NSColor.tertiaryLabelColor).setStroke()
            x.stroke()
        }
    }
}

/// A small circle beside a session's pill: its running subagent count, "?"
/// when the turn has gone silent with nothing in flight (it may be waiting on
/// you), or "…" while background jobs are still running.
///
/// Subagents and background jobs are work in flight, never something waiting
/// on you, so they're drawn in the dim "running" pill treatment. "?" is drawn
/// bright to catch your eye. Hidden (not detached) while there's nothing to
/// show; clicking it focuses the parent session like the pill does.
final class SubagentBadgeWindow: NSPanel {
    static let size: CGFloat = PillWindow.height

    private let view = SubagentBadgeView()

    /// Invoked when the badge is clicked (focus the parent session).
    var onClick: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        ignoresMouseEvents = true           // until shown
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        alphaValue = 0

        view.frame = NSRect(x: 0, y: 0, width: Self.size, height: Self.size)
        view.onClick = { [weak self] in self?.onClick?() }
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var content: SubagentBadgeView.Content {
        get { view.content }
        set { view.content = newValue }
    }

    /// The parent pill's accent, used to draw "?" like a lit pill.
    var accent: NSColor {
        get { view.accent }
        set { view.accent = newValue }
    }

    /// Fade in to the dim pill's resting alpha, or full alpha when `bright`.
    func show(bright: Bool = false) {
        ignoresMouseEvents = false
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            animator().alphaValue = bright ? 1.0 : 0.55
        }
    }

    /// Fade to invisible but stay attached, so the next subagent can reuse it.
    func hide() {
        ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            animator().alphaValue = 0
        }
    }

    func fadeOut() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
        })
    }
}

/// Circle with a centered glyph, styled like a dim PillView — or, for "?",
/// like a lit one in the session's accent color.
final class SubagentBadgeView: NSView {
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)

    enum Content: Equatable {
        case count(Int)   // running subagents
        case stalled      // "?" — silent turn, nothing in flight
        case background   // "…" — background jobs still running
    }

    var content = Content.count(0) { didSet { needsDisplay = true } }
    var accent: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        let bright = content == .stalled
        PillView.baseFill(lit: bright, dark: dark).setFill()
        circle.fill()
        // Same accent wash + border as a lit PillView.
        if bright {
            accent.withAlphaComponent(dark ? 0.30 : 0.16).setFill()
            circle.fill()
        }
        (bright ? accent.withAlphaComponent(0.9) : NSColor.separatorColor.withAlphaComponent(0.5)).setStroke()
        circle.lineWidth = bright ? 1.5 : 1
        circle.stroke()

        let text: String
        switch content {
        case .count(let n): text = n > 9 ? "9+" : String(n)
        case .stalled:      text = "?"
        case .background:   text = "…"
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: bright ? accent : NSColor.tertiaryLabelColor,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2,
                                            y: bounds.midY - size.height / 2),
                                withAttributes: attrs)
    }
}
