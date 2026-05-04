import AppKit
import QuartzCore

/// Floating, draggable, all-spaces NSPanel that hosts the sprite layer.
///
/// The panel intercepts mouse events on the cell rectangle so the user can
/// grab the pet and drag it. While dragging, the displayed row is forced to
/// `running-right` / `running-left` based on horizontal motion direction;
/// the daemon-commanded row is restored on mouse-up.
final class PetWindow: NSPanel {
    private let spriteLayer = CALayer()
    private var atlasImage: CGImage?

    /// Row last requested by the state machine (the "intended" state).
    private var commandedRow: AnimationRow = .idle
    /// Row currently being rendered. Diverges from `commandedRow` while dragging.
    private var displayedRow: AnimationRow = .idle
    private var frameIdx: Int = 0
    private var frameTimer: Timer?

    private var isDragging = false

    /// On-screen scale. 0.5 → pixel-perfect on Retina (1 source px = 1 native px).
    /// 1.0 → 2× pixel-doubled (still crisp via nearest-neighbor + contentsScale).
    private let scale: CGFloat

    init(scale: CGFloat = 0.75) {
        self.scale = scale
        let size = NSSize(width: AnimationConstants.cellWidth * scale,
                          height: AnimationConstants.cellHeight * scale)
        let frame = NSRect(origin: .zero, size: size)
        super.init(contentRect: frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        // Mouse events are accepted so the cell rectangle is grabbable.
        // (Click-through outside the cell is preserved by the small footprint.)
        ignoresMouseEvents = false
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let origin = NSPoint(x: visible.maxX - size.width - 24,
                                 y: visible.minY + 24)
            setFrameOrigin(origin)
        }

        let host = PetView(frame: frame)
        host.petWindow = self
        host.wantsLayer = true
        host.layer?.addSublayer(spriteLayer)
        contentView = host

        spriteLayer.frame = frame
        spriteLayer.magnificationFilter = .nearest    // pixel-art crisp
        spriteLayer.minificationFilter = .nearest
        spriteLayer.contentsGravity = .resize         // we control the crop via contentsRect

        // Match the screen's native pixel density so nearest-neighbor doesn't
        // get blurred by the compositor's bilinear final scale.
        let backing = NSScreen.main?.backingScaleFactor ?? 2.0
        host.layer?.contentsScale = backing
        spriteLayer.contentsScale = backing
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Pet loading

    func loadPet(_ pet: (PetManifest, URL)) {
        guard let img = NSImage(contentsOf: pet.1),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            NSLog("clawdex: failed to load atlas for \(pet.0.id) at \(pet.1.path)")
            return
        }
        atlasImage = cg
        spriteLayer.contents = cg
        applyFrame()
    }

    // MARK: - Row control

    /// Called by the state machine. Records the commanded row, but only
    /// applies it visually if we're not in the middle of a drag.
    func setRow(_ row: AnimationRow) {
        commandedRow = row
        if !isDragging {
            applyDisplayedRow(row)
        }
    }

    /// Called by the drag handler. Forces a running-direction row for the
    /// duration of the drag, ignoring whatever the state machine wants.
    func dragStarted() {
        isDragging = true
    }

    func dragMoved(stepDx: CGFloat) {
        guard isDragging else { return }
        // Hysteresis: ignore micro-jitter under 1 point.
        if abs(stepDx) < 1.0 { return }
        let row: AnimationRow = stepDx >= 0 ? .runningRight : .runningLeft
        applyDisplayedRow(row)
    }

    func dragEnded() {
        isDragging = false
        applyDisplayedRow(commandedRow)
    }

    private func applyDisplayedRow(_ row: AnimationRow) {
        guard row != displayedRow else { return }
        displayedRow = row
        frameIdx = 0
        applyFrame()
        scheduleNextFrame()
    }

    private func scheduleNextFrame() {
        frameTimer?.invalidate()
        let durations = displayedRow.frameDurationsMs
        let durMs = durations[frameIdx % durations.count]
        frameTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(durMs) / 1000.0,
                                          repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.frameIdx = (self.frameIdx + 1) % self.displayedRow.frameCount
            self.applyFrame()
            self.scheduleNextFrame()
        }
    }

    private func applyFrame() {
        guard atlasImage != nil else { return }
        let cw = AnimationConstants.cellWidth / AnimationConstants.atlasWidth   // 1/8
        let ch = AnimationConstants.cellHeight / AnimationConstants.atlasHeight // 1/9
        let col = CGFloat(frameIdx)
        let row = CGFloat(displayedRow.rawValue)
        let x = col * cw
        // CALayer unit-coords origin is bottom-left; spec rows are numbered top-down.
        let y = 1.0 - (row + 1) * ch
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spriteLayer.contentsRect = CGRect(x: x, y: y, width: cw, height: ch)
        CATransaction.commit()
    }

    // MARK: - Visibility

    func wake() { orderFrontRegardless() }
    func tuck() { orderOut(nil) }
}

/// Content view that turns mouse-down + drag into window-move events,
/// and feeds direction info back to the PetWindow so the sprite animates.
final class PetView: NSView {
    weak var petWindow: PetWindow?

    private var initialMouseLocation: NSPoint?
    private var initialWindowOrigin: NSPoint?
    private var lastMouseLocation: NSPoint?

    /// Accept clicks even when the pet's window isn't key (it never is —
    /// it's a non-activating panel).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window = self.window else { return }
        initialMouseLocation = NSEvent.mouseLocation
        initialWindowOrigin = window.frame.origin
        lastMouseLocation = NSEvent.mouseLocation
        petWindow?.dragStarted()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window = self.window,
              let initialMouse = initialMouseLocation,
              let initialOrigin = initialWindowOrigin,
              let last = lastMouseLocation else { return }
        let current = NSEvent.mouseLocation

        // Move the window with the cursor.
        let dx = current.x - initialMouse.x
        let dy = current.y - initialMouse.y
        window.setFrameOrigin(NSPoint(x: initialOrigin.x + dx, y: initialOrigin.y + dy))

        // Tell the pet which direction we're going right now.
        petWindow?.dragMoved(stepDx: current.x - last.x)
        lastMouseLocation = current
    }

    override func mouseUp(with event: NSEvent) {
        initialMouseLocation = nil
        initialWindowOrigin = nil
        lastMouseLocation = nil
        petWindow?.dragEnded()
    }
}
