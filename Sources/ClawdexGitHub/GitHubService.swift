import Foundation
import Darwin

/// Polling (default) or event-driven state owner. Network API work never occupies the control queue,
/// so webhook acknowledgements aren't delayed behind a slow GitHub response.
public final class GitHubService {
    public let config: GitHubConfig
    private let queue = DispatchQueue(label: "clawdex.github.state")
    private let worker = DispatchQueue(label: "clawdex.github.api", qos: .utility)
    // Serial across service generations: an old URL update must finish before
    // a newly restarted service updates that same owned hook again.
    private static let webhookQueue = DispatchQueue(label: "clawdex.github.webhook-registration", qos: .utility)
    private let client = GitHubClient()
    private var snapshot: GitHubSnapshot
    private var server: GitHubWebhookServer?
    private var tunnel: NgrokTunnel?
    private var active = false
    private var pollTimer: DispatchSourceTimer?
    private var disabledHooks = Set<String>()
    private let pollInterval: TimeInterval
    private let directory: URL
    private let refreshRepository: (String, String, GitHubRepositoryState, [StackDefinition]) throws -> GitHubRepositoryState
    private let disableWebhook: (String, Int) throws -> Void
    private var pending = Set<String>()
    private var fetching = false
    private var scheduled: DispatchWorkItem?
    private var deliveries = Set<String>()
    private var deliveryOrder: [String] = []
    private var settling: [String: Int] = [:]
    private let onChange: (GitHubSnapshot) -> Void
    public convenience init(config: GitHubConfig, onChange: @escaping (GitHubSnapshot) -> Void) {
        let client = GitHubClient()
        self.init(config: config, pollInterval: 120, directory: GitHubStore.directory,
            refresh: client.refresh, disableWebhook: client.disableWebhook, onChange: onChange)
    }
    init(config: GitHubConfig, pollInterval: TimeInterval, directory: URL,
         refresh: @escaping (String, String, GitHubRepositoryState, [StackDefinition]) throws -> GitHubRepositoryState,
         disableWebhook: @escaping (String, Int) throws -> Void,
         onChange: @escaping (GitHubSnapshot) -> Void) {
        self.config = config; self.pollInterval = pollInterval; self.directory = directory
        self.refreshRepository = refresh; self.disableWebhook = disableWebhook
        self.onChange = onChange; snapshot = GitHubStore.loadSnapshot(at: directory)
    }
    public func start() {
        queue.async { [weak self] in
            guard let self, self.config.enabled, !self.active else { return }
            self.active = true; self.snapshot.receiverReady = false; self.snapshot.tunnelURL = nil
            self.snapshot.tunnelError = self.config.webhooksEnabled ? "Connecting ngrok" : nil
            for repo in self.config.repositories {
                if !self.snapshot.repositories.contains(where: { $0.repository == repo }) { self.snapshot.repositories.append(GitHubRepositoryState(repository: repo)) }
            }
            for index in self.snapshot.repositories.indices {
                self.snapshot.repositories[index].error = "Refreshing"
                self.snapshot.repositories[index].webhookURL = nil; self.snapshot.repositories[index].webhookError = nil
            }
            self.publish()
            if !self.config.webhooksEnabled {
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + self.pollInterval, repeating: self.pollInterval,
                    leeway: .milliseconds(Int(min(10, self.pollInterval / 10) * 1000)))
                timer.setEventHandler { [weak self] in
                    guard let self, self.active else { return }
                    self.settling.removeAll()
                    self.enqueue(Set(self.config.repositories), delay: 0)
                }
                self.pollTimer = timer; timer.resume()
                self.enqueue(Set(self.config.repositories), delay: 0)
                return
            }
            let server = GitHubWebhookServer(port: self.config.port, handle: { [weak self] request in self?.receive(request) ?? 503 }, state: { [weak self] ready, error in
                self?.queue.async { [weak self] in
                    guard let self, self.active else { return }
                    self.snapshot.receiverReady = ready
                    if let error { self.snapshot.tunnelError = error }
                    self.publish()
                    if ready { self.startTunnel() }
                }
            })
            self.server = server
            do { try server.start() } catch { self.snapshot.tunnelError = error.localizedDescription; self.publish() }
            self.enqueue(Set(self.config.repositories), delay: 0)
        }
    }
    public func stop() {
        queue.sync {
            active = false; scheduled?.cancel(); scheduled = nil; pending.removeAll()
            pollTimer?.cancel(); pollTimer = nil
            server?.stop(); server = nil; tunnel?.stop(); tunnel = nil
            snapshot.receiverReady = false; snapshot.tunnelURL = nil; snapshot.tunnelError = "GitHub tracking stopped"
            try? GitHubStore.saveSnapshot(snapshot, at: directory)
        }
    }
    public func refresh(reconnect: Bool = false) {
        queue.async { [weak self] in
            guard let self, self.active else { return }
            self.settling.removeAll()
            if reconnect, self.config.webhooksEnabled, self.snapshot.receiverReady { self.startTunnel() }
            self.enqueue(Set(self.config.repositories), delay: 0)
        }
    }
    private func startTunnel() {
        tunnel?.stop()
        snapshot.tunnelURL = nil; snapshot.tunnelError = "Connecting ngrok"; publish()
        let tunnel = NgrokTunnel(port: config.port, url: config.publicURL) { [weak self] url, error in
            self?.queue.async { [weak self] in
                guard let self, self.active else { return }
                self.snapshot.tunnelURL = url; self.snapshot.tunnelError = error; self.publish()
                if let url { self.synchronizeWebhooks(endpoint: url); self.enqueue(Set(self.config.repositories), delay: 1) }
            }
        }
        self.tunnel = tunnel; tunnel.start()
    }
    private func synchronizeWebhooks(endpoint: String) {
        for repository in config.repositories {
            guard let id = config.hookIDs[repository] else { continue }
            Self.webhookQueue.async { [weak self] in
                guard let self, self.queue.sync(execute: { self.active && self.snapshot.tunnelURL == endpoint }) else { return }
                let result = Result { try self.client.installWebhook(repository: repository, endpoint: endpoint, secret: self.config.secret, knownID: id, createIfMissing: false) }
                self.queue.async { [weak self] in
                    guard let self, self.active, self.snapshot.tunnelURL == endpoint,
                          let index = self.snapshot.repositories.firstIndex(where: { $0.repository == repository }) else { return }
                    switch result {
                    case .success:
                        self.snapshot.repositories[index].webhookURL = endpoint
                        self.snapshot.repositories[index].webhookError = nil
                        self.enqueue([repository], delay: 0)
                    case .failure:
                        self.snapshot.repositories[index].webhookURL = nil
                        self.snapshot.repositories[index].webhookError = "Could not connect the repository webhook. Check gh access, then Refresh."
                    }
                    self.publish()
                }
            }
        }
    }
    private func receive(_ request: WebhookRequest) -> Int {
        if request.method == "GET", request.path == "/healthz" { return 200 }
        guard request.path == "/github/webhook" else { return 404 }
        guard request.method == "POST" else { return 405 }
        guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else { return 415 }
        guard WebhookSecurity.validSignature(request.headers["x-hub-signature-256"], body: request.body, secret: config.secret) else { return 401 }
        guard let event = request.headers["x-github-event"], let delivery = request.headers["x-github-delivery"],
              !delivery.isEmpty, delivery.count <= 128 else { return 400 }
        guard (try? JSONSerialization.jsonObject(with: request.body)) is [String: Any] else { return 400 }
        return queue.sync {
            guard active else { return 503 }
            if deliveries.contains(delivery) { return 202 }
            deliveries.insert(delivery); deliveryOrder.append(delivery)
            if deliveryOrder.count > 1024 { deliveries.remove(deliveryOrder.removeFirst()) }
            snapshot.lastWebhook = Date()
            if let repository = WebhookSecurity.relevantRepository(event: event, body: request.body, config: config, snapshot: snapshot) {
                settling[repository] = 0; enqueue([repository], delay: 2)
            }
            // Busy repositories emit checks for everyone's PRs. Acknowledge
            // those quietly: only refreshed canonical data repaints the board.
            // Ping is rare and useful for diagnostics, so persist its timestamp
            // without producing UI work or a GitHub API request.
            if event == "ping" { try? GitHubStore.saveSnapshot(snapshot, at: directory) }
            return 202
        }
    }
    private func enqueue(_ repos: Set<String>, delay: TimeInterval) {
        pending.formUnion(repos)
        guard !fetching else { return }
        if scheduled != nil, delay > 0 { return }
        scheduled?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.next() }; scheduled = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }
    private func next() {
        scheduled = nil
        guard active, !fetching, let repository = pending.sorted().first else { return }
        pending.remove(repository); fetching = true
        let old = snapshot.repositories.first { $0.repository == repository } ?? GitHubRepositoryState(repository: repository)
        let hookID = !config.webhooksEnabled && !disabledHooks.contains(repository) ? config.hookIDs[repository] : nil
        worker.async { [weak self] in
            guard let self, self.queue.sync(execute: { self.active }) else { return }
            // Stop delivery at GitHub, before it can consume tunnel quota.
            // Only the hook ID recorded by this installation may be changed.
            let hookResult = hookID.map { id in
                Self.webhookQueue.sync {
                    Result { try self.disableWebhook(repository, id) }
                }
            }
            guard self.queue.sync(execute: { self.active }) else { return }
            let result = Result { try self.refreshRepository(repository, self.config.login, old, self.config.manualStacks) }
            self.queue.async { [weak self] in
                guard let self, self.active else { return }; self.fetching = false
                if let index = self.snapshot.repositories.firstIndex(where: { $0.repository == repository }) {
                    if let hookResult {
                        switch hookResult {
                        case .success:
                            self.disabledHooks.insert(repository)
                            self.snapshot.repositories[index].webhookError = nil
                        case .failure:
                            self.snapshot.repositories[index].webhookError = "Could not deactivate the old webhook. Check gh webhook administration access, then Refresh."
                        }
                    }
                    switch result {
                    case .success(var repo):
                        repo.webhookURL = self.snapshot.repositories[index].webhookURL
                        repo.webhookError = self.snapshot.repositories[index].webhookError
                        self.snapshot.repositories[index] = repo
                        if repo.pullRequests.contains(where: { $0.health == .unknown }), self.settling[repository, default: 0] < 2 {
                            self.settling[repository, default: 0] += 1
                            self.pending.insert(repository)
                        }
                    case .failure(let error): self.snapshot.repositories[index].error = error.localizedDescription
                    }
                }
                self.publish()
                if !self.pending.isEmpty { self.enqueue([], delay: 2) }
            }
        }
    }
    private func publish() {
        do { try GitHubStore.saveSnapshot(snapshot, at: directory) } catch { NSLog("clawdex: could not save GitHub cache") }
        let value = snapshot; DispatchQueue.main.async { [weak self] in self?.onChange(value) }
    }
}

