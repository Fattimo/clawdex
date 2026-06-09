import AppKit

/// A compact status pill in the switchboard — one per active agent session.
///
/// Shows a colored dot + the project name, in that session's stable accent
/// color (the same color its speech bubble uses, so the two read as one
/// system). "Lit" means the session is waiting on you (finished its turn, or
/// asking for input) — drawn bright with an accent tint and ring. "Dim" means
/// it's working — the pill recedes. Clicking focuses that project's Zed window.
///
/// Added as a child window of the pet so it follows drags; the switchboard
/// stacks these vertically beside the pet.
final class PillWindow: NSPanel {
    private let view = PillView()

    static let height: CGFloat = 24
    static let maxLabelWidth: CGFloat = 160

    /// Invoked when the pill is clicked (focus the project's Zed window).
    var onClick: (() -> Void)?

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
        ignoresMouseEvents = false          // clickable: focus Zed
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        alphaValue = 0

        view.onClick = { [weak self] in self?.onClick?() }
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Set the pill's label / state and resize to fit. Returns the new size.
    @discardableResult
    func setContent(label text: String, lit: Bool, accent: NSColor) -> NSSize {
        view.title = text
        view.lit = lit
        view.accent = accent

        let tw = min(Self.maxLabelWidth,
                     ceil((text as NSString).size(withAttributes: [.font: PillView.font]).width) + 1)
        let w = PillView.padL + PillView.dotSize + PillView.dotGap + tw + PillView.padR
        let size = NSSize(width: w, height: Self.height)
        setContentSize(size)
        view.frame = NSRect(origin: .zero, size: size)
        view.needsDisplay = true

        // Settle to the state's resting alpha. Animate only if already shown so
        // a lit→dim transition fades smoothly; first show is handled by fadeIn.
        restingAlpha = lit ? 1.0 : 0.55
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
/// dim = neutral capsule, hollow dot, muted text.
final class PillView: NSView {
    static let padL: CGFloat = 9
    static let padR: CGFloat = 11
    static let dotSize: CGFloat = 8
    static let dotGap: CGFloat = 7
    static let font = NSFont.systemFont(ofSize: 12, weight: .medium)

    var title = "" { didSet { needsDisplay = true } }
    var lit = false { didSet { needsDisplay = true } }
    var accent: NSColor = .systemBlue { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = r.height / 2
        let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)

        // Capsule fill: bright neutral + accent wash when lit; flatter and
        // greyer when dim so the pill reads as switched-off.
        let base: NSColor
        if lit {
            base = dark ? NSColor(white: 0.20, alpha: 0.97) : NSColor(white: 0.98, alpha: 0.97)
        } else {
            base = dark ? NSColor(white: 0.13, alpha: 0.92) : NSColor(white: 0.91, alpha: 0.92)
        }
        base.setFill(); path.fill()
        if lit {
            accent.withAlphaComponent(dark ? 0.30 : 0.16).setFill()
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
        if lit {
            accent.setFill(); dot.fill()
        } else {
            NSColor.tertiaryLabelColor.setStroke()
            dot.lineWidth = 1.5
            dot.stroke()
        }

        // Label.
        let textColor: NSColor = lit ? (dark ? .white : .labelColor) : .tertiaryLabelColor
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: textColor]
        let tx = Self.padL + Self.dotSize + Self.dotGap
        let tsize = (title as NSString).size(withAttributes: attrs)
        let avail = bounds.width - tx - Self.padR
        let drawRect = NSRect(x: tx, y: cy - tsize.height / 2, width: max(0, avail), height: tsize.height)
        (title as NSString).draw(in: drawRect, withAttributes: attrs)
    }
}
