import Foundation

/// Codex's shared server can inherit KITTY_WINDOW_ID from a different CLI.
/// Locate the actual foreground client instead of trusting that inherited ID.
enum KittySessionResolver {
    struct Client: Equatable {
        var window: String
        var processID: Int
        var agent: String
        var root: String
        var identity: String { window + ":" + String(processID) }
    }

    /// Local client presence exists before Codex sends its first hook.
    static func clients(in data: Data) -> [Client]? {
        guard let windows = windows(in: data) else { return nil }
        var result: [Client] = []
        for window in windows {
            guard let id = window["id"] as? Int, id > 0 else { continue }
            for process in window["foreground_processes"] as? [[String: Any]] ?? [] {
                guard let pid = process["pid"] as? Int, pid > 0,
                      let command = process["cmdline"] as? [String], let executable = command.first,
                      let cwd = process["cwd"] as? String, cwd.hasPrefix("/"), cwd != "/" else { continue }
                let agent = (executable as NSString).lastPathComponent
                guard ["claude", "codex"].contains(agent),
                      !command.dropFirst().contains(where: { ["app-server", "exec", "mcp-server", "--print", "-p"].contains($0) }) else { continue }
                result.append(Client(window: String(id), processID: pid, agent: agent, root: projectRoot(cwd)))
            }
        }
        return Array(Set(result.map(\.identity))).compactMap { id in result.first { $0.identity == id } }
            .sorted { $0.identity < $1.identity }
    }

    static func projectRoot(_ path: String) -> String {
        var directory = URL(fileURLWithPath: canonical(path))
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) { return directory.path }
            directory.deleteLastPathComponent()
        }
        return canonical(path)
    }

    /// Worktrees share a common Git directory, but unrelated clones do not.
    static func repositoryIdentity(_ root: String) -> String? {
        func smallText(_ url: URL) -> String? {
            guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? file.close() }
            guard let data = try? file.read(upToCount: 4097), data.count <= 4096 else { return nil }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let entry = URL(fileURLWithPath: canonical(root)).appendingPathComponent(".git")
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &directory) else { return nil }
        var git = entry
        if !directory.boolValue {
            guard let value = smallText(entry), value.hasPrefix("gitdir: ") else { return nil }
            git = URL(fileURLWithPath: String(value.dropFirst(8)), relativeTo: entry.deletingLastPathComponent()).standardizedFileURL
        }
        if let common = smallText(git.appendingPathComponent("commondir")), !common.isEmpty {
            git = URL(fileURLWithPath: common, relativeTo: URL(fileURLWithPath: git.path, isDirectory: true)).standardizedFileURL
        }
        return canonical(git.path)
    }

    static func codexWindow(in data: Data, root: String, clientPID: Int? = nil) -> String? {
        guard root.hasPrefix("/"), root != "/",
              let windows = windows(in: data) else { return nil }
        let root = canonical(root)
        var matches = Set<Int>()
        for window in windows {
            guard let id = window["id"] as? Int, id > 0,
                  let processes = window["foreground_processes"] as? [[String: Any]] else { continue }
            for process in processes {
                if let clientPID, process["pid"] as? Int != clientPID { continue }
                guard let command = process["cmdline"] as? [String],
                      let executable = command.first,
                      (executable as NSString).lastPathComponent == "codex",
                      !command.dropFirst().contains("app-server"),
                      let cwd = process["cwd"] as? String, cwd.hasPrefix("/") else { continue }
                let path = canonical(cwd)
                if path == root || path.hasPrefix(root + "/") { matches.insert(id) }
            }
        }
        // Two CLI clients in the same repo cannot be distinguished by cwd.
        // In particular, do not fall back to the server's inherited window ID.
        return matches.count == 1 ? matches.first.map(String.init) : nil
    }

    static func tabTitle(in data: Data, windowID: String) -> String? {
        guard let id = Int(windowID), id > 0,
              let osWindows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        for osWindow in osWindows {
            for tab in osWindow["tabs"] as? [[String: Any]] ?? [] {
                let windows = tab["windows"] as? [[String: Any]] ?? []
                if windows.contains(where: { ($0["id"] as? Int) == id }) {
                    return tab["title"] as? String
                }
            }
        }
        return nil
    }

    private static func windows(in data: Data) -> [[String: Any]]? {
        guard let osWindows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return osWindows.flatMap { $0["tabs"] as? [[String: Any]] ?? [] }
            .flatMap { $0["windows"] as? [[String: Any]] ?? [] }
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
