import AppKit
import Foundation

/// Decides what the pet "says" and drives the speech bubble.
///
/// Two speech sources, in priority order:
///   1. Real prose — the latest assistant text block from the session
///      transcript (`transcript_path` forwarded by clawdex-hook). This is
///      what Claude is actually saying.
///   2. Action narration — a synthesized one-liner from the hook
///      ("⚡ swift build", "✏️ main.swift") shown when there's no fresh prose,
///      e.g. mid-tool-call.
///
/// Prose wins whenever it's newer than what we last showed, so the bubble
/// tracks Claude's reasoning between tool calls and falls back to narration
/// while a tool is running.
final class SpeechController {
    private weak var pet: PetWindow?
    private let bubble = SpeechBubbleWindow()
    private var hideTimer: Timer?
    private var lastProse = ""
    private var attached = false

    init(pet: PetWindow) {
        self.pet = pet
    }

    /// Feed one socket event. `narration` and `transcriptPath` are optional.
    func handle(event: String, narration: String?, transcriptPath: String?) {
        var toShow: String?
        if let path = transcriptPath, !path.isEmpty,
           let prose = Self.latestAssistantText(path: path), prose != lastProse {
            lastProse = prose
            toShow = prose
        } else if let n = narration, !n.isEmpty {
            toShow = n
        }
        guard let text = toShow else { return }
        show(text)
    }

    private func show(_ raw: String) {
        let text = Self.clean(raw)
        guard !text.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let pet = self.pet else { return }
            let size = self.bubble.setText(text)
            self.position(over: pet, size: size)
            if !self.attached {
                pet.addChildWindow(self.bubble, ordered: .above)
                self.attached = true
                self.position(over: pet, size: size)   // re-anchor after attach
            }
            self.bubble.fadeIn()

            self.hideTimer?.invalidate()
            // Hold long enough to read: ~60ms/char, clamped to [2.2s, 9s].
            let ttl = max(2.2, min(9.0, Double(text.count) * 0.06))
            self.hideTimer = Timer.scheduledTimer(withTimeInterval: ttl, repeats: false) { [weak self] _ in
                self?.bubble.fadeOut()
            }
        }
    }

    private func position(over pet: PetWindow, size: NSSize) {
        let pf = pet.frame
        var x = pf.midX - size.width / 2
        let y = pf.maxY + 2
        // Keep the bubble on-screen horizontally.
        if let visible = (pet.screen ?? NSScreen.main)?.visibleFrame {
            x = min(max(x, visible.minX + 4), visible.maxX - size.width - 4)
        }
        bubble.setFrameOrigin(NSPoint(x: x, y: y))
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

    /// Collapse whitespace, take the first sentence/line, and cap length so the
    /// bubble stays a glanceable one-liner rather than an essay.
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
