import XCTest

@testable import clawdexd

final class SpeechControllerTests: XCTestCase {
    func testMessageVisibilityNoneSuppressesBubbles() throws {
        let pet = PetWindow()
        let speech = SpeechController(
            pet: pet,
            config: ClawdexConfig(messageVisibility: .none, showSwitchboard: false)
        )

        speech.handle(event: "Stop", narration: "done",
                      transcriptPath: nil, source: "app", root: "/tmp/app", agent: "codex")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(pet.childWindows?.count ?? 0, 0)
    }

    func testFinalOnlySuppressesNonFinalMessagesButShowsStop() throws {
        let pet = PetWindow()
        let speech = SpeechController(
            pet: pet,
            config: ClawdexConfig(messageVisibility: .finalOnly, showSwitchboard: false)
        )

        speech.handle(event: "PreToolUse", narration: "working",
                      transcriptPath: nil, source: "app", root: "/tmp/app", agent: "codex")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(pet.childWindows?.count ?? 0, 0)

        speech.handle(event: "Stop", narration: "done",
                      transcriptPath: nil, source: "app", root: "/tmp/app", agent: "codex")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(pet.childWindows?.count ?? 0, 1)
    }

    func testFinalOnlyDoesNotConsumeIntermediateProseBeforeStop() throws {
        let pet = PetWindow()
        let speech = SpeechController(
            pet: pet,
            config: ClawdexConfig(messageVisibility: .finalOnly, showSwitchboard: false)
        )
        let transcript = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawdex-final-only-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: transcript) }
        let line = #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"finished"}]}}"#
        try line.write(to: transcript, atomically: true, encoding: .utf8)

        speech.handle(event: "PreToolUse", narration: nil,
                      transcriptPath: transcript.path, source: "app",
                      root: "/tmp/app", agent: "codex")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(pet.childWindows?.count ?? 0, 0)

        speech.handle(event: "Stop", narration: nil,
                      transcriptPath: transcript.path, source: "app",
                      root: "/tmp/app", agent: "codex")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(pet.childWindows?.count ?? 0, 1)
    }

    func testHiddenSwitchboardSuppressesPills() throws {
        let pet = PetWindow()
        let speech = SpeechController(
            pet: pet,
            config: ClawdexConfig(messageVisibility: .none, showSwitchboard: false)
        )

        speech.handle(event: "UserPromptSubmit", narration: "thinking...",
                      transcriptPath: nil, source: "app", root: "/tmp/app", agent: "codex")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(pet.childWindows?.count ?? 0, 0)
    }

    func testPermissionRequestKeepsPillDimUntilFinalResponse() throws {
        let pet = PetWindow()
        let speech = SpeechController(pet: pet)

        speech.handle(event: "PermissionRequest", narration: "waiting for you",
                      transcriptPath: nil, source: "app", root: "/tmp/app", agent: "codex")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        let pill = try XCTUnwrap(pet.childWindows?.first as? PillWindow)
        XCTAssertEqual(pill.alphaValue, 0.55, accuracy: 0.02)
    }

    func testSessionStartKeepsPillDimUntilFinalResponse() throws {
        let pet = PetWindow()
        let speech = SpeechController(pet: pet)

        speech.handle(event: "SessionStart", narration: nil,
                      transcriptPath: nil, source: "app", root: "/tmp/app", agent: "codex")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        let pill = try XCTUnwrap(pet.childWindows?.first as? PillWindow)
        XCTAssertEqual(pill.alphaValue, 0.55, accuracy: 0.02)
    }

    func testUserPromptSubmitDimsAndStopRelightsPill() throws {
        let pet = PetWindow()
        let speech = SpeechController(pet: pet)

        speech.handle(event: "UserPromptSubmit", narration: "thinking...",
                      transcriptPath: nil, source: "app", root: "/tmp/app", agent: "codex")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        let pill = try XCTUnwrap(pet.childWindows?.first as? PillWindow)
        XCTAssertEqual(pill.alphaValue, 0.55, accuracy: 0.02)

        speech.handle(event: "Stop", narration: nil,
                      transcriptPath: nil, source: "app", root: "/tmp/app", agent: "codex")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(pill.alphaValue, 1.0, accuracy: 0.02)
    }

    func testTrailingPostToolUseAfterStopDoesNotRedimPill() throws {
        let pet = PetWindow()
        let speech = SpeechController(pet: pet)

        speech.handle(event: "PreToolUse", narration: "working",
                      transcriptPath: nil, source: "app", root: "/tmp/app", agent: "codex")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        let pill = try XCTUnwrap(pet.childWindows?.first as? PillWindow)
        XCTAssertEqual(pill.alphaValue, 0.55, accuracy: 0.02)

        speech.handle(event: "Stop", narration: nil,
                      transcriptPath: nil, source: "app", root: "/tmp/app", agent: "codex")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(pill.alphaValue, 1.0, accuracy: 0.02)

        speech.handle(event: "PostToolUse", narration: nil,
                      transcriptPath: nil, source: "app", root: "/tmp/app", agent: "codex")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(pill.alphaValue, 1.0, accuracy: 0.02)
    }

    func testTurnAbortMarkerRelightsPillWithoutStopHook() throws {
        let pet = PetWindow()
        let speech = SpeechController(pet: pet)
        let transcript = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawdex-abort-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: transcript) }

        try #"{"type":"response_item","payload":{"type":"message","role":"user"}}"#
            .write(to: transcript, atomically: true, encoding: .utf8)

        speech.handle(event: "UserPromptSubmit", narration: "thinking...",
                      transcriptPath: transcript.path, source: "app",
                      root: "/tmp/app", agent: "codex")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        let pill = try XCTUnwrap(pet.childWindows?.first as? PillWindow)
        XCTAssertEqual(pill.alphaValue, 0.55, accuracy: 0.02)

        let abort = #"""
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<turn_aborted>\nThe user interrupted the previous turn on purpose.\n</turn_aborted>"}]}}
"""#
        let handle = try FileHandle(forWritingTo: transcript)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(abort.utf8))

        RunLoop.main.run(until: Date().addingTimeInterval(0.8))

        XCTAssertEqual(pill.alphaValue, 1.0, accuracy: 0.02)
    }
}
