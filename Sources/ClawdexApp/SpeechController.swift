import AppKit
import Foundation

/// Decides what the pet "says" and drives the speech bubbles.
///
/// One bubble per source (the project a session runs in), so several concurrent
/// Claude Code sessions each get their own labeled bubble, stacked above the
/// pet. A source's bubble updates in place and resets its dwell timer; bubbles
/// fade out and the stack re-flows when they expire.
///
/// Two speech sources, in priority order:
///   1. Real prose — the latest assistant text block from the session
///      transcript (`transcript_path`). What Claude is actually saying.
///   2. Action narration — a synthesized one-liner from the hook
///      ("Editing main.swift") shown when there's no fresh prose, e.g.
///      mid-tool-call.
final class SpeechController {
    private weak var pet: PetWindow?

    private final class Bubble {
        let window = SpeechBubbleWindow()
        var size: NSSize = .zero
        var timer: Timer?
        var root: String = ""
    }

    /// Ordered oldest → newest. Newest stacks highest.
    private var order: [String] = []
    private var bubbles: [String: Bubble] = [:]
    private var lastProse: [String: String] = [:]

    private let maxBubbles = 5
    private let gap: CGFloat = 6

    /// Bank of contrasting, theme-adapting workspace colors. Each environment
    /// (source) gets the next one, cycling — stable for the daemon's lifetime so
    /// a project keeps its color.
    private static let palette: [NSColor] = [
        .systemBlue, .systemGreen, .systemOrange, .systemPurple,
        .systemPink, .systemTeal, .systemIndigo, .systemRed,
    ]
    private var colorIndex = 0
    private var colorBySource: [String: NSColor] = [:]

    private func color(for source: String) -> NSColor {
        guard !source.isEmpty else { return .clear }
        if let c = colorBySource[source] { return c }
        let c = Self.palette[colorIndex % Self.palette.count]
        colorIndex += 1
        colorBySource[source] = c
        return c
    }

    init(pet: PetWindow) {
        self.pet = pet
    }

    /// Feed one socket event. `narration`, `transcriptPath`, and `source` are
    /// all optional.
    func handle(event: String, narration: String?, transcriptPath: String?,
                source: String?, root: String?) {
        let src = (source ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // A user prompt (or session start) begins a NEW turn: there's no new
        // assistant prose yet, and the transcript's latest assistant text is the
        // PREVIOUS answer. Prime the dedup with it so it never echoes, and only
        // show narration ("thinking…").
        let newTurn = (event == "UserPromptSubmit" || event == "SessionStart")
        if newTurn, let path = transcriptPath, !path.isEmpty,
           let prose = Self.latestAssistantText(path: path) {
            lastProse[src] = prose
        }

        // Prose can only have appeared on events that follow Claude writing text.
        let proseEvent = (event == "PreToolUse" || event == "PostToolUse"
                          || event == "Stop" || event == "SubagentStop"
                          || event == "PreCompact")

        var toShow: String?
        if proseEvent, let path = transcriptPath, !path.isEmpty,
           let prose = Self.latestAssistantText(path: path), prose != lastProse[src] {
            lastProse[src] = prose
            toShow = prose
        } else if let n = narration, !n.isEmpty {
            toShow = n
        }
        guard let text = toShow else { return }
        // The final turn response arrives on Stop (agent done, ready to reprompt);
        // everything else is filler and gets a muted treatment.
        show(source: src, root: root ?? "", text: text, isFinal: event == "Stop")
    }

    private func show(source: String, root: String, text raw: String, isFinal: Bool) {
        let text = Self.clean(raw)
        guard !text.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let pet = self.pet else { return }

            let bubble: Bubble
            if let existing = self.bubbles[source] {
                bubble = existing
                bubble.timer?.invalidate()
            } else {
                bubble = Bubble()
                bubble.window.onOpen = { [weak self] in self?.openProject(source: source) }
                bubble.window.onClose = { [weak self] in self?.expire(source: source) }
                pet.addChildWindow(bubble.window, ordered: .above)
                self.bubbles[source] = bubble
                self.order.append(source)
                self.evictOverflow()
            }
            if !root.isEmpty { bubble.root = root }

            bubble.size = bubble.window.setContent(source: source, message: text,
                                                   isFinal: isFinal, accent: self.color(for: source))
            self.relayout()
            bubble.window.fadeIn()

            // Hold long enough to read: ~60ms/char, clamped to [2.2s, 9s].
            let ttl = max(2.2, min(9.0, Double(text.count) * 0.06))
            bubble.timer = Timer.scheduledTimer(withTimeInterval: ttl, repeats: false) { [weak self] _ in
                self?.expire(source: source)
            }
        }
    }

