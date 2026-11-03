import XCTest

@testable import clawdexd

final class KittySessionResolverTests: XCTestCase {
    private func window(_ id: Int, cwd: String, program: String = "codex") -> [String: Any] {
        ["id": id, "foreground_processes": [["cmdline": [program], "cwd": cwd]]]
    }

    private func listing(_ windows: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [["tabs": windows.map {
            ["title": "tab-\($0["id"]!)", "windows": [$0]]
        }]])
    }

    func testSharedServerWindowDoesNotOverrideActualClient() throws {
        let data = try listing([
            window(6, cwd: "/Users/test/Projects/clawdex"),
            window(1, cwd: "/Users/test/Projects/app", program: "claude"),
            window(7, cwd: "/Users/test/Projects/app")
        ])
        XCTAssertEqual(KittySessionResolver.codexWindow(in: data, root: "/Users/test/Projects/app"), "7")
        XCTAssertEqual(KittySessionResolver.tabTitle(in: data, windowID: "7"), "tab-7")
    }

    func testAmbiguousClientsDoNotChooseAnArbitraryTab() throws {
        let data = try listing([window(6, cwd: "/tmp/app"), window(7, cwd: "/tmp/app")])
        XCTAssertNil(KittySessionResolver.codexWindow(in: data, root: "/tmp/app"))
    }

    func testRepoPrefixDoesNotMatchAnotherRepo() throws {
        let data = try listing([window(7, cwd: "/tmp/appcopy")])
        XCTAssertNil(KittySessionResolver.codexWindow(in: data, root: "/tmp/app"))
    }

    func testNestedClientDirectoryAndAbsoluteExecutable() throws {
        let data = try listing([window(7, cwd: "/tmp/app/backend", program: "/usr/local/bin/codex")])
        XCTAssertEqual(KittySessionResolver.codexWindow(in: data, root: "/tmp/app"), "7")
    }

    func testMultipleOSWindowsAndQuotedPaths() throws {
        let root = "/tmp/project's \"repo\""
        let data = try JSONSerialization.data(withJSONObject: [
            ["tabs": [["title": "other", "windows": [window(6, cwd: "/tmp/other")]]]],
            ["tabs": [["title": "projects", "windows": [window(7, cwd: root)]]]]
        ])
        XCTAssertEqual(KittySessionResolver.codexWindow(in: data, root: root), "7")
        XCTAssertEqual(KittySessionResolver.tabTitle(in: data, windowID: "7"), "projects")
    }

    func testMissingOrMalformedInputDoesNotChooseATab() throws {
        for data in [Data("invalid".utf8), try listing([])] {
            XCTAssertNil(KittySessionResolver.codexWindow(in: data, root: "/tmp/app"))
            XCTAssertNil(KittySessionResolver.tabTitle(in: data, windowID: "7"))
        }
        let data = try listing([window(7, cwd: "/tmp/app")])
        XCTAssertNil(KittySessionResolver.codexWindow(in: data, root: "/"))
        XCTAssertNil(KittySessionResolver.codexWindow(in: data, root: "relative"))
        XCTAssertNil(KittySessionResolver.tabTitle(in: data, windowID: "all"))
    }

    func testSharedServerProcessIsNotAClient() throws {
        let data = try listing([["id": 6, "foreground_processes": [
            ["cmdline": ["codex", "app-server"], "cwd": "/tmp/app"]
        ]]])
        XCTAssertNil(KittySessionResolver.codexWindow(in: data, root: "/tmp/app"))
    }
}
