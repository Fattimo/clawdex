import AppKit

/// A floating speech bubble shown above the pet. Borderless, all-spaces, added
/// as a child window of the pet so it follows drags.
///
/// The latest session update; the source label (the project the
/// event came from) lets you tell them apart. Click the body to open the
/// project; click the ✕ in the corner to dismiss.
final class SpeechBubbleWindow: NSPanel {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let bubble = BubbleView()

    private let maxTextWidth: CGFloat = 240
    private let maxLines = 4
    private let lineHeight: CGFloat = 16
    private let padL: CGFloat = 12
    private let padV: CGFloat = 8
    private let closeSize: CGFloat = 16
    private var padR: CGFloat { closeSize + 10 }   // right gutter houses the ✕

    static let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let labelFont = NSFont.systemFont(ofSize: 12, weight: .semibold)

    /// Invoked when the body is clicked (open the project).
    var onOpen: (() -> Void)?
    /// Invoked when the ✕ is clicked (dismiss).
    var onClose: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 80, height: 36),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        ignoresMouseEvents = false          // clickable: open / dismiss
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        alphaValue = 0

        label.backgroundColor = .clear
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = maxLines
        label.cell?.truncatesLastVisibleLine = true

        bubble.closeSize = closeSize
        bubble.onOpen = { [weak self] in self?.onOpen?() }
        bubble.onClose = { [weak self] in self?.onClose?() }
        bubble.addSubview(label)
        contentView = bubble
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Set the bubble's `[source] message` content and resize to fit. Returns
    /// the resulting bubble size.
    @discardableResult
    func setContent(source: String, message: String, isFinal: Bool, accent: NSColor) -> NSSize {
        bubble.isFinal = isFinal
        bubble.accentColor = accent
        label.attributedStringValue = Self.attributed(source: source, message: message,
                                                       isFinal: isFinal, accent: accent)
        label.preferredMaxLayoutWidth = maxTextWidth

        // Size from the field's own fitting size — boundingRect underestimates
        // the cell's line-fragment padding and clips short messages with an
        // ellipsis. +1 guards against rounding.
        let fit = label.fittingSize
        let tw = min(maxTextWidth, ceil(fit.width) + 1)
        let th = min(ceil(fit.height), CGFloat(maxLines) * lineHeight)
        let w = padL + tw + padR
        let h = th + padV * 2 + 6

        let size = NSSize(width: w, height: h)
        setContentSize(size)
        bubble.frame = NSRect(origin: .zero, size: size)
        label.frame = NSRect(x: padL, y: padV + 6, width: tw, height: th)
        bubble.needsDisplay = true
        return size
    }

    /// `[source] ` in the environment's accent color, followed by the message.
    /// The final turn response uses the full body color; filler stays muted.
    static func attributed(source: String, message: String, isFinal: Bool, accent: NSColor) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        para.alignment = .center

        let out = NSMutableAttributedString()
        if !source.isEmpty {
            out.append(NSAttributedString(string: "\(source)\n", attributes: [
                .font: labelFont,
                .foregroundColor: accent,
                .paragraphStyle: para,
            ]))
        }
        out.append(NSAttributedString(string: message, attributes: [
            .font: font,
            .foregroundColor: isFinal ? NSColor.labelColor : NSColor.secondaryLabelColor,
            .paragraphStyle: para,
        ]))
        return out
    }

    func fadeIn() {
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            animator().alphaValue = 1
        }
    }

    func fadeOut(_ completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            completion?()
        })
    }
}

/// Rounded speech bubble with a centered tail. Draws a ✕ in the
/// top-right gutter and routes clicks: ✕ → onClose, anywhere else → onOpen.
final class BubbleView: NSView {
    var closeSize: CGFloat = 16
    var isFinal: Bool = true { didSet { needsDisplay = true } }
    var accentColor: NSColor = .clear { didSet { needsDisplay = true } }
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?

    // Solid (opaque) gray so nothing behind shows through. Final messages get a
    // slightly brighter shade than filler. Adapts to light/dark.
    private func backgroundGray() -> NSColor {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        if dark { return NSColor(white: isFinal ? 0.34 : 0.16, alpha: 1) }
        return NSColor(white: isFinal ? 1.0 : 0.80, alpha: 1)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Top-right hit area for the ✕ (AppKit y-up coords).
    private func closeRect() -> NSRect {
        NSRect(x: bounds.maxX - closeSize - 4,
               y: bounds.maxY - closeSize - 4,
               width: closeSize, height: closeSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = NSRect(x: 0.5, y: 6.5, width: bounds.width - 1, height: bounds.height - 7)
        let path = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: bounds.midX - 6, y: 7))
        tail.line(to: NSPoint(x: bounds.midX, y: 0))
        tail.line(to: NSPoint(x: bounds.midX + 6, y: 7))
        tail.close()
        backgroundGray().setFill()
        path.fill(); tail.fill()

        // ✕ glyph
        let c = closeRect()
        let inset = c.insetBy(dx: 4.5, dy: 4.5)
        let x = NSBezierPath()
        x.lineWidth = 1.4
        x.lineCapStyle = .round
        x.move(to: NSPoint(x: inset.minX, y: inset.minY))
        x.line(to: NSPoint(x: inset.maxX, y: inset.maxY))
        x.move(to: NSPoint(x: inset.minX, y: inset.maxY))
        x.line(to: NSPoint(x: inset.maxX, y: inset.minY))
        NSColor.tertiaryLabelColor.setStroke()
        x.stroke()
    }

    // Receive the click even though the pet's panel is non-activating.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if closeRect().insetBy(dx: -3, dy: -3).contains(p) {
            onClose?()
        } else {
            onOpen?()
        }
    }
}
