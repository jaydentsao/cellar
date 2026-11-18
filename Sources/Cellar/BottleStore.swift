import Foundation

/// Loads, saves, creates and trashes bottles under ~/Library/Application Support/Cellar/Bottles.
@MainActor
final class BottleStore: ObservableObject {
    @Published private(set) var bottles: [Bottle] = []
    let root: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("Cellar/Bottles", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root,
                                                includingPropertiesForKeys: [.isDirectoryKey],
                                                options: [.skipsHiddenFiles])) ?? []
        bottles = dirs.compactMap { dir -> Bottle? in
            let cfgURL = dir.appendingPathComponent(Bottle.configFileName)
            guard let data = try? Data(contentsOf: cfgURL),
                  let cfg = try? JSONDecoder.cellar.decode(BottleConfig.self, from: data)
            else { return nil }
            return Bottle(url: dir, config: cfg)
        }
        .sorted { $0.config.name.localizedCaseInsensitiveCompare($1.config.name) == .orderedAscending }
    }

    func bottle(_ url: URL) -> Bottle? {
        bottles.first { $0.url == url }
    }

    func save(_ bottle: Bottle) throws {
        let data = try JSONEncoder.cellar.encode(bottle.config)
        try data.write(to: bottle.configURL, options: .atomic)
        if let i = bottles.firstIndex(where: { $0.url == bottle.url }) {
            bottles[i] = bottle
        } else {
            bottles.append(bottle)
            bottles.sort { $0.config.name.localizedCaseInsensitiveCompare($1.config.name) == .orderedAscending }
        }
    }

    /// Creates the folder, writes cellar.json, runs `wineboot --init`, then applies registry settings.
    func create(config: BottleConfig, runner: WineRunner) async throws -> Bottle {
        let url = uniqueFolder(for: config.name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let bottle = Bottle(url: url, config: config)
        try save(bottle)

        let code = await runner.runAndWait(bottle: bottle,
                                           arguments: ["wineboot", "--init"],
                                           label: "Create bottle")
        if code != 0 {
            throw CellarError.wine("wineboot exited with code \(code). The Log tab has Wine's output.")
        }
        await runner.applyRegistrySettings(bottle: bottle)
        return bottle
    }

    /// Moves the bottle to the macOS Trash so it can be recovered.
    func moveToTrash(_ bottle: Bottle) throws {
        try FileManager.default.trashItem(at: bottle.url, resultingItemURL: nil)
        bottles.removeAll { $0.url == bottle.url }
    }

    private func uniqueFolder(for name: String) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        var slug = String(name.unicodeScalars.filter { allowed.contains($0) })
            .trimmingCharacters(in: .whitespaces)
        if slug.isEmpty { slug = "Bottle" }
        var candidate = root.appendingPathComponent(slug, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(slug) \(n)", isDirectory: true)
            n += 1
        }
        return candidate
    }
}
