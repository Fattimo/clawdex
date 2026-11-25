import Foundation

enum MessageVisibility: String, Codable, CaseIterable {
    case all
    case finalOnly
    case none
}

struct ClawdexConfig: Codable, Equatable {
    var messageVisibility: MessageVisibility = .all
    var pinnedWorkspaces: [String] = []
    var showSwitchboard: Bool = true
    var petScale: CGFloat = 0.75
    var showGitHubSwitchboard: Bool = true
    var showMouseTrail: Bool = false

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

extension ClawdexConfig {
    private enum CodingKeys: String, CodingKey { case pinnedWorkspaces, messageVisibility, showSwitchboard, petScale, showGitHubSwitchboard, showMouseTrail }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let pins = try values.decodeIfPresent([String].self, forKey: .pinnedWorkspaces) ?? []
        var seen = Set<String>()
        pinnedWorkspaces = pins.filter { !$0.isEmpty && seen.insert($0).inserted }
        messageVisibility = try values.decodeIfPresent(MessageVisibility.self, forKey: .messageVisibility) ?? .all
        showSwitchboard = try values.decodeIfPresent(Bool.self, forKey: .showSwitchboard) ?? true
        petScale = try values.decodeIfPresent(CGFloat.self, forKey: .petScale) ?? 0.75
        showGitHubSwitchboard = try values.decodeIfPresent(Bool.self, forKey: .showGitHubSwitchboard) ?? true
        showMouseTrail = try values.decodeIfPresent(Bool.self, forKey: .showMouseTrail) ?? false
    }
}
