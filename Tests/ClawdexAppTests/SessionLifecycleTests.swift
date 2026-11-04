import AppKit
import XCTest
@testable import clawdexd

final class SessionLifecycleTests: XCTestCase {
    private let socket = "unix:/tmp/clawdex-nonexistent-kitty-test"
    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.28)) }
    private func activePills(_ pet: PetWindow) -> [PillWindow] {
        (pet.childWindows ?? []).compactMap { $0 as? PillWindow }.filter { $0.isVisible && $0.alphaValue > 0.01 }
    }

    func testClientRegistersBeforeHooksAndPresenceDoesNotResetBusyState() throws {
        let pet = PetWindow()
        let speech = SpeechController(pet: pet, config: ClawdexConfig(messageVisibility: .none))
        let client = KittySessionResolver.Client(window: "11", processID: 101, agent: "codex", root: "/tmp/demo")
        speech.reconcileKittySessions([client], socket: socket); settle()
        let pill = try XCTUnwrap(activePills(pet).first)
        XCTAssertEqual(activePills(pet).count, 1)
        XCTAssertEqual(pill.alphaValue, 1, accuracy: 0.02)
        speech.handle(event: "UserPromptSubmit", narration: nil, transcriptPath: nil,
            source: "demo", root: client.root, agent: "codex", sessionID: "new")
        settle(); speech.reconcileKittySessions([client], socket: socket); settle()
        XCTAssertEqual(pill.alphaValue, 0.55, accuracy: 0.02)
        speech.reconcileKittySessions([], socket: socket); settle()
        XCTAssertTrue(activePills(pet).isEmpty)
    }

    func testSwitchingAgentsAndLateEndCannotRemoveReplacement() throws {
        let pet = PetWindow()
        let speech = SpeechController(pet: pet, config: ClawdexConfig(messageVisibility: .none))
        let cc = KittySessionResolver.Client(window: "11", processID: 101, agent: "claude", root: "/tmp/demo")
        speech.reconcileKittySessions([cc], socket: socket); settle()
        let cdx = KittySessionResolver.Client(window: "11", processID: 202, agent: "codex", root: cc.root)
        speech.reconcileKittySessions([cdx], socket: socket); settle()
        XCTAssertEqual(activePills(pet).count, 1)
        XCTAssertEqual(activePills(pet).first?.contentView?.toolTip, "demo")
        let resumed = KittySessionResolver.Client(window: "11", processID: 303, agent: "codex", root: cc.root)
        speech.handle(event: "SessionStart", narration: nil, transcriptPath: nil,
            source: "demo", root: cc.root, agent: "codex", sessionID: "old")
        speech.reconcileKittySessions([resumed], socket: socket)
        // The replacement has no hook identity yet; an old close must not win.
        speech.handle(event: "SessionEnd", narration: nil, transcriptPath: nil,
            source: "demo", root: cc.root, agent: "codex", sessionID: "old")
        settle(); XCTAssertEqual(activePills(pet).count, 1)
        speech.handle(event: "SessionStart", narration: nil, transcriptPath: nil,
            source: "demo", root: cc.root, agent: "codex", sessionID: "new", sessionSource: "resume")
        speech.handle(event: "SessionEnd", narration: nil, transcriptPath: nil,
            source: "demo", root: cc.root, agent: "codex", sessionID: "old")
        settle(); XCTAssertEqual(activePills(pet).count, 1)
    }

    func testDismissedClientStaysHiddenUntilItsProcessIsReplaced() throws {
        let pet = PetWindow()
        let speech = SpeechController(pet: pet, config: ClawdexConfig(messageVisibility: .none))
        var client = KittySessionResolver.Client(window: "11", processID: 101, agent: "codex", root: "/tmp/demo")
        speech.reconcileKittySessions([client], socket: socket); settle()
        try XCTUnwrap(activePills(pet).first).onClose?()
        speech.reconcileKittySessions([client], socket: socket); settle()
        XCTAssertTrue(activePills(pet).isEmpty)
        client.processID = 102
        speech.reconcileKittySessions([client], socket: socket); settle()
        XCTAssertEqual(activePills(pet).count, 1)
    }

    func testSameBasenameProjectsHaveIndependentSessionEntries() {
        let pet = PetWindow()
        let speech = SpeechController(pet: pet, config: ClawdexConfig(messageVisibility: .none))
        speech.reconcileKittySessions([
            .init(window: "11", processID: 101, agent: "codex", root: "/tmp/one/demo"),
            .init(window: "12", processID: 102, agent: "codex", root: "/tmp/two/demo")
        ], socket: socket)
        settle(); XCTAssertEqual(activePills(pet).count, 2)
    }

    func testPromptBeforeClientReconciliationKeepsReplacementBusy() throws {
        let pet = PetWindow()
        let speech = SpeechController(pet: pet, config: ClawdexConfig(messageVisibility: .none))
        var client = KittySessionResolver.Client(window: "11", processID: 101, agent: "codex", root: "/tmp/demo")
        speech.reconcileKittySessions([client], socket: socket)
        speech.handle(event: "SessionStart", narration: nil, transcriptPath: nil,
            source: "demo", root: client.root, agent: "codex", sessionID: "old")
        speech.reconcileKittySessions([client], socket: socket)
        speech.handle(event: "SessionStart", narration: nil, transcriptPath: nil,
            source: "demo", root: client.root, agent: "codex", sessionID: "new", sessionSource: "resume")
        speech.handle(event: "UserPromptSubmit", narration: nil, transcriptPath: nil,
            source: "demo", root: client.root, agent: "codex", sessionID: "new")
        client.processID = 202
        speech.reconcileKittySessions([client], socket: socket); settle()
        XCTAssertEqual(activePills(pet).count, 1)
        XCTAssertEqual(try XCTUnwrap(activePills(pet).first).alphaValue, 0.55, accuracy: 0.02)
    }

    func testAgentAccentsStayInTheirWarmOrCoolFamilies() throws {
        for index in 0..<8 {
            let warm = try XCTUnwrap(SpeechController.sessionAccent(agent: "claude", index: index).usingColorSpace(.deviceRGB))
            let cool = try XCTUnwrap(SpeechController.sessionAccent(agent: "codex", index: index).usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(warm.redComponent, warm.blueComponent)
            XCTAssertGreaterThan(cool.blueComponent, cool.redComponent)
        }
    }

    func testOriginalProjectAndInternalWorktreeShareOneClientEntry() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("clawdex-worktrees-\(UUID())")
        defer { try? FileManager.default.removeItem(at: temp) }
        let original = temp.appendingPathComponent("projects/app")
        let worktree = temp.appendingPathComponent("worktrees/abc/app")
        let git = original.appendingPathComponent(".git")
        let workGit = git.appendingPathComponent("worktrees/abc")
        try FileManager.default.createDirectory(at: workGit, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(workGit.path)\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try "../..\n".write(to: workGit.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        XCTAssertEqual(KittySessionResolver.repositoryIdentity(original.path), KittySessionResolver.repositoryIdentity(worktree.path))
        for hookFirst in [false, true] {
            let pet = PetWindow()
            let speech = SpeechController(pet: pet, config: ClawdexConfig(messageVisibility: .none))
            let client = KittySessionResolver.Client(window: "11", processID: 101, agent: "codex", root: original.path)
            if !hookFirst { speech.reconcileKittySessions([client], socket: socket) }
            speech.handle(event: "UserPromptSubmit", narration: nil, transcriptPath: nil,
                source: "app", root: worktree.path, agent: "codex", sessionID: "same-session", turnID: "turn-new")
            speech.reconcileKittySessions([client], socket: socket)
            speech.handle(event: "PreToolUse", narration: nil, transcriptPath: nil,
                source: "app", root: original.path, agent: "codex", sessionID: "same-session", turnID: "turn-new")
            settle(); XCTAssertEqual(activePills(pet).count, 1)
            XCTAssertEqual(try XCTUnwrap(activePills(pet).first).alphaValue, 0.55, accuracy: 0.02)
        }
    }

    func testStructuredTurnStateRejectsQuotedAbortAndOldCompletion() {
        var state = SpeechController.TranscriptScan()
        SpeechController.scan("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"new\"}}\n", into: &state)
        let quoted = #"{"type":"response_item","payload":{"type":"function_call_output","output":"<turn_aborted> example </turn_aborted>"}}"#
        SpeechController.scan(quoted + "\n", into: &state)
        XCTAssertFalse(state.sawAbort); XCTAssertEqual(state.codexReady, false)
        SpeechController.scan("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"old\"}}\n", into: &state)
        XCTAssertEqual(state.codexReady, false)
        SpeechController.scan("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"new\"}}\n", into: &state)
        XCTAssertEqual(state.codexReady, true)
    }

    func testCurrentStopLightsAndNextTurnDimsWithoutAUserPromptHook() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("clawdex-turns-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        func event(_ name: String, _ turn: String) -> String {
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"\(name)\",\"turn_id\":\"\(turn)\"}}\n"
        }
        try event("task_started", "first").write(to: file, atomically: true, encoding: .utf8)
        let pet = PetWindow()
        let speech = SpeechController(pet: pet, config: ClawdexConfig(messageVisibility: .none))
        speech.handle(event: "Stop", narration: nil, transcriptPath: file.path,
            source: "demo", root: "/tmp/demo", agent: "codex", turnID: "first")
        settle(); let pill = try XCTUnwrap(activePills(pet).first)
        XCTAssertEqual(pill.alphaValue, 1, accuracy: 0.02)
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: Data(event("task_complete", "first").utf8))
        RunLoop.main.run(until: Date().addingTimeInterval(0.75))
        XCTAssertEqual(pill.alphaValue, 1, accuracy: 0.02)
        try handle.write(contentsOf: Data(event("task_started", "second").utf8))
        RunLoop.main.run(until: Date().addingTimeInterval(0.75))
        speech.handle(event: "Stop", narration: nil, transcriptPath: file.path,
            source: "demo", root: "/tmp/demo", agent: "codex", turnID: "first")
        settle(); XCTAssertEqual(pill.alphaValue, 0.55, accuracy: 0.02)
    }
}
