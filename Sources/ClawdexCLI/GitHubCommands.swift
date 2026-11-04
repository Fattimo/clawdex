import Foundation
import ClawdexGitHub

enum GitHubCommands {
    static func run(_ args: [String], send: ([String: Any]) -> Void) throws {
        guard let verb = args.first else { printHelp(); return }
        switch verb {
        case "setup":
            var values = Array(args.dropFirst()); var endpoint: String?
            let autoURL = values.contains("--auto-url"); values.removeAll { $0 == "--auto-url" }
            if let index = values.firstIndex(of: "--url") {
                guard values.indices.contains(index + 1), let url = PRReference.publicEndpoint(values[index + 1]) else { throw GitHubError.message("--url requires a public HTTPS endpoint") }
                endpoint = url.absoluteString; values.removeSubrange(index...index + 1)
            }
            guard !values.isEmpty, values.allSatisfy(PRReference.validRepository) else { throw GitHubError.message("Usage: clawdex github setup owner/repo [owner/repo ...] [--url https://your-domain]") }
            var config: GitHubConfig
            if FileManager.default.fileExists(atPath: GitHubStore.directory.appendingPathComponent("config.json").path) { config = try GitHubStore.loadConfig() }
            else { config = try GitHubConfig() }
            config.login = try GitHubClient().login(); config.repositories = Array(Set(values.map { $0.lowercased() })).sorted()
            config.manualStacks = config.manualStacks.filter { config.repositories.contains($0.repository) }
            if let endpoint { config.publicURL = endpoint }
            else if autoURL { config.publicURL = nil }
            config.enabled = true; try GitHubStore.saveConfig(config); send(["control": "github-reload"])
            print("GitHub tracking enabled for \(config.repositories.joined(separator: ", ")).")
            print("The daemon starts ngrok using its standard local auth configuration.")
            print("Once connected: clawdex github hook \(config.repositories[0])")
        case "status":
            guard let config = try? GitHubStore.loadConfig() else { print("GitHub is not configured. Run: clawdex github setup owner/repo"); return }
            let state = GitHubStore.loadSnapshot()
            print("GitHub: \(config.enabled ? "enabled" : "disabled") · \(config.login)")
            print("Receiver: \(state.receiverReady ? "listening" : "offline") on 127.0.0.1:\(config.port)")
            print("Webhook URL: \(state.tunnelURL.map { $0 + "/github/webhook" } ?? "not connected")")
            if let error = state.tunnelError { print(error) }
            for repo in config.repositories {
                print("\(repo): \(config.hookIDs[repo].map { "webhook #\($0) configured" } ?? "webhook not connected")")
                if let error = state.repositories.first(where: { $0.repository == repo })?.error { print("  Refresh error: \(error)") }
                if let error = state.repositories.first(where: { $0.repository == repo })?.webhookError { print("  Webhook error: \(error)") }
                if config.hookIDs[repo] != nil { print("  Webhook target: \(state.repositories.first(where: { $0.repository == repo })?.webhookURL ?? "reconnecting")") }
            }
            for stack in state.stacks(in: config) {
                print("\(stack.definition.id)\t\(stack.definition.name)\t\(stack.label)\t\(stack.definition.numbers.map { "#\($0)" }.joined(separator: " → "))")
            }
            if let date = state.lastWebhook { print("Last signed delivery: \(date)") }
        case "refresh": send(["control": "github-refresh"]); print("Refresh requested.")
        case "disable":
            var config = try GitHubStore.loadConfig(); config.enabled = false; try GitHubStore.saveConfig(config)
            send(["control": "github-reload"]); print("GitHub receiver and ngrok stopped. Repository webhook definitions are retained.")
        case "hook":
            guard args.count == 2 else { throw GitHubError.message("Usage: clawdex github hook owner/repo") }
            var config = try GitHubStore.loadConfig(); let repository = args[1].lowercased()
            guard config.enabled, config.repositories.contains(repository) else { throw GitHubError.message("Set up this repository first") }
            let snapshot = GitHubStore.loadSnapshot()
            guard snapshot.receiverReady, let endpoint = snapshot.tunnelURL, snapshot.tunnelError == nil else { throw GitHubError.message("Wait for ngrok to connect; check clawdex github status") }
            config.hookIDs[repository] = try GitHubClient().installWebhook(repository: repository, endpoint: endpoint, secret: config.secret, knownID: config.hookIDs[repository])
            try GitHubStore.saveConfig(config); send(["control": "github-reload"])
            print("Webhook configured for \(repository). Signed events now update its PR stacks.")
        case "track":
            guard args.count >= 3, !args[1].isEmpty, args[1].count <= 80 else { throw GitHubError.message("Usage: clawdex github track 'stack name' <PR URL> [PR URL ...], base first") }
            let refs = try args.dropFirst(2).map { try PRReference(url: $0) }
            guard Set(refs.map(\.repository)).count == 1, Set(refs).count == refs.count else { throw GitHubError.message("A stack needs distinct PRs from the same repository") }
            var config = try GitHubStore.loadConfig(); let repository = refs[0].repository
            guard config.repositories.contains(repository) else { throw GitHubError.message("Set up \(repository) first") }
            let id = "manual:" + UUID().uuidString
            config.manualStacks.append(StackDefinition(id: id, name: args[1], repository: repository, numbers: refs.map(\.number)))
            try GitHubStore.saveConfig(config); send(["control": "github-reload"]); print("Tracking \(args[1]): \(id)")
        case "hide", "show":
            guard args.count == 2 else { throw GitHubError.message("Usage: clawdex github \(verb) <stack-id>; IDs appear in github status") }
            var config = try GitHubStore.loadConfig()
            config.hiddenStacks.removeAll { $0 == args[1] }
            if verb == "hide" { config.hiddenStacks.append(args[1]) }
            try GitHubStore.saveConfig(config); send(["control": "github-reload"])
        default: printHelp()
        }
    }
    private static func printHelp() {
        print("""
        clawdex github setup owner/repo [--url https://your-ngrok-domain | --auto-url]
        clawdex github status
        clawdex github hook owner/repo       create/update this endpoint's webhook
        clawdex github refresh               refresh once and reconnect if needed
        clawdex github track 'name' <PR URLs in base-to-tip order>
        clawdex github hide|show <stack-id>
        clawdex github disable

        Setup reuses gh auth and ngrok's standard local auth config. No recurring
        GitHub polling: updates follow signed webhooks, login, wake and refresh.
        """)
    }
}