/// The daemon owns exactly one ngrok child. No extra launchd agent, token copy,
/// or public listener is needed. The user's standard ngrok config supplies auth.
private final class NgrokTunnel {
    private let port: UInt16
    private let url: String?
    private let queue = DispatchQueue(label: "clawdex.github.ngrok")
    private var process: Process?
    private var output: Pipe?
    private var buffer = Data()
    private var stopped = false
    private var retry: DispatchWorkItem?
    private var backoff: Double = 5
    private var lastError: String?
    private let update: (String?, String?) -> Void
    init(port: UInt16, url: String?, update: @escaping (String?, String?) -> Void) { self.port = port; self.url = url; self.update = update }
    func start() { queue.async { [weak self] in self?.launch() } }
    func stop() {
        queue.sync {
            stopped = true; retry?.cancel(); retry = nil
            output?.fileHandleForReading.readabilityHandler = nil
            if let process, process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
            }
            process = nil; output = nil
        }
    }
    private func launch() {
        guard !stopped else { return }
        guard let executable = ToolProcess.executable("ngrok") else { update(nil, "Install ngrok, then refresh GitHub"); return }
        buffer.removeAll()
        lastError = nil
        let process = Process(); process.executableURL = executable
        var arguments = ["http", "http://127.0.0.1:\(port)", "--inspect=false", "--log", "stdout", "--log-format", "json"]
        if let url { arguments += ["--url", url] }
        process.arguments = arguments; process.standardInput = FileHandle.nullDevice
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        self.process = process; output = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async { [weak self] in self?.consume(data) }
        }
        process.terminationHandler = { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, !self.stopped else { return }
                self.output?.fileHandleForReading.readabilityHandler = nil
                self.update(nil, self.lastError ?? "Ngrok disconnected. Check its local configuration, then Refresh.")
                let task = DispatchWorkItem { [weak self] in self?.launch() }; self.retry = task
                self.queue.asyncAfter(deadline: .now() + self.backoff, execute: task); self.backoff = min(60, self.backoff * 2)
            }
        }
        do { try process.run() } catch { update(nil, "Could not start ngrok") }
    }
    private func consume(_ data: Data) {
        guard !stopped, !data.isEmpty else { return }; buffer.append(data)
        guard buffer.count < 128 << 10 else { buffer.removeAll(); return }
        while let newline = buffer.firstIndex(of: 0x0a) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            switch NgrokLogEvent.parse(line) {
            case .connected(let url): backoff = 5; lastError = nil; update(url, nil)
            case .problem(let message): lastError = message; update(nil, message)
            case nil: break
            }
        }
    }
}

enum NgrokLogEvent: Equatable {
    case connected(String)
    case problem(String)
    static func parse(_ line: Data) -> NgrokLogEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        if object["msg"] as? String == "started tunnel", let text = object["url"] as? String,
           let endpoint = PRReference.publicEndpoint(text) { return .connected(endpoint.absoluteString) }
        guard let error = object["err"] as? String else { return nil }
        // Error text can include account identifiers or credentials. Display
        // fixed guidance by code, never persist the raw provider response.
        if error.contains("ERR_NGROK_123") { return .problem("Verify your ngrok account email at dashboard.ngrok.com/user/settings, then Refresh.") }
        if error.contains("ERR_NGROK_4018") || error.contains("ERR_NGROK_105") { return .problem("Configure a valid ngrok auth token locally, then Refresh.") }
        if error.contains("ERR_NGROK_334") { return .problem("This ngrok URL is already in use by another tunnel.") }
        if error.contains("ERR_NGROK_313") { return .problem("This URL cannot be reused on your ngrok plan. Select the assigned domain or run github setup with --auto-url.") }
        if error.contains("ERR_NGROK_108") { return .problem("Ngrok's simultaneous agent limit was reached. Check other running agents.") }
        return nil
    }
}
