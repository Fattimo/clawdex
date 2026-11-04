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

    func testClientDiscoveryIncludesIdleResumeClientsAndExcludesServers() throws {
        let data = try listing([["id": 7, "foreground_processes": [
            ["pid": 101, "cmdline": ["/opt/bin/codex", "resume", "thread-id"], "cwd": "/tmp/project"],
            ["pid": 102, "cmdline": ["codex", "app-server"], "cwd": "/tmp/server"],
            ["pid": 103, "cmdline": ["codex", "exec", "hello"], "cwd": "/tmp/headless"],
            ["pid": 104, "cmdline": ["node", "mcp-server"], "cwd": "/tmp/mcp"]
        ]]])
        let clients = try XCTUnwrap(KittySessionResolver.clients(in: data))
        XCTAssertEqual(clients.count, 1)
        XCTAssertEqual(clients.first?.processID, 101)
        XCTAssertEqual(clients.first?.window, "7")
        XCTAssertNil(KittySessionResolver.clients(in: Data("bad JSON".utf8)))
    }

    func testObservedProcessIdentityDisambiguatesSharedRepoClients() throws {
        let data = try listing([
            ["id": 6, "foreground_processes": [["pid": 101, "cmdline": ["codex"], "cwd": "/tmp/project"]]],
            ["id": 7, "foreground_processes": [["pid": 102, "cmdline": ["codex", "resume"], "cwd": "/tmp/project"]]]
        ])
        XCTAssertNil(KittySessionResolver.codexWindow(in: data, root: "/tmp/project"))
        XCTAssertEqual(KittySessionResolver.codexWindow(in: data, root: "/tmp/project", clientPID: 102), "7")
        XCTAssertNil(KittySessionResolver.codexWindow(in: data, root: "/tmp/project", clientPID: 999))
    }
}
