import Foundation
import Darwin

public enum ToolProcess {
    public static func executable(_ name: String) -> URL? {
        let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        return dirs.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    /// Files avoid stdout/stderr pipe backpressure on large PR responses.
    public static func run(_ name: String, _ arguments: [String], input: Data? = nil, timeout: TimeInterval = 45) throws -> Data {
        guard let executable = executable(name) else { throw GitHubError.message("\(name) is not installed") }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("clawdex-gh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temp) }
        let stdout = temp.appendingPathComponent("stdout"), stderr = temp.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdout.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: stderr.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let out = try FileHandle(forWritingTo: stdout), err = try FileHandle(forWritingTo: stderr)
        defer { try? out.close(); try? err.close() }
        let process = Process(); process.executableURL = executable; process.arguments = arguments
        process.standardOutput = out; process.standardError = err
        var env = ProcessInfo.processInfo.environment; env["GH_PROMPT_DISABLED"] = "1"; env["GH_PAGER"] = "cat"; process.environment = env
        var stdin: FileHandle?
        if let input {
            let path = temp.appendingPathComponent("input"); try input.write(to: path, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            stdin = try FileHandle(forReadingFrom: path); process.standardInput = stdin
        } else { process.standardInput = FileHandle.nullDevice }
        defer { try? stdin?.close() }
        let finished = DispatchSemaphore(value: 0); process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate(); if finished.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            throw GitHubError.message("\(name) timed out")
        }
        guard process.terminationStatus == 0 else {
            let message = String(data: (try? Data(contentsOf: stderr)) ?? Data(), encoding: .utf8) ?? "Command failed"
            throw GitHubError.message(String(message.prefix(1800)))
        }
        let size = (try FileManager.default.attributesOfItem(atPath: stdout.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size < 32 << 20 else { throw GitHubError.message("GitHub response exceeds 32 MiB") }
        return try Data(contentsOf: stdout)
    }
}

public struct GitHubClient {
    public static let fields = "number,title,headRefName,baseRefName,headRefOid,state,isDraft,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup,updatedAt,createdAt"
    public init() {}
    public func login() throws -> String {
        let data = try ToolProcess.run("gh", ["api", "user", "--jq", ".login"])
        let login = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !login.isEmpty else { throw GitHubError.message("Sign in with gh auth login first") }; return login
    }
    public func pullRequest(_ ref: PRReference) throws -> GitHubPR {
        try JSONDecoder().decode(GitHubPR.self, from: ToolProcess.run("gh", ["pr", "view", String(ref.number), "--repo", ref.repository, "--json", Self.fields]))
    }
    public func refresh(repository: String, login: String, previous: GitHubRepositoryState, manual: [StackDefinition]) throws -> GitHubRepositoryState {
        guard PRReference.validRepository(repository) else { throw GitHubError.message("Invalid repository") }
        let data = try ToolProcess.run("gh", ["pr", "list", "--repo", repository, "--author", login, "--state", "open", "--limit", "1000", "--json", Self.fields])
        var prs = try JSONDecoder().decode([GitHubPR].self, from: data)
        guard prs.count < 1000 else { throw GitHubError.message("PR discovery reached its 1000-PR limit; results may be incomplete") }
        // Keep merged parents until the entire stack is done. Explicitly tracked
        // PRs may belong to someone else, so refresh those too.
        let known = Set(previous.stacks.flatMap(\.numbers) + manual.filter { $0.repository == repository }.flatMap(\.numbers))
        let open = Set(prs.map(\.number))
        for number in known.subtracting(open).sorted() {
            if let old = previous.pullRequests.first(where: { $0.number == number }), old.state == "MERGED" { prs.append(old) }
            else { prs.append(try pullRequest(PRReference(repository: repository, number: number))) }
        }
        // GitHub calculates mergeability lazily. A targeted view requests its
        // current result rather than leaving old list-query UNKNOWNs forever.
        for index in prs.indices where prs[index].health == .unknown {
            prs[index] = try pullRequest(PRReference(repository: repository, number: prs[index].number))
        }
        var result = GitHubRepositoryState(repository: repository)
        result.pullRequests = prs
        result.stacks = StackDiscovery.discover(repository: repository, prs: prs, previous: previous.stacks, manual: manual)
        // Fetch review metadata for each visible recent PR, including siblings
        // in the same chain. This remains part of webhook-driven refreshes.
        let visible = GitHubBoardSelection.recentPullRequests(result.stacks.map { definition in
            GitHubStack(definition: definition, pullRequests: prs.filter { definition.numbers.contains($0.number) })
        })
        for number in Set(visible.map { $0.pr.number }) {
            guard let index = result.pullRequests.firstIndex(where: { $0.number == number }) else { continue }
            result.pullRequests[index].unresolvedReviewCount = try? unresolvedReviewCount(PRReference(repository: repository, number: number))
        }
        result.updatedAt = Date(); return result
    }
    private func unresolvedReviewCount(_ reference: PRReference) throws -> Int {
        let parts = reference.repository.split(separator: "/").map(String.init)
        let query = """
        query($owner: String!, $name: String!, $number: Int!, $cursor: String) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              reviewThreads(first: 100, after: $cursor) {
                nodes { id isResolved }
                pageInfo { hasNextPage endCursor }
              }
            }
          }
        }
        """
        return try ReviewThreadCounter.count { cursor in
            let variables: [String: Any] = ["owner": parts[0], "name": parts[1], "number": reference.number,
                                            "cursor": cursor as Any? ?? NSNull()]
            let input = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
            return try ToolProcess.run("gh", ["api", "graphql", "--input", "-"], input: input)
        }
    }
    public func disableWebhook(repository: String, id: Int) throws {
        guard PRReference.validRepository(repository), id > 0 else { throw GitHubError.message("Invalid owned webhook") }
        _ = try ToolProcess.run("gh", ["api", "--method", "PATCH", "repos/\(repository)/hooks/\(id)", "--input", "-"],
            input: JSONSerialization.data(withJSONObject: ["active": false]))
    }
    public func installWebhook(repository: String, endpoint: String, secret: String, knownID: Int? = nil, createIfMissing: Bool = true) throws -> Int {
        guard PRReference.validRepository(repository), let base = PRReference.publicEndpoint(endpoint) else { throw GitHubError.message("Invalid webhook endpoint or repository") }
        let url = base.appendingPathComponent("github/webhook").absoluteString
        let existingData = try ToolProcess.run("gh", ["api", "repos/\(repository)/hooks", "--paginate", "--slurp"])
        let pages = try JSONSerialization.jsonObject(with: existingData) as? [[[String: Any]]] ?? []
        let id = Self.webhookID(in: pages.flatMap { $0 }, knownID: knownID, url: url)
        guard id != nil || createIfMissing else { throw GitHubError.message("The stored webhook is missing. Run clawdex github hook \(repository) again.") }
        var body: [String: Any] = ["active": true,
            "events": ["pull_request", "pull_request_review", "pull_request_review_thread", "pull_request_review_comment", "check_run", "check_suite", "status", "push", "merge_group", "branch_protection_rule", "repository_ruleset"],
            "config": ["url": url, "content_type": "json", "secret": secret, "insecure_ssl": "0"]]
        if id == nil { body["name"] = "web" }
        let path = "repos/\(repository)/hooks" + id.map { "/\($0)" }.orEmpty
        let response = try ToolProcess.run("gh", ["api", "--method", id == nil ? "POST" : "PATCH", path, "--input", "-"], input: JSONSerialization.data(withJSONObject: body))
        guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any], let result = object["id"] as? Int else { throw GitHubError.message("GitHub did not return a webhook ID") }
        return result
    }
    static func webhookID(in hooks: [[String: Any]], knownID: Int?, url: String) -> Int? {
        if let knownID { return hooks.first { $0["id"] as? Int == knownID }?["id"] as? Int }
        return hooks.first { ($0["config"] as? [String: Any])?["url"] as? String == url }?["id"] as? Int
    }
}

enum ReviewThreadCounter {
    private struct Envelope: Decodable {
        struct Payload: Decodable {
            struct Repository: Decodable {
                struct PullRequest: Decodable {
                    struct Connection: Decodable {
                        struct Thread: Decodable { let id: String; let isResolved: Bool }
                        struct PageInfo: Decodable { let hasNextPage: Bool; let endCursor: String? }
                        let nodes: [Thread]; let pageInfo: PageInfo
                    }
                    let reviewThreads: Connection
                }
                let pullRequest: PullRequest?
            }
            let repository: Repository?
        }
        struct Failure: Decodable { let message: String }
        let data: Payload?
        let errors: [Failure]?
    }
    static func count(fetch: (String?) throws -> Data) throws -> Int {
        var cursor: String?
        var seen = Set<String>(), threads: [String: Bool] = [:]
        for _ in 0..<20 {
            let envelope = try JSONDecoder().decode(Envelope.self, from: fetch(cursor))
            guard envelope.errors?.isEmpty != false,
                  let page = envelope.data?.repository?.pullRequest?.reviewThreads else {
                throw GitHubError.message("Review conversations unavailable")
            }
            for thread in page.nodes { threads[thread.id] = thread.isResolved }
            if !page.pageInfo.hasNextPage { return threads.values.filter { !$0 }.count }
            guard let next = page.pageInfo.endCursor, !next.isEmpty, seen.insert(next).inserted else {
                throw GitHubError.message("Review conversation pagination incomplete")
            }
            cursor = next
        }
        throw GitHubError.message("Review conversation pagination limit reached")
    }
}

private extension Optional where Wrapped == String { var orEmpty: String { self ?? "" } }
