import XCTest

@testable import clawdexd

final class ClawdexConfigTests: XCTestCase {
    func testConfigRoundTripsMessageVisibilitySwitchboardAndScale() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawdex-config-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: path) }

        var config = ClawdexConfig()
        config.messageVisibility = .finalOnly
        config.showSwitchboard = false
        config.petScale = 1.1
        try config.save(to: path)

        let loaded = try ClawdexConfig.load(from: path)
        XCTAssertEqual(loaded.messageVisibility, .finalOnly)
        XCTAssertFalse(loaded.showSwitchboard)
        XCTAssertEqual(loaded.petScale, 1.1, accuracy: 0.001)
    }
}
