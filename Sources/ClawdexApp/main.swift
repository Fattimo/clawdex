import AppKit
import Foundation
import ClawdexGitHub

// clawdex daemon entry point. Brings up:
//   - an NSApplication (no menu bar — we set LSUIElement-equivalent at runtime).
//   - a floating PetWindow.
//   - a Unix socket listener at ~/.clawdex/sock.
//   - a state machine that translates incoming events to (row, frame) ticks.

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: PetWindow!
    private var server: SocketServer!
    private var machine: StateMachine!
    private var speech: SpeechController!
    private var githubBoard: GitHubBoardController!
    private var github: GitHubService?
    private var githubConfig: GitHubConfig?
    private var githubSnapshot = GitHubSnapshot()
    private var wakeObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var githubSuspended = false
    private var terminationSignals: [DispatchSourceSignal] = []
    private var githubGeneration = UUID()
    private var config = ClawdexConfig()
    private let settingsPopover = SettingsPopover()
    private var mouseTrail: MouseTrailController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from Dock & Cmd-Tab. LSUIElement set programmatically since we ship
        // a single binary without an Info.plist app bundle.
        NSApp.setActivationPolicy(.accessory)
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }; source.resume(); terminationSignals.append(source)
        }

        if let loaded = try? ClawdexConfig.load() {
            config = loaded
        }

        window = PetWindow(scale: config.petScale)
        mouseTrail = MouseTrailController()
        mouseTrail.setEnabled(config.showMouseTrail)

        // Load the user's saved pet (from a prior `select`) if it still
        // resolves, else the alphabetically-first discovered pet. ClawdexCLI
        // can send a "select" event over the socket to switch at runtime.
        if let pet = PetLibrary.preferred() {
            window.loadPet(pet)
            NSLog("clawdex: loaded pet '\(pet.0.displayName)' from \(pet.1.deletingLastPathComponent().path)")
        } else {
            NSLog("clawdex: no pets found in ~/.codex/pets or ~/.clawdex/pets — install one with `npx petdex install <name>` or use the hatch-pet skill.")
        }

        machine = StateMachine { [weak self] row in
            DispatchQueue.main.async { self?.window.setRow(row) }
        }

        speech = SpeechController(pet: window, config: config)
        githubBoard = GitHubBoardController(pet: window)
        speech.onPillLayout = { [weak self] in self?.githubBoard.anchor() }
        githubBoard.onNotice = { [weak self] message, onOpen in self?.speech.announceGitHub(message, onOpen: onOpen) }
        reloadGitHub()
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.suspendForSleep()
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.githubSuspended = false
            self.reloadGitHub()
            self.speech.startKittyObservation()
            self.mouseTrail.setEnabled(self.config.showMouseTrail)
        }
        window.onSettings = { [weak self] view, rect in
            guard let self else { return }
            self.settingsPopover.show(from: view, rect: rect, config: self.config)
        }
        window.onScaleChanged = { [weak self] scale in
            guard let self else { return }
            self.config.petScale = scale
            self.saveConfig()
        }
        settingsPopover.onChange = { [weak self] config in
            guard let self else { return }
            self.config = config
            self.saveConfig()
            self.speech.updateConfig(config)
            self.mouseTrail.setEnabled(config.showMouseTrail)
            self.githubBoard.update(config: self.githubConfig, snapshot: self.githubSnapshot, visible: config.showGitHubSwitchboard)
        }

        let sockPath = ProcessInfo.processInfo.environment["CLAWDEX_SOCK"]
            ?? (NSHomeDirectory() + "/.clawdex/sock")
        server = SocketServer(path: sockPath) { [weak self] line in
            self?.handleSocketLine(line)
        }
        do {
            try server.start()
            NSLog("clawdex: listening on \(sockPath)")
        } catch {
            NSLog("clawdex: failed to bind socket \(sockPath): \(error)")
        }

        window.wake()
        speech.startKittyObservation()
        // Hello on first launch — routed through the state machine so it
        // properly returns to idle after the wave cycle. Direct setRow calls
        // would bypass the machine and leave us stuck.
        machine.ingest(#"{"event":"startup","tool":"","row":3,"mode":"transient","ttl":0,"ts":0}"#)
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        github?.stop()
        speech?.stopKittyObservation()
        mouseTrail?.stop()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
    }

    /// CLI commands are sent as JSON over the same socket as hook events. We
    /// dispatch known control verbs here, and forward everything else to the
    /// state machine.
    private func handleSocketLine(_ line: String) {
        if let data = line.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let verb = obj["control"] as? String {
            DispatchQueue.main.async { [weak self] in
                switch verb {
                case "wake": self?.window.wake()
                case "tuck": self?.window.tuck()
                case "github-reload": self?.reloadGitHub()
                case "github-refresh": self?.refreshGitHub()
                case "select":
                    if let id = obj["id"] as? String {
                        let pets = PetLibrary.discover()
                        if let match = pets.first(where: { $0.0.id == id }) {
                            self?.window.loadPet(match)
                            PetLibrary.savePreference(id: id)
                        }
                    }
                default: break
                }
            }
            return
        }

        // Speech: surface Claude's prose (from the transcript) or the hook's
        // action narration. Independent of the row state machine.
        if let data = line.data(using: .utf8),
           let s = try? JSONDecoder().decode(SpeechLine.self, from: data) {
            // Internal Codex workers must not wave/idle the foreground pet.
            if s.agent == "codex", SpeechController.isCodexSubagentTranscript(path: s.transcript ?? "") { return }
            speech.handle(event: s.event ?? "", narration: s.text,
                          transcriptPath: s.transcript, source: s.source,
                          root: s.root, agent: s.agent, app: s.app,
                          subagent: s.subagent,
                          kitty: SpeechController.KittyTarget(
                              window: s.kitty_window ?? "", pid: s.kitty_pid ?? "",
                              sock: s.kitty_sock ?? ""),
                          sessionID: s.session_id ?? "", sessionSource: s.session_source ?? "", turnID: s.turn_id ?? "")
        }

        machine.ingest(line)
    }

    /// Lenient view of a socket line for the speech path (all fields optional).
    private struct SpeechLine: Decodable {
        let event: String?
        let text: String?
        let transcript: String?
        let source: String?
        let root: String?
        let agent: String?
        let app: String?   // launching app's bundle id (from the hook)
        let kitty_window: String?   // KITTY_WINDOW_ID, when launched in kitty
        let kitty_pid: String?
        let kitty_sock: String?     // KITTY_LISTEN_ON, if kitty set it
        let subagent: String?       // Claude Code agent_id, inside a subagent
        let session_id: String?
        let session_source: String?
        let turn_id: String?
    }

    private func saveConfig() {
        do {
            try config.save()
        } catch {
            NSLog("clawdex: failed to save config: \(error)")
        }
    }

    private func reloadGitHub() {
        githubGeneration = UUID(); let generation = githubGeneration
        github?.stop(); github = nil
        githubConfig = try? GitHubStore.loadConfig(); githubSnapshot = GitHubStore.loadSnapshot()
        githubBoard.update(config: githubConfig, snapshot: githubSnapshot, visible: config.showGitHubSwitchboard)
        guard !githubSuspended, let config = githubConfig, config.enabled else { return }
        let service = GitHubService(config: config) { [weak self] state in
            guard let self, self.githubGeneration == generation else { return }; self.githubSnapshot = state
            self.githubBoard.update(config: self.githubConfig, snapshot: state, visible: self.config.showGitHubSwitchboard)
        }
        github = service; service.start()
    }
    private func refreshGitHub() {
        guard !githubSuspended else { return }
        if !githubSnapshot.receiverReady { reloadGitHub() }
        else { github?.refresh(reconnect: githubSnapshot.tunnelURL == nil) }
    }

    private func suspendForSleep() {
        mouseTrail.stop()
        githubSuspended = true; githubGeneration = UUID()
        github?.stop(); github = nil
        githubSnapshot.receiverReady = false; githubSnapshot.tunnelURL = nil
        githubSnapshot.tunnelError = "Paused while this Mac sleeps"
        githubBoard.update(config: githubConfig, snapshot: githubSnapshot, visible: config.showGitHubSwitchboard)
        speech.stopKittyObservation()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
