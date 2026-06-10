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

    /// Where the daemon records the user's last `select` so it survives
    /// restarts and reinstalls (as long as ~/.clawdex isn't wiped). Lives
    /// outside ~/.codex/pets so reinstalling pets doesn't clobber it.
    static func preferenceURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".clawdex/selected")
    }

    /// Persisted pet id from a prior `select`, or nil if none/unreadable.
    static func loadPreference() -> String? {
        guard let raw = try? String(contentsOf: preferenceURL(), encoding: .utf8) else { return nil }
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    /// Records the preferred pet id, creating ~/.clawdex if needed. Best-effort:
    /// a write failure shouldn't break the live `select`.
    static func savePreference(id: String) {
        let url = preferenceURL()
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        try? id.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The pet to load on startup: the saved preference if it still resolves to
    /// an installed pet, otherwise the alphabetically-first discovered pet.
    static func preferred() -> (PetManifest, URL)? {
        let pets = discover()
        if let id = loadPreference(), let match = pets.first(where: { $0.0.id == id }) {
            return match
        }
        return pets.first
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
