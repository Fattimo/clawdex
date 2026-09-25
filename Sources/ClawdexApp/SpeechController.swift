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
    /// The kitty window a session runs in (from the hook's KITTY_* env), so a
    /// click can focus that exact tab over kitty's remote-control socket.
    struct KittyTarget {
        var window = ""   // KITTY_WINDOW_ID
        var pid = ""      // KITTY_PID — derives the socket when `sock` is unset
        var sock = ""     // KITTY_LISTEN_ON, e.g. unix:/var/folders/…/T/kitty-123
        var isEmpty: Bool { window.isEmpty }
    }

    private weak var pet: PetWindow?
    private var config: ClawdexConfig

    private final class Bubble {
        let window = SpeechBubbleWindow()
        var size: NSSize = .zero
        var timer: Timer?
        var root: String = ""
        var threadID: String = ""   // Codex conversation id, for the deep link
        var app: String = ""        // launching app's bundle id, for click-to-open
        var kitty = KittyTarget()   // kitty window to focus, when launched in kitty
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
        var label = ""
        var root = ""
        var threadID = ""   // Codex conversation id, for the deep link
        var app = ""        // launching app's bundle id, for click-to-open
        var kitty = KittyTarget()   // kitty window to focus, when launched in kitty
        var paintedLit: Bool?       // last readiness painted onto the kitty tab
        var lastSeen = Date()
        var transcriptPath = ""
        var transcriptOffset: UInt64 = 0
        var transcriptTail = ""
        /// Running Claude Code subagents (agent_id → last event), shown as a
        /// count badge beside the pill instead of pills of their own.
        var subagents: [String: Date] = [:]
        let badge = SubagentBadgeWindow()
        var badgeAttached = false
    }
    private var pillOrder: [String] = []        // oldest → newest, bottom → top
    private var pills: [String: Pill] = [:]
    private let pillIdleTimeout: TimeInterval = 600   // 10 min quiet → prune
    private let pillGap: CGFloat = 2            // near-flush to the visible body
    private let badgeGap: CGFloat = 4           // pill ↔ its subagent badge
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

    init(pet: PetWindow, config: ClawdexConfig = ClawdexConfig()) {
        self.pet = pet
        self.config = config
        // Keep the switchboard glued to the pet (and on the correct side) as it
        // is dragged around the screen.
        pet.onMoved = { [weak self] in self?.relayoutPills() }
        // Sweep out sessions that have gone quiet.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.prunePills()
        }
        // Codex does not currently emit a hook for a user-aborted turn. Its
        // transcript does gain a small abort marker, so watch appended
        // transcript bytes as the narrow fallback for returning to ready.
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkForAbortedTurns()
        }
    }

    func updateConfig(_ config: ClawdexConfig) {
        self.config = config
        if !config.showSwitchboard {
            removeAllPills()
        }
        if config.messageVisibility != .all {
            removeAllBubbles()
        }
    }

    /// Feed one socket event. `narration`, `transcriptPath`, and `source` are
    /// all optional.
    func handle(event: String, narration: String?, transcriptPath: String?,
                source: String?, root: String?, agent: String?, app: String? = nil,
                subagent: String? = nil, kitty: KittyTarget = KittyTarget()) {
        let launchApp = (app ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
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

        // Subagent activity belongs to its parent session: count it on the
        // parent's badge, and never let it create a pill (worktree subagents
        // run in their own agent-<id> dir), flip readiness, or narrate.
        let subagentID = Self.subagentID(subagent)
        if event == "SubagentStart" || event == "SubagentStop" || !subagentID.isEmpty {
            if config.showSwitchboard {
                trackSubagent(id: subagentID, stopped: event == "SubagentStop",
                              transcriptPath: transcriptPath ?? "", fallbackSource: src)
            }
            return
        }

        // Switchboard pill. Only Stop means the agent has actually finished a
        // turn and is ready for the next prompt. Session startup, permission
        // requests, and tool starts stay dim so in-flight work does not flicker
        // as ready. PostToolUse is only a boundary between tool calls, so it
        // leaves the current readiness alone.
        // Done before the prose guard below so readiness tracks even when
        // there's nothing new to say.
        if config.showSwitchboard, !src.isEmpty {
            let lit = Self.litState(for: event, agent: agentTag)
            updatePill(source: src, label: label, root: root ?? "",
                       threadID: threadID, transcriptPath: transcriptPath ?? "",
                       app: launchApp, kitty: kitty, lit: lit)
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
            // Final-only mode intentionally ignores intermediate prose, but it
            // must not consume it from the dedup cache before Stop gets to show
            // the same completed answer.
            if config.messageVisibility == .all || event == "Stop" {
                lastProse[src] = prose
            }
            toShow = prose
        } else if let n = narration, !n.isEmpty {
            toShow = n
        }
        guard let text = toShow else { return }
        // The final turn response arrives on Stop (agent done, ready to reprompt);
        // everything else is filler and gets a muted treatment.
        let isFinal = event == "Stop"
        guard shouldShowMessage(isFinal: isFinal) else { return }
        show(source: src, label: label, root: root ?? "", threadID: threadID,
             app: launchApp, kitty: kitty, text: text, isFinal: isFinal)
    }

    private func shouldShowMessage(isFinal: Bool) -> Bool {
        switch config.messageVisibility {
        case .all:
            return true
        case .finalOnly:
            return isFinal
        case .none:
            return false
        }
    }

    private func show(source: String, label: String, root: String, threadID: String,
                      app: String, kitty: KittyTarget, text raw: String, isFinal: Bool) {
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
            if !app.isEmpty { bubble.app = app }
            if !kitty.isEmpty { bubble.kitty = kitty }

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
    /// (codex://threads/<id>) when we know the id. Otherwise open in the app the
    /// session was launched from (captured by the hook): editors get the project
    /// folder; Claude Desktop is just brought to the front (a folder sends it to
    /// cowork). Falls back to Zed when the launching app is unknown. Pill outlives
    /// the bubble, so it's the first lookup; the bubble is the fallback.
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

        // Prefer the app that actually launched the session (the hook captured
        // it from __CFBundleIdentifier). That way a click reopens the project in
        // Claude Desktop / VS Code / Zed / whatever you started from, instead of
        // a hardcoded editor. Empty over ssh/tmux/launchd → fall back to Zed.
        let launchApp = pills[source]?.app ?? bubbles[source]?.app ?? ""

        let ws = NSWorkspace.shared
        let appURL: URL
        let name: String
        if isCodex {
            name = "Codex"
            appURL = ws.urlForApplication(withBundleIdentifier: "com.openai.codex")
                ?? URL(fileURLWithPath: "/Applications/Codex.app")
        } else if !launchApp.isEmpty,
                  let resolved = ws.urlForApplication(withBundleIdentifier: launchApp) {
            name = launchApp
            appURL = resolved
        } else {
            name = "Zed"
            appURL = ws.urlForApplication(withBundleIdentifier: "dev.zed.Zed")
                ?? URL(fileURLWithPath: "/Applications/Zed.app")
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true   // bring the app (and that workspace) to the front

        // kitty: focus the session's own tab over the remote-control socket.
        // Handing kitty a folder would spawn a new window, so never do that —
        // if the tab can't be reached, just bring kitty to the front.
        if launchApp == Self.kittyBundleID {
            let kitty = pills[source]?.kitty ?? bubbles[source]?.kitty ?? KittyTarget()
            Self.focusKitty(kitty, appURL: appURL)
            ws.openApplication(at: appURL, configuration: cfg) { _, err in
                if let err = err {
                    NSLog("clawdex: failed to focus kitty: \(err.localizedDescription)")
                }
            }
            return
        }

        // Claude Desktop hosts its sessions in-app; handing it a folder drops you
        // in cowork rather than your session, so just bring the app to the front.
        // Editors (Zed, VS Code, …) do the right thing with a folder — open/focus
        // that project's window — so keep passing it to them.
        if launchApp == "com.anthropic.claudefordesktop" {
            ws.openApplication(at: appURL, configuration: cfg) { _, err in
                if let err = err {
                    NSLog("clawdex: failed to focus \(name): \(err.localizedDescription)")
                }
            }
            return
        }

        // A stale pill can outlive its project folder — a deleted git worktree, a
        // temp dir, an unmounted volume. Handing NSWorkspace a path that's gone
        // makes macOS pop a "'<folder>' can't be found" alert, which is just noise
        // when the session no longer exists. Skip the open in that case; the pill
        // can still be dismissed with its ✕.
        guard FileManager.default.fileExists(atPath: root) else {
            NSLog("clawdex: skip open, folder gone: \(root)")
            return
        }

        ws.open([folder], withApplicationAt: appURL, configuration: cfg) { _, err in
            if let err = err {
                NSLog("clawdex: failed to open \(root) in \(name): \(err.localizedDescription)")
            }
        }
    }

    private static let kittyBundleID = "net.kovidgoyal.kitty"

    /// Resolve the kitty instance's remote-control socket. Prefers the hook's
    /// KITTY_LISTEN_ON; otherwise assumes `listen_on unix:${TMPDIR}/kitty`, which
    /// kitty suffixes with its PID. Only per-user temp-dir sockets are accepted,
    /// so hook input can't point us at an arbitrary socket.
    private static func kittySocket(_ k: KittyTarget) -> String? {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path
        var path: String
        if k.sock.hasPrefix("unix:") {
            path = String(k.sock.dropFirst("unix:".count))
        } else if !k.pid.isEmpty, k.pid.allSatisfy(\.isASCII), k.pid.allSatisfy(\.isNumber) {
            path = tmp + "/kitty-" + k.pid
        } else {
            return nil
        }
        path = URL(fileURLWithPath: path).standardizedFileURL.path
        guard path.hasPrefix(tmp + "/"),
              let type = try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType,
              type == .typeSocket else { return nil }
        return "unix:" + path
    }

    /// Ask kitty to focus the session's window (and so its tab).
    private static func focusKitty(_ k: KittyTarget, appURL: URL) {
        runKitten(k, ["focus-window", "--match", "id:" + k.window])
    }

    /// Mirror the pill onto the session's kitty tab: the switchboard accent
    /// and a ● marker when ready for you, neutral near-black and a ○ while
    /// it's working. Only
    /// repaints on a readiness change, so busy sessions don't spawn a kitten
    /// per hook event.
    private func paintKittyTab(_ pill: Pill, source: String) {
        guard !pill.kitty.isEmpty, pill.paintedLit != pill.lit else { return }
        pill.paintedLit = pill.lit
        let accent = Self.rgb(color(for: source))
        let colors: [String]
        if pill.lit {
            colors = ["active_bg=" + Self.hex(accent),
                      "active_fg=#ffffff",
                      "inactive_bg=" + Self.hex(Self.mix(accent, (0, 0, 0), 0.5)),
                      "inactive_fg=#d0d0d0"]
        } else {
            // Working: a neutral near-black reserved for busy sessions, so it
            // never reads as any session's accent.
            colors = ["active_bg=#2a2a2a",
                      "active_fg=#b0b0b0",
                      "inactive_bg=#141414",
                      "inactive_fg=#6a6a6a"]
        }
        Self.runKitten(pill.kitty, ["set-tab-color", "--match", "window_id:" + pill.kitty.window] + colors)
        Self.markKittyTab(pill.kitty, marker: pill.lit ? Self.readyMarker : Self.workingMarker)
    }

    private static let readyMarker = "●"
    private static let workingMarker = "○"

    /// The tab's own title (e.g. the session file's `new_tab app`), captured the
    /// first time we mark it so the marker can be swapped or removed without
    /// clobbering the name. Keyed by "<kitty pid>:<window id>"; kittyQueue only.
    private static var kittyBaseTitles: [String: String] = [:]

    /// Prefix the session's kitty tab title with `marker`, or restore the plain
    /// title when `marker` is nil.
    private static func markKittyTab(_ k: KittyTarget, marker: String?) {
        guard let sock = kittyTarget(k) else { return }
        kittyQueue.async {
            let key = k.pid + ":" + k.window
            if kittyBaseTitles[key] == nil {
                guard let out = execKitten(sock, ["ls", "--match", "id:" + k.window]),
                      let title = tabTitle(fromLS: out) else { return }
                kittyBaseTitles[key] = stripMarker(title)
            }
            guard let base = kittyBaseTitles[key] else { return }
            let title = marker.map { $0 + " " + base } ?? base
            if marker == nil { kittyBaseTitles[key] = nil }
            _ = execKitten(sock, ["set-tab-title", "--match", "window_id:" + k.window, title])
        }
    }

    private static func stripMarker(_ title: String) -> String {
        for m in [readyMarker, workingMarker] where title.hasPrefix(m + " ") {
            return String(title.dropFirst(m.count + 1))
        }
        return title
    }

    /// Title of the (single) tab in `kitten @ ls --match id:N` output.
    private static func tabTitle(fromLS data: Data) -> String? {
        guard let osWindows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let tabs = osWindows.first?["tabs"] as? [[String: Any]],
              let title = tabs.first?["title"] as? String else { return nil }
        return title
    }

    private static func rgb(_ c: NSColor) -> (Double, Double, Double) {
        // System colors are dynamic; resolve them as they look in dark mode,
        // which is what a terminal tab bar sits against.
        var out: (Double, Double, Double) = (0.5, 0.5, 0.5)
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            if let s = c.usingColorSpace(.sRGB) {
                out = (Double(s.redComponent), Double(s.greenComponent), Double(s.blueComponent))
            }
        }
        return out
    }

    /// Blend `a` toward `b` by `t` (0 = a, 1 = b).
    private static func mix(_ a: (Double, Double, Double), _ b: (Double, Double, Double),
                            _ t: Double) -> (Double, Double, Double) {
        (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
    }

    private static func hex(_ c: (Double, Double, Double)) -> String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(c.0), byte(c.1), byte(c.2))
    }

    private static let kittenURL: URL? = NSWorkspace.shared
        .urlForApplication(withBundleIdentifier: kittyBundleID)?
        .appendingPathComponent("Contents/MacOS/kitten")

    /// Serializes kitten calls so a session's color/title updates land in order.
    private static let kittyQueue = DispatchQueue(label: "clawdex.kitty", qos: .userInitiated)

    /// Validated socket for the session's kitty, or nil (logged) if unreachable.
    private static func kittyTarget(_ k: KittyTarget) -> String? {
        guard !k.window.isEmpty, k.window.allSatisfy(\.isASCII), k.window.allSatisfy(\.isNumber),
              let sock = kittySocket(k), kittenURL != nil else {
            NSLog("clawdex: no kitty socket for window \(k.window); set listen_on in kitty.conf")
            return nil
        }
        return sock
    }

    /// Run a `kitten @` remote-control command against the session's kitty.
    /// Best-effort, fire-and-forget.
    private static func runKitten(_ k: KittyTarget, _ args: [String]) {
        guard let sock = kittyTarget(k) else { return }
        kittyQueue.async { _ = execKitten(sock, args) }
    }

    /// Run kitten synchronously (argv only, no shell); stdout on success.
    private static func execKitten(_ sock: String, _ args: [String]) -> Data? {
        guard let kitten = kittenURL else { return nil }
        let p = Process()
        p.executableURL = kitten
        p.arguments = ["@", "--to", sock] + args
        let out = Pipe()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                NSLog("clawdex: kitten \(args.first ?? "") exited \(p.terminationStatus)")
                return nil
            }
            return data
        } catch {
            NSLog("clawdex: failed to run kitten: \(error.localizedDescription)")
            return nil
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

    /// Map a hook event to a pill's lit state. Returns `nil` to leave the pill
    /// as it is. Claude and Codex expose readiness differently, so each gets its
    /// own model rather than one shared switch:
    ///
    /// - Claude tells us directly when it's waiting on you. A fresh/cleared
    ///   session (SessionStart) is parked on your first prompt, Stop ends a turn,
    ///   and Notification is "waiting for you" — all lit. Working events dim it.
    /// - Codex has no waiting-on-you event we can trust: its PermissionRequest
    ///   fires mid-turn while it keeps working, and it emits no Stop on a user
    ///   abort (the transcript abort marker covers that, see checkForAbortedTurns).
    ///   So only Stop lights it; everything ambiguous is left as-is.
    static func litState(for event: String, agent: String) -> Bool? {
        if agent == "codex" {
            switch event {
            case "Stop":
                return true
            case "SessionStart", "UserPromptSubmit", "PreToolUse",
                 "PreCompact", "PostCompact":
                return false
            default:
                // Notification / PermissionRequest / PostToolUse / SubagentStop:
                // leave the pill as-is. PermissionRequest mid-work stays dim
                // (PreToolUse already dimmed it); a PostToolUse trailing a Stop
                // must not re-dim a finished turn.
                return nil
            }
        }
        // Claude (and any unknown agent): the original waiting-on-you model.
        switch event {
        case "SessionStart", "Stop", "Notification":
            return true
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PreCompact":
            return false
        default:
            return nil   // SubagentStop, PostCompact, etc: leave the pill as-is
        }
    }

    /// Create-or-update a session's pill and (optionally) flip its lit state.
    private func updatePill(source: String, label: String, root: String,
                            threadID: String, transcriptPath: String, app: String,
                            kitty: KittyTarget, lit: Bool?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let pet = self.pet else { return }
            let pill: Pill
            if let existing = self.pills[source] {
                pill = existing
            } else {
                pill = Pill()
                pill.window.onClick = { [weak self] in self?.tapPill(source: source) }
                pill.window.onClose = { [weak self] in self?.removePillOnMain(source: source) }
                pill.badge.onClick = { [weak self] in self?.tapPill(source: source) }
                pet.addChildWindow(pill.window, ordered: .above)
                self.pills[source] = pill
                self.pillOrder.append(source)
            }
            pill.label = label
            if !root.isEmpty { pill.root = root }
            if !threadID.isEmpty { pill.threadID = threadID }
            if !app.isEmpty { pill.app = app }
            if !kitty.isEmpty { pill.kitty = kitty }
            if !transcriptPath.isEmpty {
                pill.transcriptPath = transcriptPath
                pill.transcriptOffset = Self.transcriptSize(path: transcriptPath)
                pill.transcriptTail = ""
            }
            pill.lastSeen = Date()
            if let lit = lit { pill.lit = lit }
            pill.size = pill.window.setContent(label: label, lit: pill.lit,
                                               accent: self.color(for: source))
            self.paintKittyTab(pill, source: source)
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
        // A subagent whose SubagentStop never arrived (interrupted turn, daemon
        // restart) ages out on the same clock as a quiet session.
        var badgesChanged = false
        for source in pillOrder {
            guard let pill = pills[source], !pill.subagents.isEmpty else { continue }
            let before = pill.subagents.count
            pill.subagents = pill.subagents.filter { now.timeIntervalSince($0.value) <= pillIdleTimeout }
            if pill.subagents.count != before {
                refreshBadge(pill)
                badgesChanged = true
            }
        }
        if badgesChanged { relayoutPills() }
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
        if pill.paintedLit != nil {
            Self.runKitten(pill.kitty, ["set-tab-color", "--match", "window_id:" + pill.kitty.window,
                                        "active_bg=NONE", "active_fg=NONE",
                                        "inactive_bg=NONE", "inactive_fg=NONE"])
            Self.markKittyTab(pill.kitty, marker: nil)
        }
        pill.window.fadeOut()
        if pill.badgeAttached { pill.badge.fadeOut() }
        relayoutPills()
    }

    private func removeAllPills() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            for source in self.pillOrder {
                self.removePillOnMain(source: source)
            }
        }
    }

    private func removeAllBubbles() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            for source in self.order {
                self.expire(source: source)
            }
        }
    }

    /// Claude Code agent ids are short hex-ish tokens. Anything else from the
    /// socket is dropped rather than trusted as a dictionary key.
    private static func subagentID(_ raw: String?) -> String {
        let id = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.count <= 64,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return "" }
        return id
    }

    /// Record a subagent event on its parent session's pill. Claude passes the
    /// parent's transcript_path on subagent events, which is the reliable link
    /// — the subagent's cwd may be a worktree. Falls back to the cwd-derived
    /// key only if that pill already exists.
    private func trackSubagent(id: String, stopped: Bool, transcriptPath: String,
                               fallbackSource: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let parent = transcriptPath.isEmpty ? nil
                : self.pillOrder.last { self.pills[$0]?.transcriptPath == transcriptPath }
            guard let source = parent ?? (self.pills[fallbackSource] != nil ? fallbackSource : nil),
                  let pill = self.pills[source] else { return }
            if !id.isEmpty {
                // Any in-subagent event (not just SubagentStart) marks it
                // running, so the count self-heals after a missed start.
                pill.subagents[id] = stopped ? nil : Date()
            }
            pill.lastSeen = Date()
            self.refreshBadge(pill)
            self.relayoutPills()
        }
    }

    /// Show, update, or hide a pill's subagent badge to match its count.
    private func refreshBadge(_ pill: Pill) {
        let n = pill.subagents.count
        guard n > 0 else {
            if pill.badgeAttached { pill.badge.hide() }
            return
        }
        pill.badge.count = n
        if !pill.badgeAttached, let pet = pet {
            pet.addChildWindow(pill.badge, ordered: .above)
            pill.badgeAttached = true
        }
        pill.badge.show()
    }

    private func checkForAbortedTurns() {
        for source in pillOrder {
            guard let pill = pills[source], !pill.lit, !pill.transcriptPath.isEmpty else { continue }
            let update = Self.abortMarkerUpdate(path: pill.transcriptPath,
                                                offset: pill.transcriptOffset,
                                                tail: pill.transcriptTail)
            pill.transcriptOffset = update.offset
            pill.transcriptTail = update.tail
            guard update.found else { continue }

            pill.lit = true
            pill.lastSeen = Date()
            pill.size = pill.window.setContent(label: pill.label, lit: true,
                                               accent: self.color(for: source))
            paintKittyTab(pill, source: source)
            relayoutPills()
            pill.window.fadeIn()
        }
    }

    private static func transcriptSize(path: String) -> UInt64 {
        guard let fh = FileHandle(forReadingAtPath: path) else { return 0 }
        defer { try? fh.close() }
        return (try? fh.seekToEnd()) ?? 0
    }

    private static func abortMarkerUpdate(path: String, offset: UInt64,
                                          tail: String) -> (found: Bool, offset: UInt64, tail: String) {
        guard let fh = FileHandle(forReadingAtPath: path) else {
            return (false, offset, tail)
        }
        defer { try? fh.close() }

        let size = (try? fh.seekToEnd()) ?? offset
        guard size > offset else {
            return size < offset ? (false, size, "") : (false, size, tail)
        }
        try? fh.seek(toOffset: offset)
        guard let data = try? fh.readToEnd(), !data.isEmpty else {
            return (false, size, tail)
        }

        let chunk = String(decoding: data, as: UTF8.self)
        let scan = tail + chunk
        return (scan.contains("<turn_aborted>"), size, String(scan.suffix(128)))
    }

    /// Stack the pills vertically beside the pet, bottom-aligned with the pet's
    /// feet and growing upward (oldest at the bottom). Hugs the pet's right
    /// side, flipping to the left (right-aligned to the pet) when the pet is
    /// parked against the screen's right edge.
    private func relayoutPills() {
        guard let pet = pet else { return }
        let pf = pet.frame
        let widest = pillOrder.compactMap { source -> CGFloat? in
            guard let pill = pills[source] else { return nil }
            return pill.size.width
                + (pill.subagents.isEmpty ? 0 : badgeGap + SubagentBadgeWindow.size)
        }.max() ?? 0

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
            // Subagent badge on the pill's outward side, away from the pet.
            let bx = onLeft ? x - badgeGap - SubagentBadgeWindow.size
                            : x + pill.size.width + badgeGap
            pill.badge.setFrameOrigin(NSPoint(x: bx, y: y))
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
