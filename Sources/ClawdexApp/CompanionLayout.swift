import AppKit

/// Shared geometry for the dog's two session columns and GitHub floor.
enum CompanionLayout {
    static let artInset: CGFloat = 8
    static let columnGap: CGFloat = 8
    static let rowGap: CGFloat = 7
    static let floorGap: CGFloat = 4
    static let floorHeight: CGFloat = 38

    static func dogWidth(_ pet: NSRect) -> CGFloat { max(48, pet.width - artInset * 2) }
    static func sideInset(_ pet: NSRect) -> CGFloat { dogWidth(pet) + columnGap - artInset }
    static func floorFrame(_ pet: NSRect) -> NSRect {
        let width = dogWidth(pet)
        return NSRect(x: pet.midX - (width * 3 + columnGap * 2) / 2,
                      y: pet.minY - floorGap - floorHeight,
                      width: width * 3 + columnGap * 2, height: floorHeight)
    }
    static func sessionFrame(index: Int, pet: NSRect, onLeft: Bool? = nil) -> NSRect {
        let width = dogWidth(pet)
        let left = onLeft ?? index.isMultiple(of: 2)
        let row = onLeft == nil ? index / 2 : index
        let x = left ? pet.minX + artInset - columnGap - width
                                      : pet.maxX - artInset + columnGap
        return NSRect(x: x, y: pet.minY + 10 + CGFloat(row) * (PillWindow.height + rowGap),
                      width: width, height: PillWindow.height)
    }
    static func constrainedPet(_ pet: NSRect, screen: NSRect, sides: CGFloat, bottom: CGFloat, top: CGFloat = 0) -> NSRect {
        var result = pet
        let minX = screen.minX + 4 + sides
        let maxX = screen.maxX - 4 - sides - pet.width
        result.origin.x = maxX >= minX ? min(max(pet.minX, minX), maxX) : screen.midX - pet.width / 2
        result.origin.y = min(max(pet.minY, screen.minY + bottom + 4), screen.maxY - pet.height - top - 4)
        return result
    }
}
