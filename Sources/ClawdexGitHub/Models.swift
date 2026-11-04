import Foundation
import Security

public enum GitHubError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

public struct PRReference: Codable, Hashable {
    public let repository: String
    public let number: Int
    public var url: URL { URL(string: "https://github.com/\(repository)/pull/\(number)")! }
    public var id: String { "\(repository.lowercased())#\(number)" }
    public init(repository: String, number: Int) throws {
        guard Self.validRepository(repository), number > 0 else { throw GitHubError.message("Expected owner/repo and a positive PR number.") }
        self.repository = repository.lowercased(); self.number = number
    }
    public init(url: String) throws {
        guard let parts = URLComponents(string: url), parts.scheme == "https", parts.host == "github.com",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.query == nil, parts.fragment == nil else {
            throw GitHubError.message("Use a GitHub PR URL: https://github.com/owner/repo/pull/123")
        }
        let path = parts.path.split(separator: "/")
        guard path.count == 4, path[2] == "pull", let number = Int(path[3]) else { throw GitHubError.message("Expected a GitHub PR URL.") }
        try self.init(repository: "\(path[0])/\(path[1])", number: number)
    }
    public static func validRepository(_ value: String) -> Bool {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return components.count == 2 && components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".." && component.count <= 100 &&
            component.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
        }
    }
    public static func publicEndpoint(_ text: String) -> URL? {
        guard let url = URLComponents(string: text), url.scheme == "https", let host = url.host,
              host.contains("."), url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else { return nil }
        return URL(string: "https://\(host)")
    }
}

public enum PRHealth: String, Codable {
    case ready, checking, failed, review, draft, blocked, unknown, merged, closed
    public var label: String {
        switch self {
        case .ready: return "Ready"
        case .checking: return "Checks running"
        case .failed: return "Checks failed"
        case .review: return "Needs review"
        case .draft: return "Draft"
        case .blocked: return "Blocked"
        case .unknown: return "Checking readiness"
        case .merged: return "Merged"
        case .closed: return "Closed without merge"
        }
    }
}

public struct GitHubCheck: Codable, Equatable {
    public var name: String?
    public var context: String?
    public var status: String?
    public var conclusion: String?
    public var state: String?
    public var passed: Bool { ["SUCCESS", "NEUTRAL", "SKIPPED"].contains((conclusion ?? state ?? "").uppercased()) }
    public var failed: Bool { ["FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STALE", "STARTUP_FAILURE"].contains((conclusion ?? state ?? "").uppercased()) }
}

public struct GitHubPR: Codable, Equatable {
    public var number: Int
    public var title: String
    public var headRefName: String
    public var baseRefName: String
    public var headRefOid: String
    public var state: String
    public var isDraft: Bool
    public var mergeable: String?
    public var mergeStateStatus: String?
    public var reviewDecision: String?
    public var statusCheckRollup: [GitHubCheck]?
    public var updatedAt: String?
    public var health: PRHealth {
        if state == "MERGED" { return .merged }
        if state == "CLOSED" { return .closed }
        if state != "OPEN" { return .unknown }
        if isDraft { return .draft }
        let checks = statusCheckRollup ?? []
        if checks.contains(where: \.failed) { return .failed }
        if mergeable == "CONFLICTING" || mergeStateStatus == "DIRTY" || reviewDecision == "CHANGES_REQUESTED" { return .blocked }
        if !checks.allSatisfy(\.passed) { return .checking }
        if reviewDecision == "REVIEW_REQUIRED" { return .review }
        if mergeable == "MERGEABLE", mergeStateStatus == "CLEAN", statusCheckRollup != nil { return .ready }
        if ["BLOCKED", "BEHIND", "UNSTABLE", "HAS_HOOKS"].contains(mergeStateStatus ?? "") { return .blocked }
        return .unknown
    }
    public var checksPassed: Bool { guard let checks = statusCheckRollup else { return false }; return checks.allSatisfy(\.passed) }
    public var explanation: String {
        if health == .failed { return statusCheckRollup?.first(where: \.failed).map { "Failed: \($0.name ?? $0.context ?? "check")" } ?? health.label }
        if mergeable == "CONFLICTING" { return "Resolve merge conflicts" }
        if reviewDecision == "CHANGES_REQUESTED" { return "Address requested changes" }
        if mergeStateStatus == "BEHIND" { return "Update branch, then recheck" }
        if health == .blocked && checksPassed { return "Checks pass; GitHub still blocks merging" }
        return health.label
    }
}

