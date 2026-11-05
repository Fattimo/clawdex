import AppKit
import Foundation

/// Decides what the pet "says" and drives the speech bubbles.
///
/// The latest update appears in one labeled bubble centered above the pet.
/// Session switches remain visible independently of the message's lifetime.
///
/// Two speech sources, in priority order:
///   1. Real prose — the latest assistant text block from the session
///      transcript (`transcript_path`). What Claude is actually saying.
///   2. Action narration — a synthesized one-liner from the hook
///      ("Editing main.swift") shown when there's no fresh prose, e.g.
///      mid-tool-call.
final class SpeechController {
    var onPillLayout: (() -> Void)?
    /// The kitty window a session runs in (from the hook's KITTY_* env), so a
    /// click can focus that exact tab over kitty's remote-control socket.
    struct KittyTarget: Equatable {
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
        var neutral = false
        var retiredSessionIDs: [String] = []
        var label = ""
        var root = ""
        var threadID = ""   // Codex conversation id, for the deep link
        var app = ""        // launching app's bundle id, for click-to-open
        var kitty = KittyTarget()   // kitty window to focus, when launched in kitty
        var paintedLit: Bool?       // last readiness painted onto the kitty tab
        var paintedNeutral: Bool?
        var paintedKitty: KittyTarget? // actual client tab, not the hook server's
        var paintingKitty = false
        var agent = ""
        var sessionID = ""
        var sessionEpoch = 0
        var observedSessionID = ""
        var observedSessionEpoch = 0
        var activeTurnID = ""
        var observedClientID: String?
        var observedProcessID: Int?
        var observedThreadID = ""
        /// Last hook event or transcript growth — the session's activity clock.
        var lastSeen = Date()
        var transcriptPath = ""
        var transcriptOffset: UInt64 = 0
        var transcript = TranscriptScan()
        var compacting = false
        /// Running Claude Code subagents (agent_id → last event), shown as a
        /// count badge beside the pill instead of pills of their own.
        var subagents: [String: Date] = [:]
        let badge = SubagentBadgeWindow()
        var badgeAttached = false
        var badgeContent: SubagentBadgeView.Content?
    }

    /// What the transcript poller knows about a session, accumulated from the
    /// lines appended since the pill started watching that transcript.
    struct TranscriptScan {
        var partialLine = ""
        var openTools: Set<String> = []          // tool_use ids with no tool_result yet
        var backgroundJobs: [String: Date] = [:] // backgroundTaskId → launch
        var sawAbort = false
        var codexReady: Bool?
        var codexTransition: Bool?
        var codexTurnID = ""
        var codexHasLifecycle = false
    }
    private var pillOrder: [String] = []        // oldest → newest, alternating sides
    private var pills: [String: Pill] = [:]
    private var knownCodexTranscripts: [String: String] = [:]
    private let pillIdleTimeout: TimeInterval = 600   // 10 min quiet → prune
    /// A dim Claude pill with nothing in flight and no activity for this long
    /// shows "?": the turn most likely ended without a hook (Esc before the
    /// first reply rewinds the prompt and leaves no transcript marker). 99% of
    /// model replies land within ~45s of the prompt or last tool result.
    var stallTimeout: TimeInterval = 60
    /// Background jobs whose completion notification never arrives (session
    /// killed, daemon restart) stop showing "…" after this long.
    private let backgroundJobTimeout: TimeInterval = 7200
    private let badgeGap: CGFloat = 4           // pill ↔ its subagent badge

    private let maxBubbles = 1
    private let gap: CGFloat = 6

