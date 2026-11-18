import Foundation

/// A Wine installation Cellar can run bottles with.
struct WineEngine: Identifiable, Hashable {
    let name: String
    let path: String
    let isCustom: Bool

    var id: String { path }
    var binDirectory: URL { URL(fileURLWithPath: path).deletingLastPathComponent() }
}

/// Finds Wine builds in the usual places, plus any you add by hand.
@MainActor
final class EngineStore: ObservableObject {
    @Published private(set) var engines: [WineEngine] = []
    @Published private(set) var versions: [String: String] = [:]

    private let customKey = "customEnginePaths"

    init() { refresh() }

    var customPaths: [String] {
        UserDefaults.standard.stringArray(forKey: customKey) ?? []
    }

    func refresh() {
        var found: [WineEngine] = []
        var seen = Set<String>()

        func add(_ name: String, _ path: String, custom: Bool = false) {
            guard FileManager.default.isExecutableFile(atPath: path) else { return }
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard !seen.contains(resolved) else { return }
            seen.insert(resolved)
            found.append(WineEngine(name: name, path: path, isCustom: custom))
        }

        // Wine .app bundles (Gcenx builds, WineHQ-style packages) in /Applications and ~/Applications.
        let appDirs = ["/Applications", NSHomeDirectory() + "/Applications"]
        for dir in appDirs {
            let apps = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            for app in apps.sorted() where app.hasSuffix(".app") && app.lowercased().hasPrefix("wine") {
                let bin = "\(dir)/\(app)/Contents/Resources/wine/bin"
                let name = String(app.dropLast(4))
                // Older macOS builds use wine64 for 64-bit; newer WoW64 builds ship a single `wine`.
                if FileManager.default.isExecutableFile(atPath: bin + "/wine64") {
                    add(name, bin + "/wine64")
                } else {
                    add(name, bin + "/wine")
                }
            }
        }

        // Cuvee (open source) ships a Wine built from CrossOver's public sources, with DXMT.
        for dir in appDirs {
            add("CrossOver-source Wine (from Cuvee)",
                "\(dir)/Cuvee.app/Contents/Resources/runtime/dist/bin/wine")
        }

        // Apple's Game Porting Toolkit (brew-built) and Homebrew-linked wine binaries.
        add("Game Porting Toolkit", "/usr/local/opt/game-porting-toolkit/bin/wine64")
        for prefix in ["/opt/homebrew/bin", "/usr/local/bin"] {
            add("Wine (\(prefix))", prefix + "/wine64")
            add("Wine (\(prefix))", prefix + "/wine")
        }

        for path in customPaths {
            add(URL(fileURLWithPath: path).deletingLastPathComponent()
                    .deletingLastPathComponent().lastPathComponent + " (custom)",
                path, custom: true)
        }

        engines = found
        for engine in found where versions[engine.path] == nil {
            loadVersion(engine.path)
        }
    }

    func addCustom(path: String) {
        var paths = customPaths
        if !paths.contains(path) { paths.append(path) }
        UserDefaults.standard.set(paths, forKey: customKey)
        refresh()
    }

    func removeCustom(path: String) {
        UserDefaults.standard.set(customPaths.filter { $0 != path }, forKey: customKey)
        refresh()
    }

    func name(for path: String) -> String {
        engines.first { $0.path == path }?.name ?? URL(fileURLWithPath: path).lastPathComponent
    }

    private func loadVersion(_ path: String) {
        Task { [weak self] in
            let result = await Task.detached { EngineStore.readVersion(path) }.value
            self?.versions[path] = result
        }
    }

    nonisolated private static func readVersion(_ path: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["--version"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let s = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? "unknown version" : s
        } catch {
            return "won't start: \(error.localizedDescription)"
        }
    }
}

/// Apple Silicon Macs need Rosetta 2 to run Wine's x86_64 binaries.
enum SystemCheck {
    static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    static var rosettaInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
    }

    static var winetricksPath: String? {
        ["/opt/homebrew/bin/winetricks", "/usr/local/bin/winetricks"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// Facts about a Wine engine that change how Cellar drives it.
enum EngineInfo {
    /// The folder that holds the engine's bin/ and lib/.
    static func root(enginePath: String) -> URL {
        URL(fileURLWithPath: enginePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// A DXMT that ships inside the engine in its own lib/dxmt folder, the layout CrossOver uses.
    /// Engines like this load it through WINEDLLPATH_PREPEND, so nothing has to be installed.
    static func bundledDXMT(enginePath: String) -> URL? {
        let dir = root(enginePath: enginePath).appendingPathComponent("lib/dxmt", isDirectory: true)
        let driver = dir.appendingPathComponent("x86_64-unix/winemetal.so")
        return FileManager.default.fileExists(atPath: driver.path) ? dir : nil
    }

    /// Cellar's own DirectX 12 runtime (VKD3D-Proton, DXVK's dxgi and a matching MoltenVK).
    /// Only engines with the DLL-path patch can use it, which are the ones with a bundled DXMT.
    static var bundledD3D12: URL? {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("d3d12", isDirectory: true) else { return nil }
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.appendingPathComponent("x86_64-windows/d3d12.dll").path),
              fm.fileExists(atPath: dir.appendingPathComponent("moltenvk/libMoltenVK.dylib").path),
              fm.fileExists(atPath: dir.appendingPathComponent("moltenvk/libmetalirconverter.dylib").path)
        else { return nil }
        return dir
    }

    /// CrossOver-source builds patch Wine so Steam's window draws without outside help.
    static func handlesSteamWindow(enginePath: String) -> Bool {
        bundledDXMT(enginePath: enginePath) != nil
    }
}
