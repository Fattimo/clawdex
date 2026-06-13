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
        var threadID: String = ""   // Codex conversation id, for the deep link
    }

    /// Ordered oldest → newest. Newest stacks highest.
    private var order: [String] = []
    private var bubbles: [String: Bubble] = [:]
    private var lastProse: [String: String] = [:]

    /// Agent-readiness switchboard: one pill per active session, stacked
    /// vertically beside the pet. A pill is "lit" only once its turn has
    /// finished and "dim" while it is still working or waiting on a tool.
    /// Pills auto-prune once a session goes quiet (dim + idle past the timeout);
    /// a lit pill never disappears on its own.
    private final class Pill {
        let window = PillWindow()
        var size: NSSize = .zero
        var lit = false
        var root = ""
        var threadID = ""   // Codex conversation id, for the deep link
        var lastSeen = Date()
    }
    private var pillOrder: [String] = []        // oldest → newest, bottom → top
    private var pills: [String: Pill] = [:]
    private let pillIdleTimeout: TimeInterval = 600   // 10 min quiet → prune
    private let pillGap: CGFloat = 2            // near-flush to the visible body
    /// Transparent padding inside the pet's window frame (the sprite doesn't
    /// fill the cell). Anchoring to the frame leaves a dead gap, so we pull in
    /// by this much to hug the actual artwork. ~8pt at the default 0.75 scale.
    private let petArtInset: CGFloat = 8

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

    /// Separator joining a session key's "repo" and "agent" halves. A control
    /// char so it can't collide with a real repo name.
    private static let keySep = "\u{1}"

    /// The agent half of a composite "repo<sep>agent" session key.
    private static func agent(ofKey key: String) -> String {
        let parts = key.components(separatedBy: keySep)
        return parts.count == 2 ? parts[1] : "claude"
    }

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
        // Keep the switchboard glued to the pet (and on the correct side) as it
        // is dragged around the screen.
        pet.onMoved = { [weak self] in self?.relayoutPills() }
        // Sweep out sessions that have gone quiet.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.prunePills()
        }
    }

    /// Feed one socket event. `narration`, `transcriptPath`, and `source` are
    /// all optional.
    func handle(event: String, narration: String?, transcriptPath: String?,
                source: String?, root: String?, agent: String?) {
        let repo = (source ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let agentTag = (agent ?? "claude")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Composite identity keyed on repo + agent: the same project running
        // under Claude and Codex at once gets its own pill, bubble, and accent
        // color instead of clobbering one shared entry. `label` is what the user
        // sees — it marks non-Claude agents (e.g. "pylon ·cdx").
        let src = repo.isEmpty ? "" : repo + Self.keySep + agentTag
        let label = Self.displayLabel(repo: repo, agent: agentTag)
        // Codex conversation id, recovered from the rollout transcript filename,
        // so a pill click can deep-link straight to that thread.
        let threadID = Self.threadID(fromTranscript: transcriptPath ?? "")

        // Session closed: drop its pill and stop — there's nothing to narrate.
        if event == "SessionEnd" {
            if !src.isEmpty { removePill(source: src) }
            return
        }

        // Switchboard pill. Only Stop means the agent has actually finished a
        // turn and is ready for the next prompt. Session startup, permission
        // requests, and tool activity all stay dim so in-flight work does not
        // flicker as ready.
        // Done before the prose guard below so readiness tracks even when
        // there's nothing new to say.
        if !src.isEmpty {
            let lit: Bool?
            switch event {
            case "Stop":
                lit = true
            case "SessionStart", "Notification", "PermissionRequest",
                 "UserPromptSubmit", "PreToolUse", "PostToolUse",
                 "PreCompact", "PostCompact":
                lit = false
            default:
                lit = nil   // SubagentStop and others: leave the pill as-is
            }
            updatePill(source: src, label: label, root: root ?? "",
                       threadID: threadID, lit: lit)
        }

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
        show(source: src, label: label, root: root ?? "", threadID: threadID,
             text: text, isFinal: event == "Stop")
    }

    private func show(source: String, label: String, root: String, threadID: String,
                      text raw: String, isFinal: Bool) {
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
            if !threadID.isEmpty { bubble.threadID = threadID }

            bubble.size = bubble.window.setContent(source: label, message: text,
                                                   isFinal: isFinal, accent: self.color(for: source))
            self.relayout()
            bubble.window.fadeIn()

            // Hold long enough to read: ~60ms/char. Final turn messages prompt
            // further action, so they linger; filler clears quickly.
            let ttl = isFinal ? max(15.0, min(30.0, Double(text.count) * 0.06))
                              : max(2.2, min(9.0, Double(text.count) * 0.06))
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

    /// Focus the session. Codex sessions deep-link straight to their thread
    /// (codex://threads/<id>) when we know the id; otherwise — and for Claude —
    /// open the project folder in the agent's app (Codex Desktop / Zed, both of
    /// which accept a folder). Pill outlives the bubble, so it's the first
    /// lookup; the bubble is the fallback.
    private func openProject(source: String) {
        let isCodex = Self.agent(ofKey: source) == "codex"

        if isCodex {
            let threadID = pills[source]?.threadID ?? bubbles[source]?.threadID ?? ""
            if !threadID.isEmpty, let url = URL(string: "codex://threads/\(threadID)") {
                NSWorkspace.shared.open(url)
                return
            }
        }

        let root = pills[source]?.root ?? bubbles[source]?.root ?? ""
        guard !root.isEmpty else { return }
        let folder = URL(fileURLWithPath: root)

        let (bundleID, fallbackPath, name): (String, String, String) = isCodex
            ? ("com.openai.codex", "/Applications/Codex.app", "Codex")
            : ("dev.zed.Zed", "/Applications/Zed.app", "Zed")

        let ws = NSWorkspace.shared
        let appURL = ws.urlForApplication(withBundleIdentifier: bundleID)
            ?? URL(fileURLWithPath: fallbackPath)
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true   // bring the app (and that workspace) to the front
        ws.open([folder], withApplicationAt: appURL, configuration: cfg) { _, err in
            if let err = err {
                NSLog("clawdex: failed to open \(root) in \(name): \(err.localizedDescription)")
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

    // MARK: - Switchboard

    /// Create-or-update a session's pill and (optionally) flip its lit state.
    private func updatePill(source: String, label: String, root: String,
                            threadID: String, lit: Bool?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let pet = self.pet else { return }
            let pill: Pill
            if let existing = self.pills[source] {
                pill = existing
            } else {
                pill = Pill()
                pill.window.onClick = { [weak self] in self?.tapPill(source: source) }
                pill.window.onClose = { [weak self] in self?.removePillOnMain(source: source) }
                pet.addChildWindow(pill.window, ordered: .above)
                self.pills[source] = pill
                self.pillOrder.append(source)
            }
            if !root.isEmpty { pill.root = root }
            if !threadID.isEmpty { pill.threadID = threadID }
            pill.lastSeen = Date()
            if let lit = lit { pill.lit = lit }
            pill.size = pill.window.setContent(label: label, lit: pill.lit,
                                               accent: self.color(for: source))
            self.relayoutPills()
            pill.window.fadeIn()
        }
    }

    /// Clicking a pill focuses its session (Codex thread or editor window). The
    /// pill stays lit — it only dims once the session actually starts working
    /// again; refocusing isn't an acknowledgement.
    private func tapPill(source: String) {
        openProject(source: source)
    }

    /// Drop pills for sessions that have gone quiet — but never one that's still
    /// lit (it needs you, however long that takes). Runs on the main run loop.
    private func prunePills() {
        let now = Date()
        let stale = pillOrder.filter { source in
            guard let pill = pills[source] else { return false }
            return !pill.lit && now.timeIntervalSince(pill.lastSeen) > pillIdleTimeout
        }
        for source in stale { removePillOnMain(source: source) }
    }

    /// Remove a session's pill (from any thread).
    private func removePill(source: String) {
        DispatchQueue.main.async { [weak self] in self?.removePillOnMain(source: source) }
    }

    private func removePillOnMain(source: String) {
        guard let pill = pills.removeValue(forKey: source) else { return }
        pillOrder.removeAll { $0 == source }
        pill.window.fadeOut()
        relayoutPills()
    }

    /// Stack the pills vertically beside the pet, bottom-aligned with the pet's
    /// feet and growing upward (oldest at the bottom). Hugs the pet's right
    /// side, flipping to the left (right-aligned to the pet) when the pet is
    /// parked against the screen's right edge.
    private func relayoutPills() {
        guard let pet = pet else { return }
        let pf = pet.frame
        let widest = pillOrder.compactMap { pills[$0]?.size.width }.max() ?? 0

        // Anchor to the visible sprite edges, not the padded window frame.
        let rightEdge = pf.maxX - petArtInset
        let leftEdge = pf.minX + petArtInset

        var onLeft = false
        if let v = (pet.screen ?? NSScreen.main)?.visibleFrame,
           rightEdge + pillGap + widest > v.maxX - 4 {
            onLeft = true
        }

        var y = pf.minY
        for source in pillOrder {
            guard let pill = pills[source] else { continue }
            let x = onLeft ? leftEdge - pillGap - pill.size.width : rightEdge + pillGap
            pill.window.setFrameOrigin(NSPoint(x: x, y: y))
            y += PillWindow.height + pillGap
        }
    }

    // MARK: - Labeling

    /// The user-facing label for a session. Claude sessions show the bare repo
    /// name (the common case); other agents get a short suffix so a Claude and a
    /// Codex session in the same repo are distinguishable at a glance.
    private static func displayLabel(repo: String, agent: String) -> String {
        guard !repo.isEmpty else { return "" }
        switch agent {
        case "", "claude": return repo
        case "codex":      return "\(repo) ·cdx"
        default:           return "\(repo) ·\(agent)"
        }
    }

    /// The Codex conversation id, recovered from a rollout transcript path.
    /// Codex names them `rollout-<timestamp>-<uuid>.jsonl`, and that trailing
    /// UUID is exactly the id the `codex://threads/<id>` deep link expects.
    /// Returns "" when the path isn't a recognizable rollout file (e.g. a Claude
    /// transcript), so callers can fall back to opening the folder.
    private static func threadID(fromTranscript path: String) -> String {
        guard !path.isEmpty else { return "" }
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        guard stem.hasPrefix("rollout-"), stem.count >= 36 else { return "" }
        let candidate = String(stem.suffix(36))
        return UUID(uuidString: candidate) != nil ? candidate : ""
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
            guard let obj = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any]
            else { continue }
            if let t = assistantText(from: obj)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                return t
            }
        }
        return nil
    }

    /// Pull the assistant's text out of one transcript line, handling both the
    /// Claude Code and Codex rollout shapes:
    ///   Claude: {"type":"assistant","message":{"content":[{"type":"text","text":…}]}}
    ///   Codex:  {"type":"response_item","payload":{"type":"message",
    ///            "role":"assistant","content":[{"type":"output_text","text":…}]}}
    private static func assistantText(from obj: [String: Any]) -> String? {
        // Claude Code.
        if (obj["type"] as? String) == "assistant",
           let msg = obj["message"] as? [String: Any],
           let content = msg["content"] as? [[String: Any]] {
            return lastText(in: content, type: "text")
        }
        // Codex rollout: assistant prose lives in a response_item message.
        if (obj["type"] as? String) == "response_item",
           let payload = obj["payload"] as? [String: Any],
           (payload["type"] as? String) == "message",
           (payload["role"] as? String) == "assistant",
           let content = payload["content"] as? [[String: Any]] {
            return lastText(in: content, type: "output_text")
        }
        return nil
    }

    /// The last non-empty `text` among content blocks of the given block type.
    private static func lastText(in content: [[String: Any]], type: String) -> String? {
        var text = ""
        for block in content where (block["type"] as? String) == type {
            if let t = block["text"] as? String { text = t }
        }
        return text.isEmpty ? nil : text
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
