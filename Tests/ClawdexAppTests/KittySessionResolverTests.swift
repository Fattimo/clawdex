import XCTest

@testable import clawdexd

final class KittySessionResolverTests: XCTestCase {
    private let emptyCodexScreen = """
      >_ OpenAI Codex (v0.166.0)
         /tmp/demo

            ⣀⣤⣤⣤⣀⣀
            ⠙⠛⠿⠿⠿⠿⠛⠉

    › Ask Codex to do anything

      GPT-6.1-Sol medium · /tmp/demo
      ← for agents · ? for shortcuts
    """

    func testRecognizesActualEmptyCodexWelcomeShapeAfterClearWithoutHooks() {
        XCTAssertTrue(KittySessionResolver.isEmptyCodexPrompt(Data(emptyCodexScreen.utf8), root: "/tmp/demo"))
        XCTAssertFalse(KittySessionResolver.isEmptyCodexPrompt(Data(emptyCodexScreen.utf8), root: "/tmp/other"))
        for screen in [
            "• Tool output quotes:\n" + emptyCodexScreen,
            emptyCodexScreen.replacingOccurrences(of: "⣀⣤⣤⣤⣀⣀", with: "• Working (10s • esc to interrupt)"),
            emptyCodexScreen.replacingOccurrences(of: "⣀⣤⣤⣤⣀⣀", with: "• Finished your task"),
            emptyCodexScreen.replacingOccurrences(of: "› Ask Codex to do anything", with: "› /clear"),
            emptyCodexScreen + "\n› Previous user prompt",
            String(repeating: " ", count: 262_145) + emptyCodexScreen
        ] {
            XCTAssertFalse(KittySessionResolver.isEmptyCodexPrompt(Data(screen.utf8), root: "/tmp/demo"))
        }
    }

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

    func testExplicitResumeThreadIsValidatedAndLocated() throws {
        let thread = "11111111-1111-4111-8111-111111111111"
        let data = try listing([["id": 8, "foreground_processes": [
            ["pid": 101, "cmdline": ["codex", "resume", thread], "cwd": "/tmp/demo"]
        ]]])
        XCTAssertEqual(KittySessionResolver.clients(in: data)?.first?.resumeThreadID, thread)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let file = temp.appendingPathComponent("rollout-date-\(thread).jsonl")
        try Data().write(to: file)
        let found = try XCTUnwrap(KittySessionResolver.transcriptPath(for: thread, sessionsDirectory: temp))
        XCTAssertEqual(URL(fileURLWithPath: found).lastPathComponent, file.lastPathComponent)
        XCTAssertTrue(FileManager.default.contentsEqual(atPath: found, andPath: file.path))
        XCTAssertNil(KittySessionResolver.transcriptPath(for: "--last", sessionsDirectory: temp))
    }
}
