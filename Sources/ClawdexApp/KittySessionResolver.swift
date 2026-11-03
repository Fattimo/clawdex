import Foundation

/// Codex's shared server can inherit KITTY_WINDOW_ID from a different CLI.
/// Locate the actual foreground client instead of trusting that inherited ID.
enum KittySessionResolver {
    static func codexWindow(in data: Data, root: String) -> String? {
        guard root.hasPrefix("/"), root != "/",
              let windows = windows(in: data) else { return nil }
        let root = canonical(root)
        var matches = Set<Int>()
        for window in windows {
            guard let id = window["id"] as? Int, id > 0,
                  let processes = window["foreground_processes"] as? [[String: Any]] else { continue }
            for process in processes {
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
