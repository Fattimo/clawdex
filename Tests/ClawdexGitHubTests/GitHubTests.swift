import XCTest
import CryptoKit
@testable import ClawdexGitHub

final class GitHubTests: XCTestCase {
    func pr(_ number: Int = 1, head: String = "feature", base: String = "main", state: String = "OPEN",
            draft: Bool = false, merge: String = "CLEAN", review: String? = nil, conclusion: String? = "SUCCESS") throws -> GitHubPR {
        var object: [String: Any] = ["number": number, "title": "PR \(number)", "headRefName": head,
            "baseRefName": base, "headRefOid": "sha\(number)", "state": state, "isDraft": draft,
            "mergeable": "MERGEABLE", "mergeStateStatus": merge,
            "statusCheckRollup": [["name": "tests", "status": conclusion == nil ? "IN_PROGRESS" : "COMPLETED", "conclusion": conclusion as Any? ?? NSNull()]]]
        if let review { object["reviewDecision"] = review }
        return try JSONDecoder().decode(GitHubPR.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func config() throws -> GitHubConfig {
        var result = try GitHubConfig(); result.repositories = ["owner/repo"]; result.login = "me"; result.enabled = true; return result
    }
    func testReadinessRequiresCleanMergeAndCompleteChecks() throws {
        XCTAssertEqual(try pr().health, .ready)
        XCTAssertEqual(try pr(merge: "UNKNOWN").health, .unknown)
        XCTAssertEqual(try pr(merge: "BLOCKED").health, .blocked)
        XCTAssertEqual(try pr(review: "REVIEW_REQUIRED").health, .review)
        XCTAssertEqual(try pr(review: "CHANGES_REQUESTED").health, .blocked)
        XCTAssertEqual(try pr(conclusion: "FAILURE").health, .failed)
        XCTAssertEqual(try pr(conclusion: "CANCELLED").health, .failed)
        XCTAssertEqual(try pr(conclusion: nil).health, .checking)
        XCTAssertEqual(try pr(draft: true).health, .draft)
        var unknown = try pr(); unknown.statusCheckRollup = nil
        XCTAssertNotEqual(unknown.health, .ready)
    }
    func testClosedIsNotMerged() throws {
        XCTAssertEqual(try pr(state: "CLOSED").health, .closed)
        XCTAssertEqual(try pr(state: "MERGED", conclusion: "FAILURE").health, .merged)
    }
    func testStackCardUsesBottomOpenPRAndRetainsPositionAfterParentMerge() throws {
        let definition = StackDefinition(id: "stack", name: "Old branch slug", repository: "owner/repo", numbers: [1,2,3])
        let stack = GitHubStack(definition: definition, pullRequests: try [pr(3, head: "tip"), pr(1, state: "MERGED"), pr(2, head: "middle")])
        XCTAssertEqual(stack.bottomPR?.number, 2)
        XCTAssertEqual(stack.bottomPosition, 2)
        let old = try pr()
        XCTAssertNil(old.createdAt)
        XCTAssertNil(old.unresolvedReviewCount)
        let merged = GitHubStack(definition: definition, pullRequests: try [pr(1, state: "MERGED"), pr(2, state: "CLOSED"), pr(3, state: "MERGED")])
        XCTAssertNil(merged.bottomPR)
    }

    func testReviewCounterPaginatesAndCountsUnresolvedConversationsOnce() throws {
        func page(_ threads: [(String, Bool)], next: String?) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["data": ["repository": ["pullRequest": ["reviewThreads": [
                "nodes": threads.map { ["id": $0.0, "isResolved": $0.1] as [String: Any] },
                "pageInfo": ["hasNextPage": next != nil, "endCursor": next as Any? ?? NSNull()]
            ]]]]])
        }
        var cursors: [String?] = []
        let result = try ReviewThreadCounter.count { cursor in
            cursors.append(cursor)
            return try cursor == nil ? page([("a", false), ("b", true)], next: "page-2")
                : page([("a", false), ("c", false)], next: nil)
        }
        XCTAssertEqual(result, 2)
        XCTAssertEqual(cursors.count, 2)
        XCTAssertNil(cursors[0]); XCTAssertEqual(cursors[1], "page-2")
        XCTAssertThrowsError(try ReviewThreadCounter.count { _ in try page([("a", false)], next: "repeated") })
        XCTAssertThrowsError(try ReviewThreadCounter.count { _ in Data("{\"data\":null,\"errors\":[{\"message\":\"Unavailable\"}]}".utf8) })
        XCTAssertEqual(try ReviewThreadCounter.count { _ in try page([("a", true)], next: nil) }, 0)
    }
    func testDiscoveryOrdersParentBeforeChild() throws {
        let prs = try [pr(3, head: "tip", base: "middle"), pr(1, head: "base"), pr(2, head: "middle", base: "base")]
        let groups = StackDiscovery.discover(repository: "owner/repo", prs: prs, previous: [], manual: [])
        XCTAssertEqual(groups.count, 1); XCTAssertEqual(groups[0].numbers, [1, 2, 3])
        XCTAssertTrue(GitHubStack(definition: groups[0], pullRequests: [prs[1], prs[2], prs[0]]).ready)
    }
    func testMergedParentAndRetargetingKeepChainIdentity() throws {
        let original = StackDefinition(id: "stable", name: "Billing", repository: "owner/repo", numbers: [1, 2])
        let prs = try [pr(1, head: "base", state: "MERGED"), pr(2, head: "tip", base: "main")]
        let groups = StackDiscovery.discover(repository: "owner/repo", prs: prs, previous: [original], manual: [])
        XCTAssertEqual(groups.count, 1); XCTAssertEqual(groups[0], original)
        XCTAssertTrue(GitHubStack(definition: original, pullRequests: prs).ready)
        XCTAssertFalse(GitHubStack(definition: original, pullRequests: [prs[0]]).ready)
    }
    func testManualStackGroupsUnrelatedMainBranches() throws {
        let manual = StackDefinition(id: "manual", name: "Billing", repository: "owner/repo", numbers: [2, 1])
        let groups = StackDiscovery.discover(repository: "owner/repo", prs: try [pr(1), pr(2, head: "other")], previous: [], manual: [manual])
        XCTAssertEqual(groups, [manual])
    }
    func testForkedDependenciesStayInOneStack() throws {
        let prs = try [pr(1, head: "base"), pr(2, head: "a", base: "base"), pr(3, head: "b", base: "base")]
        let groups = StackDiscovery.discover(repository: "owner/repo", prs: prs, previous: [], manual: [])
        XCTAssertEqual(groups.count, 1); XCTAssertEqual(groups[0].numbers, [1, 2, 3])
    }
    func testNewParentPrecedesCachedMembers() throws {
        let previous = StackDefinition(id: "chain", name: "Chain", repository: "owner/repo", numbers: [2, 3])
        let prs = try [pr(2, head: "middle", base: "new-base"), pr(3, head: "tip", base: "middle"), pr(4, head: "new-base")]
        let groups = StackDiscovery.discover(repository: "owner/repo", prs: prs, previous: [previous], manual: [])
        XCTAssertEqual(groups.count, 1); XCTAssertEqual(groups[0].numbers, [4, 2, 3])
    }
    func testCycleNeverReportsReady() throws {
        let prs = try [pr(1, head: "a", base: "b"), pr(2, head: "b", base: "a")]
        let groups = StackDiscovery.discover(repository: "owner/repo", prs: prs, previous: [], manual: [])
        XCTAssertEqual(groups.count, 1)
        XCTAssertFalse(GitHubStack(definition: groups[0], pullRequests: prs).ready)
    }
    func testPRReferencesRejectOtherHostsAndInjection() throws {
        XCTAssertEqual(try PRReference(url: "https://github.com/Owner/Repo/pull/12").id, "owner/repo#12")
        for url in ["http://github.com/o/r/pull/1", "https://github.com.evil.test/o/r/pull/1", "https://user@github.com/o/r/pull/1", "https://github.com/o/r/pull/0", "https://github.com/o/r/pull/1?next=evil", "https://github.com/o/r/issues/1"] {
            XCTAssertThrowsError(try PRReference(url: url), url)
        }
        XCTAssertFalse(PRReference.validRepository("../repo")); XCTAssertFalse(PRReference.validRepository("owner/repo;echo"))
        XCTAssertNil(PRReference.publicEndpoint("https://user:password@example.com"))
        XCTAssertNil(PRReference.publicEndpoint("http://localhost:1234"))
    }
    func testGitHubSignatureTestVectorAndTampering() {
        let body = Data("Hello, World!".utf8)
        let secret = "It's a Secret to Everybody"
        let signature = "sha256=757107ea0eb2509fc211221cce984b8a37570b6d7586c22c46f4379c8b043e17"
        // Compute and compare independently; exact raw bytes, not parsed JSON.
        let digest = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: Data(secret.utf8)))
        let expected = "sha256=" + digest.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(expected, signature)
        XCTAssertTrue(WebhookSecurity.validSignature(expected, body: body, secret: secret))
        XCTAssertFalse(WebhookSecurity.validSignature(expected, body: Data("Hello, World?".utf8), secret: secret))
        XCTAssertFalse(WebhookSecurity.validSignature(expected, body: body, secret: "wrong"))
        XCTAssertFalse(WebhookSecurity.validSignature(nil, body: body, secret: secret))
        XCTAssertFalse(WebhookSecurity.validSignature(signature + "00", body: body, secret: secret))
    }
    func testRelevanceFiltersByRepoAndHeadSHA() throws {
        let config = try config(); var snapshot = GitHubSnapshot(); var repo = GitHubRepositoryState(repository: "owner/repo")
        repo.pullRequests = try [pr()]; snapshot.repositories = [repo]
        func data(_ name: String, sha: String) throws -> Data { try JSONSerialization.data(withJSONObject: ["repository": ["full_name": name], "check_run": ["head_sha": sha]]) }
        XCTAssertEqual(WebhookSecurity.relevantRepository(event: "check_run", body: try data("owner/repo", sha: "sha1"), config: config, snapshot: snapshot), "owner/repo")
        XCTAssertNil(WebhookSecurity.relevantRepository(event: "check_run", body: try data("owner/repo", sha: "other"), config: config, snapshot: snapshot))
        XCTAssertNil(WebhookSecurity.relevantRepository(event: "check_run", body: try data("other/repo", sha: "sha1"), config: config, snapshot: snapshot))
        let newPR = try JSONSerialization.data(withJSONObject: ["repository": ["full_name": "owner/repo"], "pull_request": ["number": 2, "user": ["login": "me"]]])
        XCTAssertEqual(WebhookSecurity.relevantRepository(event: "pull_request", body: newPR, config: config, snapshot: snapshot), "owner/repo")
    }
    func testHTTPParsingRejectsAmbiguousOrOversizedRequests() throws {
        let request = Data("POST /github/webhook HTTP/1.1\r\nContent-Length: 2\r\nContent-Type: application/json\r\n\r\n{}".utf8)
        let parsed = try XCTUnwrap(WebhookRequest.parse(request))
        XCTAssertEqual(parsed.path, "/github/webhook"); XCTAssertEqual(parsed.body, Data("{}".utf8))
        XCTAssertNil(try WebhookRequest.parse(request.dropLast()))
        for headers in ["Content-Length: 2\r\nContent-Length: 2", "Transfer-Encoding: chunked", "Content-Length: -1", "Content-Length: 99999999"] {
            XCTAssertThrowsError(try WebhookRequest.parse(Data("POST /github/webhook HTTP/1.1\r\n\(headers)\r\n\r\n{}".utf8)))
        }
        XCTAssertThrowsError(try WebhookRequest.parse(Data(repeating: 65, count: WebhookRequest.maxHeaders + 1)))
        XCTAssertThrowsError(try WebhookRequest.parse(request + Data("extra".utf8)))
    }
    func testConfigRoundtripRestrictsPermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clawdex-github-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try config(); try GitHubStore.saveConfig(config, at: directory)
        let restored = try GitHubStore.loadConfig(at: directory)
        XCTAssertEqual(restored.secret, config.secret); XCTAssertEqual(restored.secret.count, 64)
        let mode = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("config.json").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        let folderMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(folderMode?.intValue, 0o700)
    }

    func testLoopbackHTTPServerAcceptsSignedPayloadAndRejectsTampering() throws {
        let ready = expectation(description: "receiver ready")
        let secret = "test-secret-with-enough-entropy-for-a-fixture"
        let port = UInt16.random(in: 49000..<59000)
        let server = GitHubWebhookServer(port: port, handle: { request in
            if request.path == "/healthz" { return 200 }
            return WebhookSecurity.validSignature(request.headers["x-hub-signature-256"], body: request.body, secret: secret) ? 202 : 401
        }, state: { success, _ in if success { ready.fulfill() } })
        try server.start(); defer { server.stop() }; wait(for: [ready], timeout: 3)
        let body = Data("{\"zen\":\"fixture\"}".utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: Data(secret.utf8)))
        let signature = "sha256=" + mac.map { String(format: "%02x", $0) }.joined()
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        let responses = expectation(description: "HTTP responses"); responses.expectedFulfillmentCount = 2
        for (payload, expected) in [(body, 202), (Data("{}".utf8), 401)] {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/github/webhook")!)
            request.httpMethod = "POST"; request.httpBody = payload; request.timeoutInterval = 3
            request.setValue(signature, forHTTPHeaderField: "X-Hub-Signature-256")
            session.dataTask(with: request) { _, response, error in
                XCTAssertNil(error); XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, expected); responses.fulfill()
            }.resume()
        }
        wait(for: [responses], timeout: 5)
    }
    func testListenerCanRestartImmediatelyOnSamePort() throws {
        let port = UInt16.random(in: 49000..<59000)
        for iteration in 0..<3 {
            let ready = expectation(description: "listener \(iteration) ready")
            let server = GitHubWebhookServer(port: port, handle: { _ in 200 }, state: { success, _ in if success { ready.fulfill() } })
            try server.start(); wait(for: [ready], timeout: 4)
            server.stop()
        }
    }
    func testNgrokURLIsConnectedOnlyAfterTunnelActuallyStarts() throws {
        func log(_ object: [String: String]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
        XCTAssertNil(NgrokLogEvent.parse(try log(["msg": "config loaded", "url": "https://example.ngrok-free.dev"])))
        XCTAssertEqual(NgrokLogEvent.parse(try log(["msg": "started tunnel", "url": "https://example.ngrok-free.dev"])), .connected("https://example.ngrok-free.dev"))
        XCTAssertNil(NgrokLogEvent.parse(try log(["msg": "started tunnel", "url": "http://localhost:1234"])))
        let result = NgrokLogEvent.parse(try log(["msg": "failed", "err": "private-account fixture-secret ERR_NGROK_123"]))
        guard case .problem(let message) = result else { return XCTFail("Expected verification guidance") }
        XCTAssertTrue(message.contains("Verify")); XCTAssertFalse(message.contains("private-account")); XCTAssertFalse(message.contains("fixture-secret"))
    }
    func testWebhookURLChangeCanOnlyUpdateStoredOwnedHook() {
        let hooks: [[String: Any]] = [
            ["id": 10, "config": ["url": "https://old.ngrok-free.app/github/webhook"]],
            ["id": 20, "config": ["url": "https://new.ngrok-free.app/github/webhook"]]
        ]
        XCTAssertEqual(GitHubClient.webhookID(in: hooks, knownID: 10, url: "https://new.ngrok-free.app/github/webhook"), 10)
        XCTAssertNil(GitHubClient.webhookID(in: hooks, knownID: 99, url: "https://new.ngrok-free.app/github/webhook"))
        XCTAssertEqual(GitHubClient.webhookID(in: hooks, knownID: nil, url: "https://new.ngrok-free.app/github/webhook"), 20)
    }
    func testRecentSelectionUsesPRUpdateTimeRatherThanNumber() throws {
        let input = try [pr(1, head: "old-work"), pr(20, head: "new-work"), pr(30, head: "other")]
        let stacks = input.enumerated().map { index, value -> GitHubStack in
            var value = value
            value.updatedAt = ["2026-11-03T12:00:00Z", "2026-10-01T12:00:00Z", "2026-09-01T12:00:00Z"][index]
            return GitHubStack(definition: StackDefinition(id: "\(value.number)", name: value.title, repository: "owner/repo", numbers: [value.number]), pullRequests: [value])
        }
        XCTAssertEqual(GitHubBoardSelection.recentStacks(stacks, limit: 2).map(\.definition.id), ["1", "20"])
    }
    func testFourRecentPRsShareTheirWholeChainWithoutBackfillingExtraCards() throws {
        let chain = GitHubStack(definition: StackDefinition(id: "chain", name: "Chain", repository: "owner/repo", numbers: [8, 9]), pullRequests: try [pr(8), pr(9, head: "tip")])
        let singles = try (1...7).map { n in
            GitHubStack(definition: StackDefinition(id: "\(n)", name: "Single", repository: "owner/repo", numbers: [n]), pullRequests: [try pr(n)])
        }
        let selected = GitHubBoardSelection.recentStacks(singles + [chain])
        XCTAssertEqual(selected.map(\.definition.id), ["chain", "7", "6"])
        XCTAssertEqual(selected[0].pullRequests.map(\.number), [8, 9])
    }
    func testRecentSelectionExcludesClosedAndMergedPRsAndDecodesOldCache() throws {
        let old = try pr(1)
        XCTAssertNil(old.updatedAt)
        let stacks = try [pr(1), pr(10, state: "CLOSED"), pr(20, state: "MERGED")].map { value in
            GitHubStack(definition: StackDefinition(id: "\(value.number)", name: value.title, repository: "owner/repo", numbers: [value.number]), pullRequests: [value])
        }
        XCTAssertEqual(GitHubBoardSelection.recentStacks(stacks).map(\.definition.id), ["1"])
        XCTAssertTrue(GitHubBoardSelection.recentStacks(stacks, limit: 0).isEmpty)
    }
}
