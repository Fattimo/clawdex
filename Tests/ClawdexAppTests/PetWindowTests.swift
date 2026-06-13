import XCTest

@testable import clawdexd

final class PetWindowTests: XCTestCase {
    func testPetScaleChangesFrameSize() {
        let pet = PetWindow(scale: 0.75)
        let initialWidth = pet.frame.width

        pet.setScale(1.0)

        XCTAssertGreaterThan(pet.frame.width, initialWidth)
    }
}
