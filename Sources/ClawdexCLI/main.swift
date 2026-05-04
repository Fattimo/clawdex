import Foundation
import Darwin

// clawdex CLI — sends control commands to the running clawdexd daemon over its
// Unix socket. Subcommands:
//   clawdex wake             — show the pet.
//   clawdex tuck             — hide the pet.
//   clawdex select <id>      — switch to a pet by id (folder name).
//   clawdex list             — print discovered pets and exit.
//   clawdex which            — print active pet (placeholder; daemon doesn't yet report).

let args = CommandLine.arguments

guard args.count >= 2 else {
    print("""
    clawdex — Codex-pet companion for Claude Code

    Usage:
      clawdex wake              show the pet
      clawdex tuck              hide the pet
      clawdex select <id>       switch to pet <id> (folder name under ~/.codex/pets)
      clawdex list              list discovered pets
    """)
    exit(2)
}

let cmd = args[1]

func sockPath() -> String {
    if let env = ProcessInfo.processInfo.environment["CLAWDEX_SOCK"] { return env }
    return NSHomeDirectory() + "/.clawdex/sock"
}

func send(_ payload: [String: Any]) {
    let path = sockPath()
    guard FileManager.default.fileExists(atPath: path) else {
        FileHandle.standardError.write("clawdex: daemon not running (no socket at \(path))\n".data(using: .utf8)!)
        exit(1)
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { exit(1) }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in buf.copyBytes(from: bytes) }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saddr in
            Darwin.connect(fd, saddr, size)
        }
    }
    guard rc == 0 else { exit(1) }
    var data = try! JSONSerialization.data(withJSONObject: payload)
    data.append(0x0a)
    _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
}

func discover() -> [(String, String, URL)] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        .flatMap { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
    let roots = [codexHome.appendingPathComponent("pets"),
                 home.appendingPathComponent(".clawdex/pets")]
    var seen = Set<String>()
    var out: [(String, String, URL)] = []
    for root in roots {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { continue }
        for name in entries {
            let dir = root.appendingPathComponent(name)
            let manifest = dir.appendingPathComponent("pet.json")
            guard let data = try? Data(contentsOf: manifest),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = obj["id"] as? String,
                  let display = obj["displayName"] as? String else { continue }
            if seen.insert(id).inserted { out.append((id, display, root)) }
        }
    }
    return out.sorted { $0.0 < $1.0 }
}

switch cmd {
case "wake":
    send(["control": "wake"])
case "tuck":
    send(["control": "tuck"])
case "select":
    guard args.count >= 3 else {
        FileHandle.standardError.write("clawdex: usage: clawdex select <id>\n".data(using: .utf8)!)
        exit(2)
    }
    send(["control": "select", "id": args[2]])
case "list":
    let pets = discover()
    if pets.isEmpty {
        print("(no pets found in ~/.codex/pets or ~/.clawdex/pets)")
    } else {
        for (id, display, root) in pets {
            print("\(id)\t\(display)\t\(root.path)/\(id)")
        }
    }
default:
    FileHandle.standardError.write("clawdex: unknown command \(cmd)\n".data(using: .utf8)!)
    exit(2)
}
