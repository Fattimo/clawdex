import Foundation

/// Codex pet animation rows. Authoritative source:
/// openai/skills/.curated/hatch-pet/references/animation-rows.md
/// Atlas: 1536x1872, 8 cols x 9 rows, 192x208 cell, transparent.
enum AnimationRow: Int, CaseIterable {
    case idle = 0
    case runningRight = 1
    case runningLeft = 2
    case waving = 3
    case jumping = 4
    case failed = 5
    case waiting = 6
    case running = 7
    case review = 8

    /// Per-frame duration in milliseconds. Length = column count (used cells).
    var frameDurationsMs: [Int] {
        switch self {
        case .idle:         return [280, 110, 110, 140, 140, 320]
        case .runningRight: return [120, 120, 120, 120, 120, 120, 120, 220]
        case .runningLeft:  return [120, 120, 120, 120, 120, 120, 120, 220]
        case .waving:       return [140, 140, 140, 280]
        case .jumping:      return [140, 140, 140, 140, 280]
        case .failed:       return [140, 140, 140, 140, 140, 140, 140, 240]
        case .waiting:      return [150, 150, 150, 150, 150, 260]
        case .running:      return [120, 120, 120, 120, 120, 220]
        case .review:       return [150, 150, 150, 150, 150, 280]
        }
    }

    var frameCount: Int { frameDurationsMs.count }

    /// Total ms for one full cycle. Used to time `transient` plays.
    var cycleDurationMs: Int { frameDurationsMs.reduce(0, +) }
}

enum AnimationConstants {
    static let columns = 8
    static let rows = 9
    static let cellWidth: CGFloat = 192
    static let cellHeight: CGFloat = 208
    static let atlasWidth: CGFloat = 1536
    static let atlasHeight: CGFloat = 1872
}
