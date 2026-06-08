import AppKit

/// A floating speech bubble shown above the pet. Borderless, click-through,
/// all-spaces. Added as a child window of the pet so it follows drags.
final class SpeechBubbleWindow: NSPanel {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let bubble = BubbleView()

    private let maxTextWidth: CGFloat = 240
    private let maxLines = 4
    private let lineHeight: CGFloat = 16
    private let padH: CGFloat = 12
    private let padV: CGFloat = 9
    private let tailHeight: CGFloat = 8

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 80, height: 40),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        alphaValue = 0

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.backgroundColor = .clear
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = maxLines
        label.cell?.truncatesLastVisibleLine = true

        bubble.tailHeight = tailHeight
        bubble.addSubview(label)
        contentView = bubble
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Resize to fit `text` and return the resulting bubble size.
    @discardableResult
    func setText(_ text: String) -> NSSize {
        label.stringValue = text
        let bounding = (text as NSString).boundingRect(
            with: NSSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: label.font as Any])
        let tw = min(maxTextWidth, ceil(bounding.width))
        let th = min(ceil(bounding.height), CGFloat(maxLines) * lineHeight)
        let w = tw + padH * 2
        let h = th + padV * 2 + tailHeight

        let size = NSSize(width: w, height: h)
        setContentSize(size)
        bubble.frame = NSRect(origin: .zero, size: size)
        // Text sits above the downward tail (AppKit y-up coords).
        label.frame = NSRect(x: padH, y: padV + tailHeight, width: tw, height: th)
        bubble.needsDisplay = true
        return size
    }

    func fadeIn() {
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            animator().alphaValue = 1
        }
    }

    func fadeOut() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            if self.alphaValue < 0.01 { self.orderOut(nil) }
        })
    }
}

/// Rounded-rect speech bubble background with a downward tail at bottom-center.
final class BubbleView: NSView {
    var tailHeight: CGFloat = 8

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        guard r.height > tailHeight else { return }
        let body = NSRect(x: 0.5, y: tailHeight + 0.5,
                          width: r.width - 1, height: r.height - tailHeight - 1)
        let bodyPath = NSBezierPath(roundedRect: body, xRadius: 10, yRadius: 10)

        let cx = r.midX
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: cx - 7, y: tailHeight + 0.5))
        tail.line(to: NSPoint(x: cx, y: 0.5))
        tail.line(to: NSPoint(x: cx + 7, y: tailHeight + 0.5))
        tail.close()

        let fill = NSColor.windowBackgroundColor.withAlphaComponent(0.96)
        fill.setFill()
        bodyPath.fill()
        tail.fill()

        NSColor.separatorColor.withAlphaComponent(0.6).setStroke()
        bodyPath.lineWidth = 1
        bodyPath.stroke()
    }
}
