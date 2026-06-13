import XCTest

@testable import clawdexd

final class SpeechControllerTests: XCTestCase {
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
}
