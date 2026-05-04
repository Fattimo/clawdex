import Foundation

struct PetManifest: Codable, Equatable {
    let id: String
    let displayName: String
    let description: String?
    let spritesheetPath: String

    static func load(directory: URL) throws -> (PetManifest, URL) {
        let manifestURL = directory.appendingPathComponent("pet.json")
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(PetManifest.self, from: data)
        let sheetURL = directory.appendingPathComponent(manifest.spritesheetPath)
        return (manifest, sheetURL)
    }
}

struct PetLibrary {
    /// Searches the Codex-canonical path first, then a clawdex-only fallback,
    /// so users who already have Codex installed see their existing pets
    /// without a second install step.
    static func searchPaths() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .flatMap { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".codex")
        return [
            codexHome.appendingPathComponent("pets"),
            home.appendingPathComponent(".clawdex/pets")
        ]
    }

    static func discover() -> [(PetManifest, URL)] {
        var results: [(PetManifest, URL)] = []
        var seen = Set<String>()
        let fm = FileManager.default
        for root in searchPaths() {
            guard let entries = try? fm.contentsOfDirectory(at: root,
                                                            includingPropertiesForKeys: [.isDirectoryKey],
                                                            options: [.skipsHiddenFiles]) else { continue }
            for entry in entries {
                guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                guard let (manifest, sheet) = try? PetManifest.load(directory: entry) else { continue }
                guard fm.fileExists(atPath: sheet.path) else { continue }
                if seen.insert(manifest.id).inserted {
                    results.append((manifest, sheet))
                }
            }
        }
        return results.sorted { $0.0.displayName < $1.0.displayName }
    }
}
