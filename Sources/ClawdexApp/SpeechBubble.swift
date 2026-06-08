import AppKit

/// A floating speech bubble shown above the pet. Borderless, all-spaces, added
/// as a child window of the pet so it follows drags.
///
/// One bubble per concurrent session; the `[source]` label (the project the
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
    func setContent(source: String, message: String) -> NSSize {
        let attr = Self.attributed(source: source, message: message)
        label.attributedStringValue = attr

        let bounding = attr.boundingRect(
            with: NSSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let tw = min(maxTextWidth, ceil(bounding.width))
        let th = min(ceil(bounding.height), CGFloat(maxLines) * lineHeight)
        let w = padL + tw + padR
        let h = th + padV * 2

        let size = NSSize(width: w, height: h)
        setContentSize(size)
        bubble.frame = NSRect(origin: .zero, size: size)
        label.frame = NSRect(x: padL, y: padV, width: tw, height: th)
        bubble.needsDisplay = true
        return size
    }

    /// `[source] ` in a dimmer weight, followed by the message in the body color.
    static func attributed(source: String, message: String) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping

        let out = NSMutableAttributedString()
        if !source.isEmpty {
            out.append(NSAttributedString(string: "[\(source)] ", attributes: [
                .font: labelFont,
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: para,
            ]))
        }
        out.append(NSAttributedString(string: message, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
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

/// Plain rounded-rect speech bubble background (no tail). Draws a ✕ in the
/// top-right gutter and routes clicks: ✕ → onClose, anywhere else → onOpen.
final class BubbleView: NSView {
    var closeSize: CGFloat = 16
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?

    /// Top-right hit area for the ✕ (AppKit y-up coords).
    private func closeRect() -> NSRect {
        NSRect(x: bounds.maxX - closeSize - 4,
               y: bounds.maxY - closeSize - 4,
               width: closeSize, height: closeSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
        NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
        path.fill()
        NSColor.separatorColor.withAlphaComponent(0.6).setStroke()
        path.lineWidth = 1
        path.stroke()

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
