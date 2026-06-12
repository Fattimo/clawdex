import Foundation

/// Translates incoming socket events into a stream of `(row, frame)` ticks
/// that the renderer reads on the main run loop.
///
/// Modes (from clawdex-hook):
/// - transient: play the row through one full cycle, then return to idle.
/// - sticky: hold this row until another sticky/transient arrives, or a
///   release fires. Heartbeat absence (>15s) also drops to idle.
/// - release: clear sticky lock without interrupting an in-flight transient;
///   Codex PostToolUse is intentionally a no-op release.
final class StateMachine {
    struct Event: Decodable {
        let event: String
        let agent: String?
        let row: Int
        let mode: String
        let ttl: Int?
    }

    enum Mode: String { case transient, sticky, release, heartbeat }

    private let onChange: (AnimationRow) -> Void

    private var currentRow: AnimationRow = .idle
    private var stickyRow: AnimationRow? = nil
    private var transientUntil: Date? = nil
    private var lastHeartbeat: Date = Date()
    private var idleAfter: TimeInterval = 15.0   // seconds without heartbeat → idle

    init(onChange: @escaping (AnimationRow) -> Void) {
        self.onChange = onChange
        // Periodically reconcile (handles heartbeat timeouts and transient endings).
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    /// Process one JSON line received on the daemon socket.
    func ingest(_ line: String) {
        guard let data = line.data(using: .utf8),
              let evt = try? JSONDecoder().decode(Event.self, from: data) else { return }

        DispatchQueue.main.async { [weak self] in
            self?.apply(evt)
        }
    }

    private func apply(_ evt: Event) {
        if evt.event == "heartbeat" {
            lastHeartbeat = Date()
            return
        }
        guard let mode = Mode(rawValue: evt.mode) else { return }

        switch mode {
        case .transient:
            guard let row = AnimationRow(rawValue: evt.row) else { return }
            let cycleMs = evt.ttl.flatMap { $0 > 0 ? $0 : nil } ?? row.cycleDurationMs
            transientUntil = Date().addingTimeInterval(TimeInterval(cycleMs) / 1000.0)
            if evt.event == "Stop" && evt.agent == "codex" {
                // A final wave should settle to idle, not back to the work row
                // that Codex kept alive across the last PostToolUse boundary.
                stickyRow = nil
            }
            setRow(row)

        case .sticky:
            guard let row = AnimationRow(rawValue: evt.row) else { return }
            stickyRow = row
            transientUntil = nil
            if let ttl = evt.ttl, ttl > 0 {
                // Sticky with TTL: auto-release after duration.
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ttl)) { [weak self] in
                    if self?.stickyRow == row { self?.stickyRow = nil; self?.tick() }
                }
            }
            setRow(row)

        case .release:
            // Codex emits PostToolUse between internal tool calls. Keep the
            // current work row alive there so it does not flash back to the
            // idle/blinking row before the next tool or final Stop arrives.
            // Claude keeps the older release behavior.
            if !(evt.event == "PostToolUse" && evt.agent == "codex") {
                stickyRow = nil
            }

        case .heartbeat:
            lastHeartbeat = Date()
        }
    }

    private func tick() {
        // Transient playing? Hold it.
        if let until = transientUntil, Date() < until {
            return
        } else {
            transientUntil = nil
        }

        // Heartbeat timeout? Force idle.
        if Date().timeIntervalSince(lastHeartbeat) > idleAfter {
            stickyRow = nil
            setRow(.idle)
            return
        }

        // Default: sticky if set, else idle.
        setRow(stickyRow ?? .idle)
    }

    private func setRow(_ row: AnimationRow) {
        guard row != currentRow else { return }
        currentRow = row
        onChange(row)
    }
}
