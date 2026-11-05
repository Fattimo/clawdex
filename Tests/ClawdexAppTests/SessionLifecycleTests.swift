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

    func testInternalCodexHooksCannotRelightOrReplaceBusyParent() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("clawdex-worker-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        try #"{"type":"session_meta","payload":{"source":{"subagent":{"other":"guardian"}}}}"#
            .appending("\n").write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(SpeechController.isCodexSubagentTranscript(path: file.path))
        let pet = PetWindow()
        let speech = SpeechController(pet: pet, config: ClawdexConfig(messageVisibility: .none))
        speech.handle(event: "UserPromptSubmit", narration: nil, transcriptPath: nil,
            source: "demo", root: "/tmp/demo", agent: "codex", sessionID: "parent", turnID: "parent-turn")
        settle(); let pill = try XCTUnwrap(activePills(pet).first)
        // Rollout-backed workers may inherit the parent hook's session ID;
        // ephemeral internal clients may have a separate ID and no rollout.
        for (transcript, session) in [(file.path, "parent"), ("", "internal")] {
            for event in ["SessionStart", "UserPromptSubmit", "Stop", "SessionEnd"] {
                speech.handle(event: event, narration: nil, transcriptPath: transcript,
                    source: "demo", root: "/tmp/demo", agent: "codex", sessionID: session, turnID: "worker-turn")
                settle()
                XCTAssertEqual(activePills(pet).count, 1)
                XCTAssertEqual(pill.alphaValue, 0.55, accuracy: 0.02, "\(session) \(event)")
            }
        }
        speech.handle(event: "Stop", narration: nil, transcriptPath: nil,
            source: "demo", root: "/tmp/demo", agent: "codex", sessionID: "parent", turnID: "parent-turn")
        settle(); XCTAssertEqual(pill.alphaValue, 1, accuracy: 0.02)
    }

    func testCodexSubagentMetadataRequiresStructuredSessionSource() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("clawdex-meta-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        for line in [
            #"{"type":"session_meta","payload":{"source":"cli"}}"#,
            #"{"type":"response_item","payload":{"source":{"subagent":"quoted"}}}"#,
            #"{"type":"session_meta","payload":{"source": "subagent"}}"#,
            "invalid JSON"
        ] {
            try (line + "\n").write(to: file, atomically: true, encoding: .utf8)
            XCTAssertFalse(SpeechController.isCodexSubagentTranscript(path: file.path))
        }
        XCTAssertFalse(SpeechController.isCodexSubagentTranscript(path: ""))
    }

    func testClearKeepsNeutralDotUntilNewActivity() throws {
        for agent in ["claude", "codex"] {
            let pet = PetWindow()
            let speech = SpeechController(pet: pet, config: ClawdexConfig(messageVisibility: .none))
            func send(_ event: String, source: String = "") {
                speech.handle(event: event, narration: nil, transcriptPath: nil,
                    source: "demo", root: "/tmp/demo", agent: agent,
                    sessionID: "session", sessionSource: source)
            }
            send("Stop"); settle()
            let pill = try XCTUnwrap(activePills(pet).first)
            let view = try XCTUnwrap(pill.contentView as? PillView)
            XCTAssertTrue(view.lit)
            send("SessionStart", source: "clear"); settle()
            XCTAssertTrue(view.neutral); XCTAssertFalse(view.lit)
            XCTAssertEqual(pill.alphaValue, 0.85, accuracy: 0.02)
            send("Stop"); settle()
            XCTAssertTrue(view.neutral)
            send("UserPromptSubmit"); settle()
            XCTAssertFalse(view.neutral); XCTAssertFalse(view.lit)
            send("Stop"); settle()
            XCTAssertFalse(view.neutral); XCTAssertTrue(view.lit)
        }
    }

    func testCodexThreadEndBeforeReplacementStartNeutralizesLiveClient() throws {
        let pet = PetWindow()
        let speech = SpeechController(pet: pet, config: ClawdexConfig(messageVisibility: .none))
        let client = KittySessionResolver.Client(window: "11", processID: 101, agent: "codex", root: "/tmp/demo")
        speech.reconcileKittySessions([client], socket: socket)
        func send(_ event: String, session: String = "old") {
            speech.handle(event: event, narration: nil, transcriptPath: nil,
                source: "demo", root: client.root, agent: "codex", sessionID: session)
        }
        send("SessionStart"); send("Stop"); settle()
        let pill = try XCTUnwrap(activePills(pet).first)
        let view = try XCTUnwrap(pill.contentView as? PillView)
        XCTAssertTrue(view.lit)
        send("SessionEnd"); settle()
        speech.reconcileKittySessions([client], socket: socket); settle()
        XCTAssertEqual(activePills(pet).count, 1)
        XCTAssertTrue(view.neutral); XCTAssertFalse(view.lit)
        send("Stop"); settle(); XCTAssertTrue(view.neutral)
        send("UserPromptSubmit", session: "new"); settle()
        XCTAssertFalse(view.neutral); XCTAssertFalse(view.lit)
        send("Stop", session: "new"); settle(); XCTAssertTrue(view.lit)
        send("SessionEnd", session: "old"); settle()
        XCTAssertTrue(view.lit); XCTAssertFalse(view.neutral)
        speech.reconcileKittySessions([], socket: socket); settle()
        XCTAssertTrue(activePills(pet).isEmpty)
    }

    func testObservedEmptyCodexScreenNeutralizesWithoutAnyClearHook() throws {
        let pet = PetWindow()
        let speech = SpeechController(pet: pet, config: ClawdexConfig(messageVisibility: .none))
        var client = KittySessionResolver.Client(window: "11", processID: 101, agent: "codex", root: "/tmp/demo")
        speech.reconcileKittySessions([client], socket: socket)
        func send(_ event: String, session: String) {
            speech.handle(event: event, narration: nil, transcriptPath: nil,
                source: "demo", root: client.root, agent: "codex", sessionID: session)
        }
        send("SessionStart", session: "old"); send("Stop", session: "old"); settle()
        let view = try XCTUnwrap(activePills(pet).first?.contentView as? PillView)
        XCTAssertTrue(view.lit)
        client.emptyPromptObservedAt = Date()
        speech.reconcileKittySessions([client], socket: socket); settle()
        XCTAssertTrue(view.neutral); XCTAssertFalse(view.lit)
        // Late background work from the old thread cannot undo a visible clear.
        send("PreToolUse", session: "old"); send("Stop", session: "old"); settle()
        XCTAssertTrue(view.neutral)
        send("UserPromptSubmit", session: "new"); settle()
        XCTAssertFalse(view.neutral); XCTAssertFalse(view.lit)
        // A screen sampled before that prompt must not neutralize the new turn.
        client.emptyPromptObservedAt = .distantPast
        speech.reconcileKittySessions([client], socket: socket); settle()
        XCTAssertFalse(view.neutral); XCTAssertFalse(view.lit)
        send("Stop", session: "new"); settle(); XCTAssertTrue(view.lit)
    }

    func testBackgroundForkCannotOverrideResumedMainCompletion() throws {
        let main = "11111111-1111-4111-8111-111111111111"
        let fork = "22222222-2222-4222-8222-222222222222"
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        func transcript(_ thread: String, parent: String?) throws -> URL {
            let file = temp.appendingPathComponent("rollout-\(thread).jsonl")
            var payload: [String: Any] = ["id": thread, "source": "vscode"]
            if let parent { payload["forked_from_id"] = parent }
            let header = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": payload])
            var data = header
            data.append(Data("\n{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"done\"}}\n".utf8))
            try data.write(to: file)
            return file
        }
        let mainFile = try transcript(main, parent: nil)
        let forkFile = try transcript(fork, parent: main)
        let cleared = "33333333-3333-4333-8333-333333333333"
        let clearedFile = try transcript(cleared, parent: nil)
        XCTAssertTrue(SpeechController.isCodexBackgroundFork(path: forkFile.path, foregroundThreadID: main))
        XCTAssertFalse(SpeechController.isCodexBackgroundFork(path: forkFile.path, foregroundThreadID: fork))
        for hookFirst in [false, true] {
            let pet = PetWindow()
            let speech = SpeechController(pet: pet, config: ClawdexConfig(messageVisibility: .none))
            var client = KittySessionResolver.Client(window: "11", processID: 101, agent: "codex", root: "/tmp/demo")
            client.resumeThreadID = main; client.resumeTranscriptPath = mainFile.path
            func send(_ event: String, thread: String, path: URL) {
                speech.handle(event: event, narration: nil, transcriptPath: path.path,
                    source: "demo", root: client.root, agent: "codex", sessionID: thread, turnID: "main-turn")
            }
            if hookFirst { send("PreToolUse", thread: fork, path: forkFile) }
            speech.reconcileKittySessions([client], socket: socket); settle()
            let view = try XCTUnwrap(activePills(pet).first?.contentView as? PillView)
            XCTAssertTrue(view.lit, "Restore the completed primary transcript on first client binding")
            send("UserPromptSubmit", thread: main, path: mainFile); settle()
            XCTAssertFalse(view.lit)
            send("PreToolUse", thread: fork, path: forkFile)
            send("Stop", thread: main, path: mainFile); settle()
            XCTAssertTrue(view.lit)
            send("PreToolUse", thread: fork, path: forkFile); settle()
            XCTAssertTrue(view.lit, "A working background fork must not dim the finished primary")
            speech.handle(event: "SessionStart", narration: nil, transcriptPath: clearedFile.path,
                source: "demo", root: client.root, agent: "codex", sessionID: cleared, sessionSource: "clear")
            send("UserPromptSubmit", thread: cleared, path: clearedFile)
            speech.reconcileKittySessions([client], socket: socket)
            send("PreToolUse", thread: fork, path: forkFile)
            send("Stop", thread: cleared, path: clearedFile); settle()
            XCTAssertTrue(view.lit, "A new clear-session binding survives the old resume command in process metadata")
        }
        // A fork explicitly resumed in its own CLI is a legitimate primary.
        let pet = PetWindow()
        let speech = SpeechController(pet: pet, config: ClawdexConfig(messageVisibility: .none))
        var client = KittySessionResolver.Client(window: "12", processID: 102, agent: "codex", root: "/tmp/demo")
        client.resumeThreadID = fork; client.resumeTranscriptPath = forkFile.path
        speech.reconcileKittySessions([client], socket: socket)
        speech.handle(event: "UserPromptSubmit", narration: nil, transcriptPath: forkFile.path,
            source: "demo", root: client.root, agent: "codex", sessionID: fork, turnID: "fork-turn")
        settle()
        let view = try XCTUnwrap(activePills(pet).first?.contentView as? PillView)
        XCTAssertFalse(view.lit)
        speech.handle(event: "Stop", narration: nil, transcriptPath: forkFile.path,
            source: "demo", root: client.root, agent: "codex", sessionID: fork, turnID: "fork-turn")
        settle(); XCTAssertTrue(view.lit)
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