public struct StackDefinition: Codable, Equatable {
    public var id: String
    public var name: String
    public var repository: String
    public var numbers: [Int]
    public init(id: String = UUID().uuidString, name: String, repository: String, numbers: [Int]) {
        self.id = id; self.name = name; self.repository = repository; self.numbers = numbers
    }
}

public struct GitHubStack: Codable, Equatable {
    public var definition: StackDefinition
    public var pullRequests: [GitHubPR]
    public var missing: [Int] { definition.numbers.filter { n in !pullRequests.contains { $0.number == n } } }
    public var merged: Bool { missing.isEmpty && !pullRequests.isEmpty && pullRequests.allSatisfy { $0.health == .merged } }
    public var ready: Bool {
        missing.isEmpty && validOrder && !pullRequests.isEmpty && !merged && pullRequests.allSatisfy { [.ready, .merged].contains($0.health) }
    }
    public var validOrder: Bool {
        for (index, pr) in pullRequests.enumerated() where pr.state != "MERGED" {
            if let parent = pullRequests.firstIndex(where: { $0.number != pr.number && $0.headRefName == pr.baseRefName }), parent >= index { return false }
        }
        return true
    }
    public var signature: String { pullRequests.map { "\($0.number):\($0.headRefOid):\($0.state)" }.joined(separator: ",") }
    public var label: String {
        if !missing.isEmpty { return "Sync incomplete" }
        if !validOrder { return "Check stack order" }
        if merged { return "Merged" }
        if ready { let count = pullRequests.filter { $0.health != .merged }.count; return "\(count)/\(count) ready" }
        if pullRequests.contains(where: { [.failed, .blocked, .closed].contains($0.health) }) { return "Needs you" }
        if pullRequests.contains(where: { $0.health == .checking }) { return "Checks running" }
        if pullRequests.contains(where: { $0.health == .review }) { return "Needs review" }
        if pullRequests.contains(where: { $0.health == .draft }) { return "Draft" }
        return "Checking readiness"
    }
}

/// Provisional recency rule, kept separate from discovery and readiness so the
/// user-facing activity heuristic can evolve without changing tracked chains.
public enum GitHubBoardSelection {
    public static func recentStacks(_ stacks: [GitHubStack], limit: Int = 4) -> [GitHubStack] {
        guard limit > 0 else { return [] }
        let candidates = stacks.flatMap { stack in
            stack.pullRequests.filter { $0.state == "OPEN" }.map { (stack: stack, pr: $0) }
        }.sorted {
            let a = $0.pr.updatedAt ?? "", b = $1.pr.updatedAt ?? ""
            if a != b { return a > b }
            if $0.pr.number != $1.pr.number { return $0.pr.number > $1.pr.number }
            return $0.stack.definition.id < $1.stack.definition.id
        }
        var prs = Set<String>(), chains = Set<String>()
        var result: [GitHubStack] = []
        for candidate in candidates {
            let ref = "\(candidate.stack.definition.repository)#\(candidate.pr.number)"
            guard prs.insert(ref).inserted else { continue }
            if prs.count > limit { break }
            if chains.insert(candidate.stack.definition.id).inserted { result.append(candidate.stack) }
        }
        return result
    }
}

