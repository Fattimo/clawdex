import Foundation
import Darwin

/// Codex's shared server can inherit KITTY_WINDOW_ID from a different CLI.
/// Locate the actual foreground client instead of trusting that inherited ID.
enum KittySessionResolver {
    struct Client: Equatable {
        var window: String
        var processID: Int
        var agent: String
        var root: String
        var emptyPromptObservedAt: Date? = nil
        var resumeThreadID: String = ""
        var resumeTranscriptPath: String = ""
        var identity: String { window + ":" + String(processID) }
    }

    /// Codex can clear its TUI without emitting a lifecycle hook. Recognize
    /// only its empty welcome screen, never a finished answer or tool output.
    static func isEmptyCodexPrompt(_ data: Data, root: String) -> Bool {
        guard data.count <= 262_144, let text = String(data: data, encoding: .utf8) else { return false }
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard lines.count >= 4, lines[0].hasPrefix(">_ OpenAI Codex (v"), lines[0].hasSuffix(")"),
              lines[1].hasPrefix("/") || lines[1].hasPrefix("~/"),
              projectRoot((lines[1] as NSString).expandingTildeInPath) == projectRoot(root),
              let prompt = lines.firstIndex(of: "› Ask Codex to do anything"), prompt > 1,
              lines.filter({ $0.hasPrefix("›") }).count == 1 else { return false }
        let help = ["To get started, describe a task or try one of these commands:",
                    "/init - ", "/status - ", "/permissions - ", "/model - ", "/review - "]
        return lines[2..<prompt].allSatisfy { line in
            help.contains(where: { line.hasPrefix($0) }) || line.unicodeScalars.allSatisfy {
                CharacterSet.whitespaces.contains($0) || (0x2800...0x28FF).contains($0.value)
            }
        }
    }

    /// Local client presence exists before Codex sends its first hook.
    static func clients(in data: Data, launchDirectory: (Int) -> String? = launchDirectory(pid:)) -> [Client]? {
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
                // Claude chdirs into whatever repo it is working in; name the
                // session after where it was launched, matching its hooks.
                let home = agent == "claude" ? (launchDirectory(pid) ?? cwd) : cwd
                var client = Client(window: String(id), processID: pid, agent: agent, root: projectRoot(home))
                if agent == "codex", let resume = command.firstIndex(of: "resume"), resume + 1 < command.count,
                   UUID(uuidString: command[resume + 1]) != nil {
                    client.resumeThreadID = command[resume + 1].lowercased()
                }
                result.append(client)
            }
        }
        return Array(Set(result.map(\.identity))).compactMap { id in result.first { $0.identity == id } }
            .sorted { $0.identity < $1.identity }
    }

    /// The directory a process was started in: `PWD` from its exec-time
    /// environment (KERN_PROCARGS2, same-user processes only). Nil unless it
    /// names an existing absolute directory.
    static func launchDirectory(pid: Int) -> String? {
        guard pid > 0, pid <= Int(Int32.max) else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size, size <= 1 << 20 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size, size <= buffer.count else { return nil }
        return launchDirectory(procargs: Array(buffer[..<size]))
    }

    /// Parses a KERN_PROCARGS2 buffer: argc, exec path, padding NULs, argv,
    /// then environment strings. Bounds-checked throughout.
    static func launchDirectory(procargs: [UInt8]) -> String? {
        let header = MemoryLayout<Int32>.size
        guard procargs.count > header else { return nil }
        let argc = procargs[0..<header].withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 0, argc < 4096 else { return nil }
        var index = header
        func skipString() { while index < procargs.count, procargs[index] != 0 { index += 1 } }
        func skipNULs() { while index < procargs.count, procargs[index] == 0 { index += 1 } }
        skipString(); skipNULs()                         // exec path + padding
        for _ in 0..<argc { skipString(); index += 1 }   // argv
        let prefix = Array("PWD=".utf8)
        while index < procargs.count, procargs[index] != 0 {
            let start = index
            skipString()
            let entry = procargs[start..<index]
            index += 1
            guard entry.starts(with: prefix),
                  let path = String(bytes: entry.dropFirst(prefix.count), encoding: .utf8),
                  path.hasPrefix("/"), path != "/" else { continue }
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue ? path : nil
        }
        return nil
    }

    static func transcriptPath(for threadID: String, sessionsDirectory: URL? = nil) -> String? {
        guard UUID(uuidString: threadID) != nil else { return nil }
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
        let root = sessionsDirectory ?? URL(fileURLWithPath: home).appendingPathComponent("sessions")
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        var visited = 0
        while let file = files.nextObject() as? URL, visited < 20_000 {
            visited += 1
            if file.lastPathComponent.lowercased().hasSuffix("-" + threadID.lowercased() + ".jsonl") { return file.path }
        }
        return nil
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