    /// Bank of contrasting, theme-adapting workspace colors. Each environment
    /// (source) gets the next one, cycling — stable for the daemon's lifetime so
    /// a project keeps its color.
    static func sessionAccent(agent: String, index: Int) -> NSColor {
        let palette: [NSColor] = agent == "codex" ? [.systemBlue, .systemTeal, .systemIndigo, .systemCyan]
                                                : [.systemOrange, .systemRed, .systemYellow, .systemBrown]
        return palette[index % palette.count]
    }
    private var colorIndices: [String: Int] = [:]
    private var colorBySource: [String: NSColor] = [:]
    private var kittyDiscoveryTimer: Timer?
    private var kittyDiscoveryInFlight = false
    private var kittyDiscoveryGeneration = UUID()
    private var dismissedKittyClients = Set<String>()

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
        if source == "GitHub" { return .systemGreen }
        if let c = colorBySource[source] { return c }
        let agent = Self.agent(ofKey: source)
        let index = colorIndices[agent, default: 0]
        let c = Self.sessionAccent(agent: agent, index: index)
        colorIndices[agent] = index + 1
        colorBySource[source] = c
        return c
    }

    deinit { kittyDiscoveryTimer?.invalidate() }

    private static func sourceKey(repo: String, root: String, agent: String) -> String {
        let identity = root.hasPrefix("/") ? URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path : repo
        return identity + keySep + agent
    }

    private func sessionSource(repo: String, root: String, agent: String, sessionID: String = "", transcript: String = "") -> String {
        let candidates = pillOrder.filter { pills[$0]?.agent == agent }
        if let match = candidates.first(where: { source in
            guard let pill = pills[source] else { return false }
            return (!sessionID.isEmpty && pill.sessionID == sessionID) || (!transcript.isEmpty && pill.transcriptPath == transcript)
        }) { return match }
        let canonical = root.hasPrefix("/") ? URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path : root
        if let match = candidates.first(where: { pills[$0]?.root == canonical }) { return match }
        if let common = KittySessionResolver.repositoryIdentity(root) {
            let matches = candidates.filter { source in
                guard let pill = pills[source] else { return false }
                return (pill.root as NSString).lastPathComponent == (root as NSString).lastPathComponent
                    && KittySessionResolver.repositoryIdentity(pill.root) == common
            }
            if matches.count == 1 { return matches[0] }
        }
        return Self.sourceKey(repo: repo, root: root, agent: agent)
    }

    func startKittyObservation() {
        guard kittyDiscoveryTimer == nil else { return }
        kittyDiscoveryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.discoverKittySessions() }
        discoverKittySessions()
    }
    func stopKittyObservation() {
        kittyDiscoveryTimer?.invalidate(); kittyDiscoveryTimer = nil
        kittyDiscoveryGeneration = UUID(); kittyDiscoveryInFlight = false
    }
    private func discoverKittySessions() {
        guard config.showSwitchboard, !kittyDiscoveryInFlight, Self.kittenURL != nil else { return }
        kittyDiscoveryInFlight = true
        let generation = kittyDiscoveryGeneration
        let knownTranscripts = knownCodexTranscripts
        let known = Set(pills.values.compactMap { Self.kittySocket($0.kitty) })
        Self.kittyQueue.async { [weak self] in
            let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            let discovered = files.compactMap { file -> String? in
                let name = file.lastPathComponent
                guard name.hasPrefix("kitty-"), !name.dropFirst(6).isEmpty,
                      name.dropFirst(6).allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
                return Self.kittySocket(KittyTarget(window: "0", sock: "unix:" + file.path))
            }
            let sockets = Array((known.sorted() + discovered.sorted()).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.prefix(4))
            let snapshots = sockets.compactMap { socket -> (String, [KittySessionResolver.Client])? in
                guard let data = Self.execKitten(socket, ["ls"]), var clients = KittySessionResolver.clients(in: data) else { return nil }
                for index in clients.indices.prefix(32) where clients[index].agent == "codex" {
                    let thread = clients[index].resumeThreadID
                    if !thread.isEmpty {
                        clients[index].resumeTranscriptPath = knownTranscripts[thread]
                            ?? KittySessionResolver.transcriptPath(for: thread) ?? ""
                    }
                    let observedAt = Date()
                    if let screen = Self.execKitten(socket, ["get-text", "--match", "id:" + clients[index].window, "--extent", "screen"]),
                       KittySessionResolver.isEmptyCodexPrompt(screen, root: clients[index].root) {
                        clients[index].emptyPromptObservedAt = observedAt
                    }
                }
                return (socket, clients)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.kittyDiscoveryGeneration == generation else { return }
                self.kittyDiscoveryInFlight = false
                for (socket, clients) in snapshots {
                    for client in clients where !client.resumeTranscriptPath.isEmpty {
                        self.rememberCodexTranscript(client.resumeTranscriptPath, threadID: client.resumeThreadID)
                    }
                    self.reconcileKittySessions(clients, socket: socket)
                }
            }
        }
    }

    /// Only successful local snapshots may remove a client. Hook activity owns
    /// readiness after registration; presence checks never reset a busy turn.
    func reconcileKittySessions(_ clients: [KittySessionResolver.Client], socket: String) {
        guard config.showSwitchboard else { return }
        let prefix = socket + "#"
        let present = Set(clients.map { prefix + $0.identity })
        let grouped = Dictionary(grouping: clients) { sessionSource(repo: "", root: $0.root, agent: $0.agent) }
        dismissedKittyClients = dismissedKittyClients.filter { !$0.hasPrefix(prefix) || present.contains($0) }
        for source in pillOrder {
            guard let pill = pills[source] else { continue }
            if let id = pill.observedClientID, id.hasPrefix(prefix), !present.contains(id), grouped[source]?.count != 1 {
                removePillOnMain(source: source)
            } else if pill.observedClientID == nil, grouped[source] == nil,
                      (Self.kittySocket(pill.kitty) == socket || pill.kitty.sock == socket),
                      Date().timeIntervalSince(pill.lastSeen) > 3 {
                // A late hook from a closed client must not leave a ghost pill.
                removePillOnMain(source: source)
            }
        }
        for source in grouped.keys.sorted() {
            guard let group = grouped[source], group.count == 1, let client = group.first else { continue }
            let id = prefix + client.identity
            guard !dismissedKittyClients.contains(id) else { continue }
            if let pill = pills[source], pill.observedClientID != nil, pill.observedClientID != id {
                let freshHook = pill.sessionEpoch != pill.observedSessionEpoch
                    || (!pill.sessionID.isEmpty && pill.sessionID != pill.observedSessionID)
                if !freshHook { removePillOnMain(source: source) }
            }
            let pid = URL(fileURLWithPath: String(socket.dropFirst(5))).lastPathComponent
                .replacingOccurrences(of: "kitty-", with: "")
            let target = KittyTarget(window: client.window, pid: pid.allSatisfy(\.isNumber) ? pid : "", sock: socket)
            let newlyRegistered = pills[source] == nil
            if newlyRegistered {
                updatePill(source: source, label: Self.displayLabel(repo: (client.root as NSString).lastPathComponent, agent: client.agent),
                    agent: client.agent, root: client.root, threadID: "", transcriptPath: "", app: Self.kittyBundleID,
                    kitty: target, lit: true, compacting: false)
            }
            guard let pill = pills[source] else { continue }
            let bindThread = !client.resumeThreadID.isEmpty && (pill.observedThreadID.isEmpty
                || (pill.observedClientID != nil && pill.observedClientID != id))
            if bindThread {
                pill.observedThreadID = client.resumeThreadID
                if !client.resumeTranscriptPath.isEmpty,
                   pill.threadID.isEmpty || Self.isCodexBackgroundFork(path: pill.transcriptPath, foregroundThreadID: client.resumeThreadID) {
                    let initial = Self.transcriptSnapshot(path: client.resumeTranscriptPath)
                    pill.transcriptPath = client.resumeTranscriptPath; pill.transcriptOffset = initial.offset
                    pill.transcript = initial.state; pill.threadID = client.resumeThreadID
                    pill.sessionID = client.resumeThreadID; pill.activeTurnID = initial.state.codexTurnID
                    pill.lit = initial.state.codexReady ?? false; pill.neutral = false; pill.paintedLit = nil
                    pill.size = pill.window.setContent(label: pill.label, lit: pill.lit, accent: color(for: source))
                }
            }
            let changed = pill.kitty != target || pill.observedClientID != id || pill.root != client.root
            pill.observedClientID = id; pill.observedProcessID = client.processID
            pill.observedSessionID = pill.sessionID; pill.observedSessionEpoch = pill.sessionEpoch
            pill.kitty = target; pill.app = Self.kittyBundleID; pill.root = client.root
            if let observedAt = client.emptyPromptObservedAt,
               newlyRegistered || pill.lastSeen <= observedAt {
                neutralizeCodexClient(source: source)
            }
            if changed { pill.paintedLit = nil }
            if changed || pill.paintedLit != pill.lit { paintKittyTab(pill, source: source) }
        }
    }

    init(pet: PetWindow, config: ClawdexConfig = ClawdexConfig()) {
        self.pet = pet
        self.config = config
        // Keep the switchboard glued to the pet (and on the correct side) as it
        // is dragged around the screen.
        pet.onMoved = { [weak self] in self?.relayoutPills(); self?.relayout() }
        // Sweep out sessions that have gone quiet.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.prunePills()
        }
        // Neither Claude nor Codex emits a hook for a user-aborted turn (Claude
        // skips Stop on Esc). Both transcripts do gain a small abort marker, so
        // watch appended transcript bytes as the narrow fallback for returning
        // to ready.
        // The same poll tracks in-flight tools and background jobs for the
        // pill's badge ("?" / "…").
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.scanTranscripts()
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
                subagent: String? = nil, kitty: KittyTarget = KittyTarget(),
                sessionID: String = "", sessionSource: String = "", turnID: String = "") {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.handle(event: event, narration: narration, transcriptPath: transcriptPath, source: source,
                    root: root, agent: agent, app: app, subagent: subagent, kitty: kitty,
                    sessionID: sessionID, sessionSource: sessionSource, turnID: turnID)
            }
            return
        }
        let launchApp = (app ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let repo = (source ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let agentTag = (agent ?? "claude")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if agentTag == "codex", Self.isCodexSubagentTranscript(path: transcriptPath ?? "") { return }
        // Composite identity keyed on repo + agent: the same project running
        // under Claude and Codex at once gets its own pill, bubble, and accent
        // color instead of clobbering one shared entry. `label` is what the user
        // sees — it marks non-Claude agents (e.g. "pylon ·cdx").
        let src = repo.isEmpty ? "" : self.sessionSource(repo: repo, root: root ?? "", agent: agentTag,
            sessionID: sessionID, transcript: transcriptPath ?? "")
        let threadID = Self.threadID(fromTranscript: transcriptPath ?? "")
        let resuming = agentTag == "codex" && event == "SessionStart" && sessionSource == "resume"
            && UUID(uuidString: sessionID) != nil
            && (threadID.isEmpty || threadID.lowercased() == sessionID.lowercased())
        if resuming { pills[src]?.retiredSessionIDs.removeAll { $0 == sessionID } }
        if agentTag == "codex", !sessionID.isEmpty,
           pills[src]?.retiredSessionIDs.contains(sessionID) == true { return }
        // Internal clients can emit hooks without a transcript or agent_id.
        // They must not replace the identity/readiness of a busy foreground
        // session just because they share its working directory.
        if agentTag == "codex", (transcriptPath ?? "").isEmpty,
           let pill = pills[src], (!pill.lit || pill.neutral), !pill.sessionID.isEmpty,
           !sessionID.isEmpty, sessionID != pill.sessionID,
           !(pill.neutral && event == "UserPromptSubmit"), !resuming { return }
        let label = Self.displayLabel(repo: repo, agent: agentTag)
        // Codex conversation id, recovered from the rollout transcript filename,
        // so a pill click can deep-link straight to that thread.
        if agentTag == "codex" {
            if let bound = pills[src]?.observedThreadID, !bound.isEmpty,
               !resuming, Self.isCodexBackgroundFork(path: transcriptPath ?? "", foregroundThreadID: bound) { return }
            rememberCodexTranscript(transcriptPath ?? "", threadID: threadID)
            if event == "SessionStart", ["clear", "resume"].contains(sessionSource), !threadID.isEmpty {
                pills[src]?.observedThreadID = threadID
            }
        }

        // Session closed: drop its pill and stop — there's nothing to narrate.
        if event == "SessionEnd" {
            if !src.isEmpty { removePill(source: src, sessionID: sessionID, transcriptPath: transcriptPath ?? "") }
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
            let lit = event == "SessionStart" && sessionSource == "compact" ? nil : Self.litState(for: event, agent: agentTag)
            updatePill(source: src, label: label, agent: agentTag, root: root ?? "",
                       threadID: threadID, transcriptPath: transcriptPath ?? "",
                       app: launchApp, kitty: kitty, lit: lit,
                       compacting: event == "PreCompact",
                       turnEnded: event == "Stop" || event == "StopFailure" || event == "Interrupt", sessionID: sessionID,
                       sessionStarted: event == "SessionStart", event: event, turnID: turnID,
                       sessionCleared: event == "SessionStart" && sessionSource == "clear", sessionResumed: resuming)
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
                      app: String, kitty: KittyTarget, text raw: String, isFinal: Bool,
                      onOpen: (() -> Void)? = nil) {
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
            }
            if !root.isEmpty { bubble.root = root }
            if !threadID.isEmpty { bubble.threadID = threadID }
            if !app.isEmpty { bubble.app = app }
            if !kitty.isEmpty { bubble.kitty = kitty }
            if let onOpen { bubble.window.onOpen = onOpen }
            self.order.removeAll { $0 == source }
            self.order.append(source)
            self.evictOverflow()

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
                b.window.orderOut(nil)
                pet?.removeChildWindow(b.window)
            }
        }
    }

    /// Focus the session. Desktop Codex sessions deep-link to their thread
    /// (codex://threads/<id>) when we know the id. Otherwise open in the app the
    /// session was launched from (captured by the hook): editors get the project
    /// folder; Claude Desktop is just brought to the front (a folder sends it to
    /// cowork). Falls back to Zed when the launching app is unknown. Pill outlives
    /// the bubble, so it's the first lookup; the bubble is the fallback.
    private func openProject(source: String) {
        let isCodex = Self.agent(ofKey: source) == "codex"
        let launchApp = pills[source]?.app ?? bubbles[source]?.app ?? ""
        let useCodexApp = Self.usesCodexDesktop(agent: isCodex ? "codex" : "claude", app: launchApp)

        if useCodexApp {
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
        let ws = NSWorkspace.shared
        let appURL: URL
        let name: String
        if useCodexApp {
            name = "Codex"
            appURL = ws.urlForApplication(withBundleIdentifier: "com.openai.codex")
                ?? URL(fileURLWithPath: "/Applications/Codex.app")
        } else if !launchApp.isEmpty,
                  let resolved = ws.urlForApplication(withBundleIdentifier: Self.bundleID(for: launchApp)) {
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
        if Self.bundleID(for: launchApp) == Self.kittyBundleID {
            let kitty = pills[source]?.kitty ?? bubbles[source]?.kitty ?? KittyTarget()
            Self.focusKitty(kitty, root: root, agent: isCodex ? "codex" : "claude", clientPID: pills[source]?.observedProcessID)
            ws.openApplication(at: appURL, configuration: cfg) { _, err in
                if let err = err {
                    NSLog("clawdex: failed to focus kitty: \(err.localizedDescription)")
                }
            }
            return
        }

        // Terminals should activate their existing windows. Claude Desktop
        // hosts its sessions in-app; handing it a folder drops you
        // in cowork rather than your session, so just bring the app to the front.
        // Editors (Zed, VS Code, …) do the right thing with a folder — open/focus
        // that project's window — so keep passing it to them.
        if launchApp == "com.anthropic.claudefordesktop" || Self.isTerminalApp(launchApp) {
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

    // CLI hooks identify their terminal/editor; opening a desktop Codex thread
    // would send the user to a different client than the one doing the work.
    static func usesCodexDesktop(agent: String, app: String) -> Bool {
        agent == "codex" && (app.isEmpty || app == "com.openai.codex")
    }

    private static func bundleID(for app: String) -> String {
        switch app {
        case "Apple_Terminal": return "com.apple.Terminal"
        case "iTerm.app": return "com.googlecode.iterm2"
        case "ghostty": return "com.mitchellh.ghostty"
        case "WezTerm": return "com.github.wez.wezterm"
        case "kitty": return kittyBundleID
        default: return app
        }
    }

    private static func isTerminalApp(_ app: String) -> Bool {
        ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
         "com.github.wez.wezterm", "io.alacritty", kittyBundleID].contains(bundleID(for: app))
    }

    /// Resolve the kitty instance's remote-control socket. Prefers the hook's
    /// KITTY_LISTEN_ON; otherwise assumes `listen_on unix:${TMPDIR}/kitty`, which
    /// kitty suffixes with its PID. Only per-user temp-dir sockets are accepted,
    /// so hook input can't point us at an arbitrary socket.
    private static func kittySocket(_ k: KittyTarget) -> String? {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.resolvingSymlinksInPath().path
        var path: String
        if k.sock.hasPrefix("unix:") {
            path = String(k.sock.dropFirst("unix:".count))
        } else if !k.pid.isEmpty, k.pid.allSatisfy(\.isASCII), k.pid.allSatisfy(\.isNumber) {
            path = tmp + "/kitty-" + k.pid
        } else {
            return nil
        }
        path = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(tmp + "/"),
              let type = try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType,
              type == .typeSocket else { return nil }
        return "unix:" + path
    }

    /// Ask kitty to focus the session's window (and so its tab).
    private static func focusKitty(_ k: KittyTarget, root: String, agent: String, clientPID: Int? = nil) {
        kittyQueue.async {
            guard let target = resolveKitty(k, root: root, agent: agent, clientPID: clientPID),
                  let sock = kittyTarget(target) else { return }
            _ = execKitten(sock, ["focus-window", "--match", "id:" + target.window])
        }
    }

    /// Called only on kittyQueue. A shared Codex server's inherited environment
    /// identifies the server's terminal, which need not host this session.
    private static func resolveKitty(_ k: KittyTarget, root: String, agent: String, clientPID: Int? = nil) -> KittyTarget? {
        guard let sock = kittyTarget(k) else { return nil }
        guard agent == "codex" else { return k }
        guard let data = execKitten(sock, ["ls"]),
              let window = KittySessionResolver.codexWindow(in: data, root: root, clientPID: clientPID) else {
            NSLog("clawdex: no unique kitty Codex client for %@; leaving tabs unchanged", root)
            return nil
        }
        return KittyTarget(window: window, pid: k.pid, sock: sock)
    }

    /// Mirror the pill onto the session's kitty tab: the switchboard accent
    /// and a ● marker when ready for you, neutral near-black and a ○ while
    /// it's working. Only
    /// repaints on a readiness change, so busy sessions don't spawn a kitten
    /// per hook event.
    private func paintKittyTab(_ pill: Pill, source: String) {
        guard !pill.kitty.isEmpty, !pill.paintingKitty,
              pill.paintedLit != pill.lit || pill.paintedNeutral != pill.neutral else { return }
        pill.paintingKitty = true
        let reported = pill.kitty
        let root = pill.root
        let agent = pill.agent
        let clientPID = pill.observedProcessID
        let lit = pill.lit
        let neutral = pill.neutral
        let accent = Self.rgb(color(for: source))
        let colors: [String]
        if neutral {
            colors = ["active_bg=#101318", "inactive_bg=#101318",
                      "active_fg=" + Self.hex(accent), "inactive_fg=" + Self.hex(accent)]
        } else if pill.lit {
            colors = ["active_bg=" + Self.hex(accent),
                      "active_fg=#ffffff",
                      "inactive_bg=" + Self.hex(Self.mix(accent, (0, 0, 0), 0.5)),
                      "inactive_fg=#d0d0d0"]
        } else {
            // Keep the agent's warm/cool identity while a turn is busy, with
            // much darker backgrounds than its ready-for-you state.
            colors = ["active_bg=" + Self.hex(Self.mix(accent, (0, 0, 0), 0.80)),
                      "active_fg=#b0b0b0",
                      "inactive_bg=" + Self.hex(Self.mix(accent, (0, 0, 0), 0.90)),
                      "inactive_fg=#6a6a6a"]
        }
        Self.kittyQueue.async { [weak self] in
            let target = Self.resolveKitty(reported, root: root, agent: agent, clientPID: clientPID)
            var success = false
            if let target, let sock = Self.kittyTarget(target) {
                let colored = Self.execKitten(sock, ["set-tab-color", "--match", "window_id:" + target.window] + colors) != nil
                let titled = Self.markKittyTabOnQueue(target, marker: neutral ? Self.neutralMarker : (lit ? Self.readyMarker : Self.workingMarker))
                success = colored && titled
            }
            let painted = success
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                pill.paintingKitty = false
                guard self.pills[source] === pill else {
                    if let target { self.clearKittyIfUnclaimed(target) }
                    return
                }
                // Retain the actual target even after a partial paint so a
                // later close can restore any colors/title already applied.
                if let target {
                    let previous = pill.paintedKitty
                    pill.paintedKitty = target
                    if let previous, previous != target { self.clearKittyIfUnclaimed(previous) }
                }
                if painted { pill.paintedLit = lit; pill.paintedNeutral = neutral }
                // If another event arrived while these commands ran, catch up
                // once. A failure alone waits for the next event before retry.
                if pill.lit != lit || pill.neutral != neutral || pill.kitty != reported || pill.observedProcessID != clientPID {
                    pill.paintedLit = nil
                    self.paintKittyTab(pill, source: source)
                }
            }
        }
    }

    private static let readyMarker = "●"
    private static let workingMarker = "○"
    private static let neutralMarker = "◉"

    /// The tab's own title (e.g. the session file's `new_tab app`), captured the
    /// first time we mark it so the marker can be swapped or removed without
    /// clobbering the name. Keyed by "<kitty pid>:<window id>"; kittyQueue only.
    private static var kittyBaseTitles: [String: String] = [:]

    /// Prefix the session's kitty tab title with `marker`, or restore the plain
    /// title when `marker` is nil.
    private static func markKittyTabOnQueue(_ k: KittyTarget, marker: String?) -> Bool {
        guard let sock = kittyTarget(k) else { return false }
        let key = k.pid + ":" + k.window
        if kittyBaseTitles[key] == nil {
            guard let out = execKitten(sock, ["ls", "--match", "id:" + k.window]),
                  let title = KittySessionResolver.tabTitle(in: out, windowID: k.window) else { return false }
            kittyBaseTitles[key] = stripMarker(title)
        }
        guard let base = kittyBaseTitles[key] else { return false }
        let title = marker.map { $0 + " " + base } ?? base
        guard execKitten(sock, ["set-tab-title", "--match", "window_id:" + k.window, title]) != nil else { return false }
        if marker == nil { kittyBaseTitles[key] = nil }
        return true
    }

    private static func stripMarker(_ title: String) -> String {
        for m in [readyMarker, workingMarker, neutralMarker] where title.hasPrefix(m + " ") {
            return String(title.dropFirst(m.count + 1))
        }
        return title
    }

    private static func clearKittyTab(_ k: KittyTarget) {
        kittyQueue.async {
            guard let sock = kittyTarget(k) else { return }
            _ = execKitten(sock, ["set-tab-color", "--match", "window_id:" + k.window,
                                  "active_bg=NONE", "active_fg=NONE",
                                  "inactive_bg=NONE", "inactive_fg=NONE"])
            _ = markKittyTabOnQueue(k, marker: nil)
        }
    }

    private func clearKittyIfUnclaimed(_ target: KittyTarget) {
        guard !pills.values.contains(where: { pill in
            [pill.kitty, pill.paintedKitty].compactMap { $0 }.contains { $0.window == target.window && $0.pid == target.pid }
        }) else { return }
        Self.clearKittyTab(target)
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
            // A dead/unresponsive remote-control server must not stall every
            // other session's tab updates on the serial kitty queue.
            let timeout = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3, execute: timeout)
            defer { timeout.cancel() }
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

    func announceGitHub(_ message: String, onOpen: @escaping () -> Void) {
        guard shouldShowMessage(isFinal: true) else { return }
        show(source: "GitHub", label: "GitHub", root: "", threadID: "", app: "",
             kitty: KittyTarget(), text: message, isFinal: true, onOpen: onOpen)
    }

    /// The latest message sits centered above the dog.
    private func relayout() {
        guard let pet = pet else { return }
        pet.companionSpeechInset = order.compactMap { bubbles[$0]?.size.height }.max().map { $0 + gap } ?? 0
        pet.constrainCompanionToScreen()
        let pf = pet.frame
        var y = pf.maxY + gap
        for source in order {
            guard let b = bubbles[source] else { continue }
            var x = pf.midX - b.size.width / 2
            if let v = (pet.screen ?? NSScreen.main)?.visibleFrame {
                x = min(max(x, v.minX + 4), v.maxX - b.size.width - 4)
                y = min(y, v.maxY - b.size.height - 4)
            }
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
    ///   and Notification is "waiting for you" — all lit. StopFailure is a turn
    ///   that died on an API error instead of Stop; it's just as idle, so it
    ///   lights too. Working events dim it. A user interrupt (Esc) fires no
    ///   hook at all — the transcript marker covers it, see scanTranscripts.
    /// - Codex has no waiting-on-you event we can trust: its PermissionRequest
    ///   fires mid-turn while it keeps working, and it emits no Stop on a user
    ///   abort. Interrupt lights it directly; transcript scanning also covers
    ///   aborts from clients without that hook. Ambiguous events leave it as-is.
    static func litState(for event: String, agent: String) -> Bool? {
        if agent == "codex" {
            switch event {
            case "SessionStart", "Stop", "Interrupt":
                return true
            case "UserPromptSubmit", "PreToolUse", "PermissionRequest",
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
        case "SessionStart", "Stop", "StopFailure", "Notification":
            return true
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PreCompact":
            return false
        default:
            return nil   // SubagentStop, PostCompact, etc: leave the pill as-is
        }
    }

    /// Create-or-update a session's pill and (optionally) flip its lit state.
    private func updatePill(source: String, label: String, agent: String, root: String,
                            threadID: String, transcriptPath: String, app: String,
                            kitty: KittyTarget, lit: Bool?, compacting: Bool,
                            turnEnded: Bool = false, sessionID: String = "", sessionStarted: Bool = false,
                            event: String = "", turnID: String = "", sessionCleared: Bool = false, sessionResumed: Bool = false) {
        let update = { [weak self] in
            guard let self = self, let pet = self.pet else { return }
            let pill: Pill
            if let existing = self.pills[source] {
                pill = existing
            } else {
                pill = Pill()
                pill.window.onClick = { [weak self] in self?.tapPill(source: source) }
                pill.window.onClose = { [weak self] in
                    guard let self else { return }
                    if let id = self.pills[source]?.observedClientID { self.dismissedKittyClients.insert(id) }
                    self.removePillOnMain(source: source)
                }
                pill.badge.onClick = { [weak self] in self?.tapPill(source: source) }
                pet.addChildWindow(pill.window, ordered: .above)
                self.pills[source] = pill
                self.pillOrder.append(source)
            }
            if agent == "codex", ["Stop", "Interrupt"].contains(event), !turnID.isEmpty,
               !pill.activeTurnID.isEmpty, pill.activeTurnID != turnID { return }
            if pill.neutral, ["Stop", "StopFailure", "Interrupt"].contains(event) { return }
            pill.label = label
            pill.agent = agent
            if !sessionID.isEmpty { pill.sessionID = sessionID }
            if sessionStarted { pill.sessionEpoch += 1 }
            if !root.isEmpty, pill.root != root, pill.observedClientID == nil { pill.root = root; pill.paintedLit = nil }
            if !threadID.isEmpty { pill.threadID = threadID }
            if !app.isEmpty { pill.app = app }
            if !kitty.isEmpty, pill.observedClientID == nil, pill.kitty != kitty { pill.kitty = kitty; pill.paintedLit = nil }
            if sessionResumed {
                pill.neutral = false; pill.activeTurnID = ""; pill.transcript = TranscriptScan()
                pill.observedThreadID = threadID.isEmpty ? sessionID : threadID
            }
            // Start watching a transcript from its current end; after that the
            // poller reads it continuously, so lines written just before this
            // event (e.g. the tool_use a PreToolUse announces) aren't skipped.
            if !transcriptPath.isEmpty, transcriptPath != pill.transcriptPath || sessionResumed {
                pill.transcriptPath = transcriptPath
                let initial = Self.transcriptSnapshot(path: transcriptPath)
                pill.transcriptOffset = initial.offset
                pill.transcript = initial.state
                if agent == "codex", !initial.state.codexTurnID.isEmpty { pill.activeTurnID = initial.state.codexTurnID }
            }
            pill.lastSeen = Date()
            pill.compacting = compacting
            // Nothing is in flight once a turn ends; drop any tool_use whose
            // result line we missed so it can't suppress "?" next turn.
            if turnEnded { pill.transcript.openTools.removeAll() }
            if agent == "codex" {
                if lit == false, event != "SessionStart" {
                    if !turnID.isEmpty { pill.activeTurnID = turnID; pill.transcript.codexTurnID = turnID }
                    pill.transcript.codexReady = false
                    pill.transcript.sawAbort = false; pill.transcript.codexTransition = nil
                }
                if event == "SessionStart", let confirmed = pill.transcript.codexReady { pill.lit = confirmed }
                else if let lit { pill.lit = lit }
                if pill.lit, ["Stop", "Interrupt"].contains(event) { pill.transcript.codexReady = true }
            } else if let lit { pill.lit = lit }
            if sessionCleared {
                pill.neutral = true; pill.lit = true; pill.activeTurnID = ""
                if agent == "codex", !threadID.isEmpty { pill.observedThreadID = threadID }
                pill.transcript = TranscriptScan()
                pill.subagents.removeAll()
            } else if lit != nil, event != "SessionStart" {
                pill.neutral = false
            }
            pill.transcript.codexTransition = nil; pill.transcript.sawAbort = false
            pill.size = pill.window.setContent(label: label, lit: pill.lit,
                                               accent: self.color(for: source), neutral: pill.neutral)
            pill.badge.accent = self.color(for: source)
            self.paintKittyTab(pill, source: source)
            self.refreshBadge(pill)
            self.relayoutPills()
            pill.window.fadeIn()
        }
        if Thread.isMainThread { update() } else { DispatchQueue.main.async(execute: update) }
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
            return pill.observedClientID == nil && !pill.lit && now.timeIntervalSince(pill.lastSeen) > pillIdleTimeout
        }
        for source in stale { removePillOnMain(source: source) }
    }

    /// Remove a session's pill (from any thread).
    private func neutralizeCodexClient(source: String) {
        guard let pill = pills[source], pill.agent == "codex", !pill.neutral else { return }
        if !pill.sessionID.isEmpty {
            pill.retiredSessionIDs.append(pill.sessionID)
            pill.retiredSessionIDs = Array(pill.retiredSessionIDs.suffix(16))
        }
        updatePill(source: source, label: pill.label, agent: pill.agent, root: pill.root,
            threadID: "", transcriptPath: "", app: pill.app, kitty: pill.kitty,
            lit: true, compacting: false, sessionID: pill.sessionID,
            event: "SessionStart", sessionCleared: true)
        pill.transcriptPath = ""; pill.transcriptOffset = 0; pill.threadID = ""
    }

    private func removePill(source: String, sessionID: String, transcriptPath: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let pill = self.pills[source] else { return }
            if !sessionID.isEmpty, !pill.sessionID.isEmpty, sessionID != pill.sessionID { return }
            if !transcriptPath.isEmpty, !pill.transcriptPath.isEmpty, transcriptPath != pill.transcriptPath { return }
            if pill.observedClientID != nil {
                // A thread end can precede resume or replacement. Only a
                // verified empty prompt means clear; presence handles exits.
                if self.kittyDiscoveryTimer != nil { self.discoverKittySessions() }
                return
            }
            self.removePillOnMain(source: source)
        }
    }

    private func removePillOnMain(source: String) {
        guard let pill = pills.removeValue(forKey: source) else { return }
        pillOrder.removeAll { $0 == source }
        if let target = pill.paintedKitty { clearKittyIfUnclaimed(target) }
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

    /// The badge a pill should show, highest priority first: running subagents
    /// (the session is plainly busy), then "?" for a turn that has gone silent
    /// with nothing in flight, then "…" for background jobs still running.
    private func badgeContent(for pill: Pill, now: Date = Date()) -> SubagentBadgeView.Content? {
        if !pill.subagents.isEmpty { return .count(pill.subagents.count) }
        if isStalled(pill, now: now) { return .stalled }
        if !pill.transcript.backgroundJobs.isEmpty { return .background }
        return nil
    }

    /// Only Claude transcripts record tool_use/tool_result pairs we can match,
    /// so Codex pills never stall.
    private func isStalled(_ pill: Pill, now: Date) -> Bool {
        (pill.agent == "claude" || pill.agent.isEmpty) && !pill.lit
            && !pill.transcriptPath.isEmpty && pill.transcript.openTools.isEmpty
            && !pill.compacting && now.timeIntervalSince(pill.lastSeen) > stallTimeout
    }

    /// Show, update, or hide a pill's badge to match its state. Returns whether
    /// the badge appeared or disappeared (the pill stack's width may change).
    @discardableResult
    private func refreshBadge(_ pill: Pill) -> Bool {
        let content = badgeContent(for: pill)
        let toggled = (content == nil) != (pill.badgeContent == nil)
        guard content != pill.badgeContent else { return false }
        pill.badgeContent = content
        guard let content = content else {
            if pill.badgeAttached { pill.badge.hide() }
            return toggled
        }
        pill.badge.content = content
        if !pill.badgeAttached, let pet = pet {
            pet.addChildWindow(pill.badge, ordered: .above)
            pill.badgeAttached = true
        }
        pill.badge.show(bright: content == .stalled)
        return toggled
    }

    private func scanTranscripts() {
        let now = Date()
        var layoutChanged = false
        for source in pillOrder {
            guard let pill = pills[source], !pill.transcriptPath.isEmpty else { continue }
            let update = Self.readAppended(path: pill.transcriptPath, offset: pill.transcriptOffset)
            pill.transcriptOffset = update.offset
            if let chunk = update.chunk {
                pill.lastSeen = now
                pill.transcript.sawAbort = false
                Self.scan(chunk, into: &pill.transcript)
            }
            pill.transcript.backgroundJobs = pill.transcript.backgroundJobs
                .filter { now.timeIntervalSince($0.value) <= backgroundJobTimeout }

            let readiness = pill.agent == "codex" ? pill.transcript.codexTransition ?? (pill.transcript.sawAbort ? true : nil)
                                                 : (pill.transcript.sawAbort ? true : nil)
            if readiness != nil, !pill.transcript.codexTurnID.isEmpty { pill.activeTurnID = pill.transcript.codexTurnID }
            pill.transcript.sawAbort = false; pill.transcript.codexTransition = nil
            if let readiness, !(pill.neutral && readiness), readiness != pill.lit || pill.neutral {
                pill.neutral = false
                pill.lit = readiness
                pill.size = pill.window.setContent(label: pill.label, lit: readiness,
                                                   accent: self.color(for: source), neutral: pill.neutral)
                paintKittyTab(pill, source: source)
                pill.window.fadeIn()
                layoutChanged = true
            }
            if refreshBadge(pill) { layoutChanged = true }
        }
        if layoutChanged { relayoutPills() }
    }

    /// Codex writes a `<turn_aborted>` user message; Claude writes a user text
    /// block "[Request interrupted by user]" (or "… for tool use]"). Claude's is
    /// matched with its raw JSON quotes so a tool result that merely quotes the
    /// marker (escaped as \"text\":\"…) can't light a pill mid-turn. The id
    /// patterns below rely on the same raw-quote rule.
    private static let toolUseRegex = try! NSRegularExpression(
        pattern: #""type":"tool_use","id":"([A-Za-z0-9_]{1,64})""#)
    private static let toolResultRegex = try! NSRegularExpression(
        pattern: #""tool_use_id":"([A-Za-z0-9_]{1,64})""#)
    private static let backgroundLaunchRegex = try! NSRegularExpression(
        pattern: #""backgroundTaskId":"([A-Za-z0-9_]{1,64})""#)
    /// Completion notices arrive as queued `<task-notification>` messages.
    private static let queuedNotice = #""type":"queue-operation","operation":"enqueue""#
    private static let taskDoneRegex = try! NSRegularExpression(
        pattern: #"<task-id>([A-Za-z0-9_]{1,64})</task-id>"#)
    /// Bounds on untrusted transcript input: a partial line longer than this is
    /// dropped rather than buffered, and the id sets stop growing past a cap.
    private static let maxPartialLine = 4 << 20
    private static let maxTrackedIDs = 256

    /// Fold appended transcript text into `state`, one complete line at a time.
    static func scan(_ chunk: String, into state: inout TranscriptScan) {
        state.codexTransition = nil
        var lines = (state.partialLine + chunk).components(separatedBy: "\n")
        let partial = lines.removeLast()
        state.partialLine = partial.utf8.count > maxPartialLine ? "" : partial
        for line in lines where !line.isEmpty {
            guard line.utf8.count <= maxPartialLine else { continue }
            var aborted = false
            if let data = line.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if object["type"] as? String == "event_msg", let payload = object["payload"] as? [String: Any] {
                    let type = payload["type"] as? String ?? ""
                    let turn = payload["turn_id"] as? String ?? ""
                    if type == "task_started" {
                        state.codexHasLifecycle = true; state.codexTurnID = turn
                        state.codexReady = false; state.codexTransition = false; state.sawAbort = false
                    } else if ["task_complete", "turn_aborted"].contains(type),
                              turn.isEmpty || state.codexTurnID.isEmpty || state.codexTurnID == turn {
                        state.codexHasLifecycle = true; state.codexReady = true; state.codexTransition = true
                        aborted = type == "turn_aborted"
                    }
                }
                if object["type"] as? String == "response_item", let payload = object["payload"] as? [String: Any],
                   payload["type"] as? String == "message", payload["role"] as? String == "user",
                   let content = payload["content"] as? [[String: Any]] {
                    aborted = aborted || content.contains { block in
                        guard block["type"] as? String == "input_text", let text = block["text"] as? String else { return false }
                        return text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<turn_aborted>") && text.contains("</turn_aborted>")
                    }
                }
                if object["type"] as? String == "user", let message = object["message"] as? [String: Any],
                   let content = message["content"] as? [[String: Any]] {
                    aborted = aborted || content.contains { $0["type"] as? String == "text" && ($0["text"] as? String)?.hasPrefix("[Request interrupted by user") == true }
                }
            }
            if aborted {
                state.sawAbort = true
                state.openTools.removeAll()
                state.codexReady = true; state.codexTransition = true
            }
            for id in matches(toolUseRegex, in: line) where state.openTools.count < maxTrackedIDs {
                state.openTools.insert(id)
            }
            for id in matches(toolResultRegex, in: line) { state.openTools.remove(id) }
            for id in matches(backgroundLaunchRegex, in: line)
            where state.backgroundJobs.count < maxTrackedIDs {
                state.backgroundJobs[id] = Date()
            }
            if line.contains(queuedNotice) {
                for id in matches(taskDoneRegex, in: line) { state.backgroundJobs[id] = nil }
            }
        }
    }

    private static func matches(_ regex: NSRegularExpression, in line: String) -> [String] {
        guard line.contains("\"") else { return [] }
        let ns = line as NSString
        return regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
    }

    private static func transcriptSnapshot(path: String) -> (offset: UInt64, state: TranscriptScan) {
        var state = TranscriptScan()
        guard let fh = FileHandle(forReadingAtPath: path) else { return (0, state) }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let start = size > 262144 ? size - 262144 : 0
        try? fh.seek(toOffset: start)
        guard let data = try? fh.read(upToCount: 262144), var text = String(data: data, encoding: .utf8) else { return (size, state) }
        if start > 0 { text = text.firstIndex(of: "\n").map { String(text[text.index(after: $0)...]) } ?? "" }
        scan(text, into: &state)
        return (size, state)
    }

    /// Bytes appended to a transcript since `offset`, and the new offset. A
    /// file that shrank (rewritten) restarts from its new end.
    private static func readAppended(path: String, offset: UInt64) -> (chunk: String?, offset: UInt64) {
        guard let fh = FileHandle(forReadingAtPath: path) else { return (nil, offset) }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? offset
        guard size > offset else { return (nil, size) }
        try? fh.seek(toOffset: offset)
        guard let data = try? fh.readToEnd(), !data.isEmpty else { return (nil, size) }
        return (String(decoding: data, as: UTF8.self), offset + UInt64(data.count))
    }

    /// Claude Code stays on the left; Codex stays on the right.
    private func relayoutPills() {
        guard let pet = pet else { return }
        let badgeSpace = pills.values.contains { $0.badgeContent != nil } ? badgeGap + SubagentBadgeWindow.size : 0
        pet.companionSideInset = pillOrder.isEmpty ? 0 : CompanionLayout.sideInset(pet.frame) + badgeSpace
        let codexCount = pillOrder.filter { Self.agent(ofKey: $0) == "codex" }.count
        let rows = max(codexCount, pillOrder.count - codexCount)
        pet.companionSessionInset = max(0, 10 + CGFloat(rows) * (PillWindow.height + CompanionLayout.rowGap) - CompanionLayout.rowGap - pet.frame.height)
        pet.constrainCompanionToScreen()
        var sideRows: [Bool: Int] = [:]
        for source in pillOrder {
            guard let pill = pills[source] else { continue }
            let left = pill.agent != "codex"
            let row = sideRows[left, default: 0]; sideRows[left] = row + 1
            let frame = CompanionLayout.sessionFrame(index: row, pet: pet.frame, onLeft: left)
            pill.size = pill.window.setContent(label: pill.label, lit: pill.lit,
                accent: color(for: source), fixedWidth: frame.width, neutral: pill.neutral)
            pill.window.setFrameOrigin(frame.origin)
            // Subagent badge on the pill's outward side, away from the pet.
            let bx = left ? frame.minX - badgeGap - SubagentBadgeWindow.size
                                            : frame.maxX + badgeGap
            pill.badge.setFrameOrigin(NSPoint(x: bx, y: frame.minY))
        }
        onPillLayout?()
    }

    // MARK: - Labeling

    /// Claude and Codex use bare project names; side and color identify them.
    private static func displayLabel(repo: String, agent: String) -> String {
        guard !repo.isEmpty else { return "" }
        switch agent {
        case "", "claude", "codex": return repo
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

    private func rememberCodexTranscript(_ path: String, threadID: String) {
        guard !path.isEmpty, !threadID.isEmpty else { return }
        if knownCodexTranscripts.count >= 256, knownCodexTranscripts[threadID] == nil { knownCodexTranscripts.removeAll() }
        knownCodexTranscripts[threadID] = path
    }

    /// Codex internal agents can inherit the parent's hook session_id without
    /// supplying agent_id. Their own rollout metadata identifies them reliably.
    static func isCodexSubagentTranscript(path: String) -> Bool {
        guard let payload = codexSessionMetadata(path: path), let source = payload["source"] as? [String: Any] else { return false }
        return source["subagent"] != nil
    }

    static func isCodexBackgroundFork(path: String, foregroundThreadID: String) -> Bool {
        guard !foregroundThreadID.isEmpty, let payload = codexSessionMetadata(path: path),
              let parent = payload["forked_from_id"] as? String, UUID(uuidString: parent) != nil,
              let thread = payload["id"] as? String, UUID(uuidString: thread) != nil else { return false }
        return thread.lowercased() != foregroundThreadID.lowercased()
    }

    private static func codexSessionMetadata(path: String) -> [String: Any]? {
        guard !path.isEmpty, let file = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: 65_536),
              let end = data.firstIndex(of: 0x0a),
              let object = try? JSONSerialization.jsonObject(with: Data(data[..<end])) as? [String: Any],
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any] else { return nil }
        return payload
    }

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
