import AppKit
import XCTest
@testable import clawdexd

final class MouseTrailTests: XCTestCase {
    func testTrailExpiresAndDoesNotConnectPointerJumps() {
        var trail = MouseTrail()
        trail.update(.zero, now: 1)
        trail.update(NSPoint(x: 20, y: 0), now: 1.1)
        XCTAssertEqual(trail.samples.count, 2)
        trail.update(NSPoint(x: 800, y: 0), now: 1.11)
        XCTAssertEqual(trail.samples.count, 1)
        trail.update(NSPoint(x: 801, y: 0), now: 2)
        XCTAssertEqual(trail.samples.count, 1)
        trail.clear()
        XCTAssertTrue(trail.samples.isEmpty)
    }

    func testTrailIsBoundedDuringRapidMovement() {
        var trail = MouseTrail()
        for index in 0..<200 { trail.update(NSPoint(x: index, y: 0), now: Double(index) * 0.0001) }
        XCTAssertEqual(trail.samples.count, 64)
    }

    func testWindowCoordinatesSupportDisplaysAboveAndBelowPrimary() {
        XCTAssertEqual(MouseTrailController.appKitRect(CGRect(x: 100, y: 200, width: 300, height: 400), desktopTop: 1000),
                       NSRect(x: 100, y: 400, width: 300, height: 400))
        XCTAssertEqual(MouseTrailController.appKitRect(CGRect(x: -500, y: -800, width: 300, height: 400), desktopTop: 1000).minY, 1400)
    }
}
