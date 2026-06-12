import AppKit
import Foundation

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from Dock & Cmd-Tab. LSUIElement set programmatically since we ship
        // a single binary without an Info.plist app bundle.
        NSApp.setActivationPolicy(.accessory)

        window = PetWindow()

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

        speech = SpeechController(pet: window)

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
        // Hello on first launch — routed through the state machine so it
        // properly returns to idle after the wave cycle. Direct setRow calls
        // would bypass the machine and leave us stuck.
        machine.ingest(#"{"event":"startup","tool":"","row":3,"mode":"transient","ttl":0,"ts":0}"#)
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
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
            speech.handle(event: s.event ?? "", narration: s.text,
                          transcriptPath: s.transcript, source: s.source,
                          root: s.root, agent: s.agent)
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
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