public enum StackDiscovery {
    /// Connected branch chains, including forks, ordered base before children.
    /// Cached membership survives retargeting/merging; manual groups take priority.
    public static func discover(repository: String, prs: [GitHubPR], previous: [StackDefinition], manual: [StackDefinition]) -> [StackDefinition] {
        var remaining = Dictionary(prs.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        var groups: [StackDefinition] = []
        for group in manual.filter({ $0.repository == repository }) {
            groups.append(group); for n in group.numbers { remaining[n] = nil }
        }
        let nodes = remaining.values.sorted { $0.number < $1.number }
        var adjacency: [Int: Set<Int>] = [:]
        for p in nodes {
            for parent in nodes where parent.number != p.number && parent.headRefName == p.baseRefName && !parent.headRefName.isEmpty {
                adjacency[p.number, default: []].insert(parent.number)
                adjacency[parent.number, default: []].insert(p.number)
            }
        }
        // Preserve chain identity when GitHub retargets a child after a merge.
        for old in previous where old.repository == repository && !manual.contains(where: { $0.id == old.id }) {
            let members = old.numbers.filter { remaining[$0] != nil }
            for pair in zip(members, members.dropFirst()) {
                adjacency[pair.0, default: []].insert(pair.1); adjacency[pair.1, default: []].insert(pair.0)
            }
        }
        var visited = Set<Int>()
        for node in nodes where !visited.contains(node.number) {
            var component: [Int] = []; var queue = [node.number]
            while let n = queue.popLast() {
                guard visited.insert(n).inserted else { continue }; component.append(n)
                queue += Array(adjacency[n] ?? [])
            }
            let memberSet = Set(component)
            let old = previous.first { $0.repository == repository && !Set($0.numbers).isDisjoint(with: memberSet) }
            let oldOrder = old?.numbers ?? []
            var ordered: [Int] = []; var pending = component.sorted {
                let a = oldOrder.firstIndex(of: $0) ?? Int.max, b = oldOrder.firstIndex(of: $1) ?? Int.max
                return a == b ? $0 < $1 : a < b
            }
            while !pending.isEmpty {
                let available = pending.first { n in
                    guard let p = remaining[n] else { return true }
                    return !pending.contains { parent in parent != n && remaining[parent]?.headRefName == p.baseRefName }
                } ?? pending[0] // Cycle: stable display, readiness is gated below.
                ordered.append(available); pending.removeAll { $0 == available }
            }
            let first = remaining[ordered[0]]!
            groups.append(StackDefinition(id: old?.id ?? "\(repository)#\(first.number)",
                name: old?.name ?? first.headRefName.split(separator: "/").last.map(String.init) ?? first.title,
                repository: repository, numbers: ordered))
        }
        return groups
    }
}

public struct GitHubRepositoryState: Codable, Equatable {
    public var repository: String
    public var pullRequests: [GitHubPR] = []
    public var stacks: [StackDefinition] = []
    public var updatedAt: Date?
    public var error: String?
    public var webhookURL: String?
    public var webhookError: String?
    public init(repository: String) { self.repository = repository }
}

public struct GitHubSnapshot: Codable {
    public var repositories: [GitHubRepositoryState] = []
    public var tunnelURL: String?
    public var tunnelError: String?
    public var lastWebhook: Date?
    public var receiverReady = false
    public init() {}
    public func stacks(in config: GitHubConfig) -> [GitHubStack] {
        repositories.filter { config.repositories.contains($0.repository) }.flatMap { repo in
            repo.stacks.filter { !config.hiddenStacks.contains($0.id) }.map { definition in
                GitHubStack(definition: definition, pullRequests: definition.numbers.compactMap { number in repo.pullRequests.first { $0.number == number } })
            }
        }
    }
}

public struct GitHubConfig: Codable {
    public var enabled = false
    public var repositories: [String] = []
    public var login = ""
    public var port: UInt16 = 47839
    public var secret: String
    public var publicURL: String?
    public var manualStacks: [StackDefinition] = []
    public var hiddenStacks: [String] = []
    public var hookIDs: [String: Int] = [:]
    public init() throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw GitHubError.message("Could not generate a webhook secret") }
        secret = bytes.map { String(format: "%02x", $0) }.joined()
    }
    public func validate() throws {
        guard port > 1024, secret.utf8.count >= 32, repositories.allSatisfy(PRReference.validRepository), !login.isEmpty else { throw GitHubError.message("Invalid GitHub configuration") }
        if let url = publicURL, PRReference.publicEndpoint(url) == nil { throw GitHubError.message("Expected an HTTPS ngrok endpoint without a path") }
        for group in manualStacks {
            guard repositories.contains(group.repository), !group.numbers.isEmpty, group.numbers.allSatisfy({ $0 > 0 }), Set(group.numbers).count == group.numbers.count else { throw GitHubError.message("Invalid manual stack") }
        }
    }
}

public enum GitHubStore {
    public static var directory: URL {
        let home = ProcessInfo.processInfo.environment["CLAWDEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".clawdex")
        return home.appendingPathComponent("github")
    }
    public static func loadConfig(at directory: URL = directory) throws -> GitHubConfig {
        let config = try JSONDecoder().decode(GitHubConfig.self, from: Data(contentsOf: directory.appendingPathComponent("config.json")))
        try config.validate(); return config
    }
    public static func saveConfig(_ config: GitHubConfig, at directory: URL = directory) throws {
        try config.validate(); try save(config, name: "config.json", at: directory)
    }
    public static func loadSnapshot(at directory: URL = directory) -> GitHubSnapshot {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("state.json")), let state = try? JSONDecoder().decode(GitHubSnapshot.self, from: data) else { return GitHubSnapshot() }
        return state
    }
    public static func saveSnapshot(_ state: GitHubSnapshot, at directory: URL = directory) throws { try save(state, name: "state.json", at: directory) }
    private static func save<T: Encodable>(_ value: T, name: String, at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let path = directory.appendingPathComponent(name)
        try JSONEncoder().encode(value).write(to: path, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
}
