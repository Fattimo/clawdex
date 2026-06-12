import XCTest

@testable import clawdexd

final class PillWindowTests: XCTestCase {
    func testTrailingCloseHitDoesNotOpenPill() {
        let view = PillView(frame: NSRect(x: 0, y: 0, width: 100, height: PillWindow.height))
        var opened = false
        var closed = false
        view.onClick = { opened = true }
        view.onClose = { closed = true }

        view.mouseEntered(with: mouseEvent(at: NSPoint(x: 95, y: PillWindow.height / 2)))
        view.mouseDown(with: mouseEvent(at: NSPoint(x: 95, y: PillWindow.height / 2)))

        XCTAssertFalse(opened)
        XCTAssertTrue(closed)
    }

    func testBodyClickStillOpensPill() {
        let view = PillView(frame: NSRect(x: 0, y: 0, width: 100, height: PillWindow.height))
        var opened = false
        view.onClick = { opened = true }

        view.mouseDown(with: mouseEvent(at: NSPoint(x: 30, y: PillWindow.height / 2)))

        XCTAssertTrue(opened)
    }

    func testTrailingHitWithoutHoverStillOpensPill() {
        let view = PillView(frame: NSRect(x: 0, y: 0, width: 100, height: PillWindow.height))
        var opened = false
        var closed = false
        view.onClick = { opened = true }
        view.onClose = { closed = true }

        view.mouseDown(with: mouseEvent(at: NSPoint(x: 95, y: PillWindow.height / 2)))

        XCTAssertTrue(opened)
        XCTAssertFalse(closed)
    }

    private func mouseEvent(at point: NSPoint) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else {
            fatalError("Could not create mouse event")
        }
        return event
    }
}