    private func evictOverflow() {
        while order.count > maxBubbles {
            let oldest = order.removeFirst()
            if let b = bubbles.removeValue(forKey: oldest) {
                b.timer?.invalidate()
                b.window.fadeOut()
            }
        }
    }

    /// Open the project root the bubble came from in Zed.
    private func openProject(source: String) {
        guard let root = bubbles[source]?.root, !root.isEmpty else { return }
        let folder = URL(fileURLWithPath: root)

        let ws = NSWorkspace.shared
        let zedURL = ws.urlForApplication(withBundleIdentifier: "dev.zed.Zed")
            ?? URL(fileURLWithPath: "/Applications/Zed.app")
        let cfg = NSWorkspace.OpenConfiguration()
        ws.open([folder], withApplicationAt: zedURL, configuration: cfg) { _, err in
            if let err = err {
                NSLog("clawdex: failed to open \(root) in Zed: \(err.localizedDescription)")
            }
        }
    }

    private func expire(source: String) {
        guard let b = bubbles.removeValue(forKey: source) else { return }
        b.timer?.invalidate()
        order.removeAll { $0 == source }
        b.window.fadeOut()
        relayout()
    }

    /// Stack the live bubbles above the pet, all sharing one left edge so they
    /// line up instead of each centering on its own width.
    private func relayout() {
        guard let pet = pet else { return }
        let pf = pet.frame
        let widest = order.compactMap { bubbles[$0]?.size.width }.max() ?? 0

        // Common left anchor near the pet, clamped so even the widest bubble
        // stays on-screen.
        var x = pf.minX
        if let v = (pet.screen ?? NSScreen.main)?.visibleFrame {
            x = min(max(x, v.minX + 4), v.maxX - widest - 4)
        }

        var y = pf.maxY + gap
        for source in order {
            guard let b = bubbles[source] else { continue }
            b.window.setFrameOrigin(NSPoint(x: x, y: y))
            y += b.size.height + gap
        }
    }

    // MARK: - Transcript reading

    /// Read the most recent assistant text block from a Claude Code transcript
    /// (JSONL). Reads only the tail of the file to stay cheap on long sessions.
    static func latestAssistantText(path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }

        let size = (try? fh.seekToEnd()) ?? 0
        let window: UInt64 = 262_144   // 256 KiB tail is plenty for a few messages
        let start = size > window ? size - window : 0
        try? fh.seek(toOffset: start)
        guard let data = try? fh.readToEnd(), !data.isEmpty else { return nil }

        var lines = data.split(separator: 0x0a, omittingEmptySubsequences: true)
        if start > 0 && !lines.isEmpty { lines.removeFirst() }   // drop partial first line

        for lineData in lines.reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any],
                  (obj["type"] as? String) == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let content = msg["content"] as? [[String: Any]] else { continue }

            var text = ""
            for block in content where (block["type"] as? String) == "text" {
                if let t = block["text"] as? String { text = t }   // last text block in the message
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    // MARK: - Text shaping

    /// Collapse whitespace and cap length so the bubble stays a glanceable
    /// one-liner rather than an essay.
    static func clean(_ raw: String) -> String {
        let collapsed = raw
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let parts = collapsed.split(separator: " ").filter { !$0.isEmpty }
        var s = parts.joined(separator: " ")
        let cap = 180
        if s.count > cap {
            let idx = s.index(s.startIndex, offsetBy: cap)
            s = String(s[..<idx]).trimmingCharacters(in: .whitespaces) + "…"
        }
        return s
    }
}
