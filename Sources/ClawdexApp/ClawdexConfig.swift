import Foundation

enum MessageVisibility: String, Codable, CaseIterable {
    case all
    case finalOnly
    case none
}

struct ClawdexConfig: Codable, Equatable {
    var messageVisibility: MessageVisibility = .all
    var showSwitchboard: Bool = true
    var petScale: CGFloat = 0.75

    static let defaultPath = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".clawdex/config.json")

    static func load(from path: URL = defaultPath) throws -> ClawdexConfig {
        let data = try Data(contentsOf: path)
        return try JSONDecoder().decode(ClawdexConfig.self, from: data)
    }

    func save(to path: URL = defaultPath) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(self)
        try data.write(to: path, options: .atomic)
    }
}
