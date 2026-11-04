import Foundation
import CryptoKit
import Network

public struct WebhookRequest {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data
    public static let maxBody = 1 << 20
    public static let maxHeaders = 16 << 10

    /// nil means incomplete. Only fixed-length, single HTTP requests are accepted.
    public static func parse(_ bytes: Data) throws -> WebhookRequest? {
        guard let separator = bytes.range(of: Data("\r\n\r\n".utf8)) else {
            if bytes.count > maxHeaders { throw GitHubError.message("Headers too large") }; return nil
        }
        guard separator.lowerBound < maxHeaders,
              let text = String(data: bytes[..<separator.lowerBound], encoding: .utf8) else { throw GitHubError.message("Invalid headers") }
        let lines = text.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3, first[2] == "HTTP/1.1" || first[2] == "HTTP/1.0" else { throw GitHubError.message("Invalid request line") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { throw GitHubError.message("Invalid header") }
            let name = line[..<colon].lowercased()
            guard headers[name] == nil else { throw GitHubError.message("Duplicate header") }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil else { throw GitHubError.message("Chunked requests are not supported") }
        let length = headers["content-length"] ?? "0"
        guard !length.isEmpty, length.allSatisfy({ $0.isASCII && $0.isNumber }), let count = Int(length), count <= maxBody else {
            throw GitHubError.message("Invalid body length")
        }
        let end = separator.upperBound + count
        guard bytes.count >= end else { return nil }
        guard bytes.count == end else { throw GitHubError.message("Unexpected trailing data") }
        return WebhookRequest(method: String(first[0]), path: String(first[1]), headers: headers, body: Data(bytes[separator.upperBound..<end]))
    }
}

public enum WebhookSecurity {
    public static func validSignature(_ signature: String?, body: Data, secret: String) -> Bool {
        guard let signature, signature.hasPrefix("sha256="), signature.count == 71 else { return false }
        let hex = Array(signature.dropFirst(7)); var code = Data()
        for index in stride(from: 0, to: hex.count, by: 2) {
            guard let value = UInt8(String(hex[index...index+1]), radix: 16) else { return false }; code.append(value)
        }
        return HMAC<SHA256>.isValidAuthenticationCode(code, authenticating: body, using: SymmetricKey(data: Data(secret.utf8)))
    }
    /// Only relevant events invalidate a repo. CI events often have empty PR
    /// arrays, so map their head SHA to known PRs instead.
    public static func relevantRepository(event: String, body: Data, config: GitHubConfig, snapshot: GitHubSnapshot) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let repo = object["repository"] as? [String: Any], let name = (repo["full_name"] as? String)?.lowercased(),
              config.repositories.contains(name) else { return nil }
        let known = snapshot.repositories.first { $0.repository == name }?.pullRequests ?? []
        let prs = Set(known.map(\.number)); let shas = Set(known.filter { $0.state == "OPEN" }.map(\.headRefOid))
        switch event {
        case "pull_request", "pull_request_review", "pull_request_review_thread":
            guard let pr = object["pull_request"] as? [String: Any], let number = pr["number"] as? Int else { return nil }
            let author = (pr["user"] as? [String: Any])?["login"] as? String
            return prs.contains(number) || author?.lowercased() == config.login.lowercased() ? name : nil
        case "check_run", "check_suite":
            guard let check = object[event] as? [String: Any], let sha = check["head_sha"] as? String else { return nil }
            return shas.contains(sha) ? name : nil
        case "status": return (object["sha"] as? String).map(shas.contains) == true ? name : nil
        case "push":
            guard let ref = object["ref"] as? String else { return nil }
            return known.contains { ref == "refs/heads/" + $0.headRefName || ref == "refs/heads/" + $0.baseRefName } ? name : nil
        case "merge_group", "branch_protection_rule", "repository_ruleset": return name
        default: return nil
        }
    }
}

/// One serial network queue, at most eight connections, absolute 5s deadline.
/// The callback validates/queues work and returns immediately; no API calls here.
public final class GitHubWebhookServer {
    private let queue = DispatchQueue(label: "clawdex.github.http")
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var stopped = false
    private var bindAttempts = 0
    private let port: UInt16
    private let handle: (WebhookRequest) -> Int
    private let state: (Bool, String?) -> Void
    public init(port: UInt16, handle: @escaping (WebhookRequest) -> Int, state: @escaping (Bool, String?) -> Void) {
        self.port = port; self.handle = handle; self.state = state
    }
    public func start() throws {
        let listener = try makeListener()
        queue.async { [weak self] in self?.install(listener) }
    }
    private func makeListener() throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        return try NWListener(using: parameters)
    }
    private func install(_ listener: NWListener) {
        guard !stopped else { listener.cancel(); return }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] newState in
            guard let self, let listener, self.listener === listener, !self.stopped else { return }
            switch newState {
            case .ready: self.bindAttempts = 0; self.state(true, nil)
            case .failed:
                listener.stateUpdateHandler = nil; listener.cancel(); self.listener = nil
                self.state(false, "Could not bind the local webhook receiver")
                guard self.bindAttempts < 6 else { return }
                self.bindAttempts += 1
                self.queue.asyncAfter(deadline: .now() + 0.1 * pow(2, Double(self.bindAttempts))) { [weak self] in
                    guard let self, !self.stopped else { return }
                    do { self.install(try self.makeListener()) } catch { self.state(false, "Could not restart webhook receiver") }
                }
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }
    public func stop() {
        // Keep the owner alive until cleanup runs. A weak capture here can
        // skip cancellation after reload releases its last reference, leaving
        // Network's active listener bound to the old port indefinitely.
        queue.async { [self] in
            stopped = true
            listener?.stateUpdateHandler = nil; listener?.cancel(); listener = nil
            connections.values.forEach { $0.cancel() }; connections.removeAll()
        }
    }
    private func accept(_ connection: NWConnection) {
        guard connections.count < 8 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection; connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.connections.removeValue(forKey: id)?.cancel() }
        receive(connection, id: id, buffer: Data())
    }
    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { [weak self] data, _, complete, error in
            guard let self, self.connections[id] != nil else { return }
            var bytes = buffer; if let data { bytes.append(data) }
            do {
                guard bytes.count <= WebhookRequest.maxHeaders + WebhookRequest.maxBody else { self.respond(connection, id: id, status: 413); return }
                if let request = try WebhookRequest.parse(bytes) {
                    self.respond(connection, id: id, status: self.handle(request))
                } else if complete || error != nil { self.connections.removeValue(forKey: id)?.cancel() }
                else { self.receive(connection, id: id, buffer: bytes) }
            } catch { self.respond(connection, id: id, status: 400) }
        }
    }
    private func respond(_ connection: NWConnection, id: UUID, status: Int) {
        let body = "\(status)\n"
        let response = "HTTP/1.1 \(status) Result\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            connection.cancel(); self?.connections[id] = nil
        })
    }
}
