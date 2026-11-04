import AppKit
import ClawdexGitHub
import XCTest
@testable import clawdexd

final class GitHubBoardTests: XCTestCase {
    private func items() -> [GitHubScorebugWindow.Item] {
        (0..<5).map { .init(id: "chain-\($0)", title: "Chain \($0)", status: "Ready", number: $0 + 10, unresolvedReviewCount: 0) }
    }

    func testTickerCyclesFourChainsAndClickOpensTheDisplayedEntry() throws {
        _ = NSApplication.shared
        let window = GitHubScorebugWindow()
        defer { window.close() }
        window.setItems(items()); window.orderFrontRegardless()
        XCTAssertEqual(window.items.count, 4)
        XCTAssertEqual(window.frame.height, 38)
        XCTAssertTrue(window.button.attributedTitle.string.hasPrefix("#10 · Chain 0\nUpdated"))
        XCTAssertEqual(window.button.item?.reviewText, "0 unresolved")
        var selected: String?
        window.onSelect = { selected = $0 }
        window.advance(); window.advance()
        window.button.performClick(nil)
        XCTAssertEqual(selected, "chain-2")
        window.setItems(Array(items().reversed()))
        XCTAssertEqual(window.currentItem?.id, "chain-2")
        // Refresh the displayed status without replacing the current chain.
        var update = items(); update[2].status = "Checks running"
        window.setItems(update)
        XCTAssertEqual(window.currentItem?.id, "chain-2")
        XCTAssertTrue(window.button.toolTip?.contains("Checks running") == true)
        window.advance(); window.advance()
        XCTAssertEqual(window.currentItem?.id, "chain-0")
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.bounds.contains(window.button.frame))
        window.setItems([])
        XCTAssertNil(window.currentItem)
        XCTAssertFalse(window.button.isEnabled)
    }

    func testHoverPausesRotationAndHiddenTickerStopsItsTimer() throws {
        let window = GitHubScorebugWindow(rotationInterval: 0.1)
        defer { window.close() }
        window.setItems(items()); window.orderFrontRegardless()
        let view = try XCTUnwrap(window.contentView)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0))
        view.mouseEntered(with: event)
        window.advance()
        RunLoop.main.run(until: Date().addingTimeInterval(0.16))
        XCTAssertEqual(window.currentItem?.id, "chain-0")
        view.mouseExited(with: event)
        RunLoop.main.run(until: Date().addingTimeInterval(0.14))
        XCTAssertEqual(window.currentItem?.id, "chain-1")
        window.orderOut(nil)
        let hidden = window.currentItem?.id
        RunLoop.main.run(until: Date().addingTimeInterval(0.16))
        XCTAssertEqual(window.currentItem?.id, hidden)
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.14))
        XCTAssertNotEqual(window.currentItem?.id, hidden)
    }

    func testStackPresentationUsesPRTitlePositionReviewCountAndTruthfulTone() throws {
        func stack(draft: Bool = false, pending: Bool = false, failed: Bool = false, mergedFailure: Bool = false) throws -> GitHubStack {
            let prs: [[String: Any]] = (1...3).map { number -> [String: Any] in
                let checking = pending && number == 3
                let failure = (failed && number == 2) || (mergedFailure && number == 1)
                let conclusion: Any = failure ? "FAILURE" : (checking ? NSNull() : "SUCCESS" as Any)
                let checks: [[String: Any]] = [["status": checking ? "IN_PROGRESS" : "COMPLETED", "conclusion": conclusion]]
                return ["number": number, "title": "Actual PR title \(number)", "headRefName": "feature-\(number)",
                 "baseRefName": "main", "headRefOid": "sha", "state": number == 1 ? "MERGED" : "OPEN",
                 "isDraft": draft, "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN",
                 "statusCheckRollup": checks,
                 "createdAt": "2026-10-30T12:00:00Z", "updatedAt": "2026-11-03T12:00:00Z", "unresolvedReviewCount": 3]
            }
            return try JSONDecoder().decode(GitHubStack.self, from: JSONSerialization.data(withJSONObject: [
                "definition": ["id": "stack", "name": "Old branch slug", "repository": "owner/repo", "numbers": [1,2,3]],
                "pullRequests": prs
            ]))
        }
        let item = try XCTUnwrap(GitHubBoardController.item(for: stack(), issue: nil))
        XCTAssertEqual(item.number, 2)
        XCTAssertEqual(item.title, "Actual PR title 2")
        XCTAssertEqual(item.stackPosition, "2/3")
        XCTAssertEqual(item.reviewText, "3 unresolved")
        XCTAssertEqual(item.tone, .ready)
        XCTAssertTrue(item.metadata(now: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-03T14:00:00Z"))).contains("Updated 2h ago"))
        XCTAssertTrue(item.metadata().contains("opened"))
        XCTAssertEqual(try GitHubBoardController.item(for: stack(pending: true), issue: nil)?.tone, .pending)
        XCTAssertEqual(try GitHubBoardController.item(for: stack(pending: true, failed: true), issue: nil)?.tone, .failed)
        XCTAssertEqual(try GitHubBoardController.item(for: stack(draft: true, failed: true), issue: nil)?.tone, .failed)
        XCTAssertEqual(try GitHubBoardController.item(for: stack(mergedFailure: true), issue: nil)?.tone, .ready)
        XCTAssertEqual(try GitHubBoardController.item(for: stack(draft: true), issue: nil)?.tone, .neutral)
        XCTAssertEqual(try GitHubBoardController.item(for: stack(), issue: "Offline")?.tone, .neutral)
    }

    func testCardFacesStayOpaqueAcrossStatusesAndAppearances() throws {
        let window = GitHubScorebugWindow()
        defer { window.close() }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            var baseFace: NSColor?
            for tone in [GitHubScorebugTone.ready, .pending, .failed, .neutral] {
                window.setItems([.init(id: "card", title: "A deliberately very long PR title to exercise truncation", status: "Ready",
                    number: 60005, stackPosition: "2/3", unresolvedReviewCount: 12, tone: tone)])
                XCTAssertEqual(window.alphaValue, 1)
                XCTAssertEqual(tone.fill(dark: appearance == .darkAqua).alphaComponent, 1)
                let view = try XCTUnwrap(window.contentView); view.layoutSubtreeIfNeeded()
                let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: rep)
                let face = try XCTUnwrap(rep.colorAt(x: 2, y: rep.pixelsHigh / 2))
                XCTAssertGreaterThan(face.alphaComponent, 0.99)
                if let baseFace { XCTAssertEqual(face, baseFace) } else { baseFace = face }
                let x = Int(13 * CGFloat(rep.pixelsWide) / view.bounds.width)
                let dot = try XCTUnwrap(rep.colorAt(x: x, y: rep.pixelsHigh / 2))
                XCTAssertNotEqual(dot, face)
                XCTAssertTrue(window.button.toolTip?.contains("12 unresolved") == true)
            }
        }
        var unknown = items()[0]; unknown.unresolvedReviewCount = nil
        XCTAssertEqual(unknown.reviewText, "— unresolved")
    }

    func testFrequentSnapshotUpdatesDoNotStarveRotation() {
        let window = GitHubScorebugWindow(rotationInterval: 0.15)
        defer { window.close() }
        window.setItems(items()); window.orderFrontRegardless()
        for _ in 0..<3 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.06))
            window.setItems(items())
        }
        XCTAssertEqual(window.currentItem?.id, "chain-1")
    }

    func testClickDestinationSkipsMergedAndClosedParentsInDefinitionOrder() throws {
        func pr(_ number: Int, state: String) throws -> GitHubPR {
            let object: [String: Any] = ["number": number, "title": "PR \(number)", "headRefName": "feature-\(number)",
                "baseRefName": "main", "headRefOid": "sha", "state": state, "isDraft": false]
            return try JSONDecoder().decode(GitHubPR.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let prs = try [pr(4, state: "OPEN"), pr(2, state: "CLOSED"), pr(1, state: "MERGED"), pr(3, state: "OPEN")]
        let url = GitHubBoardNavigation.mergeURL(repository: "owner/repo", orderedNumbers: [1,2,3,4], pullRequests: prs)
        XCTAssertEqual(url?.absoluteString, "https://github.com/owner/repo/pull/3#partial-pull-merging")
        XCTAssertNil(GitHubBoardNavigation.mergeURL(repository: "owner/repo", orderedNumbers: [1,2], pullRequests: prs))
        XCTAssertNil(GitHubBoardNavigation.mergeURL(repository: "other.example/repo/extra", orderedNumbers: [3], pullRequests: prs))
    }

    func testCompanionGeometryBalancesSwitchesAndKeepsTheFloorReachable() {
        let screen = NSRect(x: -1440, y: 30, width: 1440, height: 870)
        for scale in [0.5, 0.75, 1.5] {
            let original = NSRect(x: screen.maxX - 20, y: screen.minY, width: 192 * scale, height: 192 * scale)
            let pet = CompanionLayout.constrainedPet(original, screen: screen,
                sides: CompanionLayout.sideInset(original), bottom: CompanionLayout.floorGap + CompanionLayout.floorHeight)
            let floor = CompanionLayout.floorFrame(pet)
            XCTAssertTrue(screen.contains(floor))
            XCTAssertEqual(pet.minY - floor.maxY, 4)
            XCTAssertEqual(floor.midX, pet.midX)
            let switches = (0..<4).map { CompanionLayout.sessionFrame(index: $0, pet: pet) }
            XCTAssertEqual(switches[0].minX, switches[2].minX)
            XCTAssertEqual(switches[1].minX, switches[3].minX)
            XCTAssertEqual(switches[0].minY, switches[1].minY)
            XCTAssertGreaterThan(switches[2].minY, switches[0].maxY)
            for frame in switches {
                XCTAssertTrue(screen.contains(frame))
                XCTAssertEqual(frame.width, CompanionLayout.dogWidth(pet))
                XCTAssertFalse(frame.intersects(pet.insetBy(dx: 8, dy: 0)))
            }
            XCTAssertEqual(switches[0].minX, floor.minX)
            XCTAssertEqual(switches[1].maxX, floor.maxX)
        }
    }
}
