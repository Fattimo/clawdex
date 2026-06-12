import XCTest

@testable import clawdexd

final class StateMachineTests: XCTestCase {
    func testPostToolUseKeepsCurrentWorkingRowUntilNextEvent() {
        var rows: [AnimationRow] = []
        let machine = StateMachine { rows.append($0) }

        machine.ingest(#"{"event":"PreToolUse","agent":"codex","row":7,"mode":"sticky","ttl":0}"#)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        machine.ingest(#"{"event":"PostToolUse","agent":"codex","row":-1,"mode":"release","ttl":0}"#)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        XCTAssertEqual(rows, [.running])
    }

    func testPostToolUseStillReleasesForClaudeSessions() {
        var rows: [AnimationRow] = []
        let machine = StateMachine { rows.append($0) }

        machine.ingest(#"{"event":"PreToolUse","agent":"claude","row":7,"mode":"sticky","ttl":0}"#)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        machine.ingest(#"{"event":"PostToolUse","agent":"claude","row":-1,"mode":"release","ttl":0}"#)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        XCTAssertEqual(rows, [.running, .idle])
    }

    func testStopClearsCodexWorkingRowAfterFinalWave() {
        var rows: [AnimationRow] = []
        let machine = StateMachine { rows.append($0) }

        machine.ingest(#"{"event":"PreToolUse","agent":"codex","row":7,"mode":"sticky","ttl":0}"#)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        machine.ingest(#"{"event":"PostToolUse","agent":"codex","row":-1,"mode":"release","ttl":0}"#)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        machine.ingest(#"{"event":"Stop","agent":"codex","row":3,"mode":"transient","ttl":1}"#)
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))

        XCTAssertEqual(rows, [.running, .waving, .idle])
    }
}
