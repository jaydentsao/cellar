import Foundation
import CryptoKit

/// Copies a macOS DXVK build's DLLs into a bottle, backing up whatever was there first.
enum DXVKInstaller {
    static let markerName = ".cellar-dxvk"

    /// The name of the DXVK folder that was installed, or nil if none.
    static func installedVersion(in bottle: Bottle) -> String? {
        let marker = bottle.url.appendingPathComponent(markerName)
        guard let s = try? String(contentsOf: marker, encoding: .utf8) else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `folder` is an extracted DXVK release: the folder that contains `x64` (and usually `x32`).
    @discardableResult
    static func install(from folder: URL, into bottle: Bottle) throws -> String {
        let fm = FileManager.default
        let x64 = folder.appendingPathComponent("x64", isDirectory: true)
        let x32 = folder.appendingPathComponent("x32", isDirectory: true)
        guard fm.fileExists(atPath: x64.path) else {
            throw CellarError.dxvk("That folder has no x64 folder inside. Choose the extracted DXVK release folder, the one that contains x64 and x32.")
        }
        let windows = bottle.driveC.appendingPathComponent("windows", isDirectory: true)
        guard fm.fileExists(atPath: windows.path) else {
            throw CellarError.dxvk("This bottle hasn't been initialized yet. Use Tools → Update Bottle first.")
        }
        let backupRoot = bottle.url.appendingPathComponent(".cellar-backup/dxvk", isDirectory: true)

        var copied = 0
        for (source, destName) in [(x64, "system32"), (x32, "syswow64")] {
            guard fm.fileExists(atPath: source.path) else { continue }
            let dest = windows.appendingPathComponent(destName, isDirectory: true)
            guard fm.fileExists(atPath: dest.path) else { continue }
            let backup = backupRoot.appendingPathComponent(destName, isDirectory: true)
            try fm.createDirectory(at: backup, withIntermediateDirectories: true)

            let dlls = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "dll" }
            for dll in dlls {
                let target = dest.appendingPathComponent(dll.lastPathComponent)
                if fm.fileExists(atPath: target.path) {
                    let saved = backup.appendingPathComponent(dll.lastPathComponent)
                    // Keep the very first original; later reinstalls don't overwrite it.
                    if !fm.fileExists(atPath: saved.path) {
                        try fm.copyItem(at: target, to: saved)
                    }
                    try fm.removeItem(at: target)
                }
                try fm.copyItem(at: dll, to: target)
                copied += 1
            }
        }
        guard copied > 0 else {
            throw CellarError.dxvk("No DLLs were found to copy from \(folder.lastPathComponent).")
        }
        let label = folder.lastPathComponent
        try label.write(to: bottle.url.appendingPathComponent(markerName), atomically: true, encoding: .utf8)
        return label
    }
}

/// Known fixes applied automatically when a program is added.
enum ProgramPresets {
    /// Steam's interface is a built-in Chromium (steamwebhelper). Under Wine on macOS its GPU
    /// rendering fails, which leaves Steam with no window or a black one. These flags make it
    /// draw in software instead.
    /// -noverifyfiles stops Steam from restoring its original helper over Cellar's wrapper.
    static let steamArguments = "-no-cef-sandbox -cef-single-process -noverifyfiles"

    /// Deadlock's Steam app ID. Launching through Steam keeps VAC and matchmaking working.
    static let deadlockAppID = "1422450"
    /// The same path Steam's own Play button takes.
    static var deadlockArguments: String { "steam://rungameid/" + deadlockAppID }

    static func defaultArguments(for url: URL) -> String {
        url.lastPathComponent.lowercased() == "steam.exe" ? steamArguments : ""
    }
}

/// Looks through a bottle's Program Files for game executables.
enum ProgramScanner {
    private static let skipNames = ["unins", "setup", "install", "redist", "vcredist", "crash",
                                    "report", "update", "helper", "dxsetup", "dotnet", "directx",
                                    "prereq", "cleanup", "repair", "notification", "service",
                                    "overlay", "streaming", "webhelper", "errorreporter"]
    private static let skipFolders: Set<String> = ["Common Files", "Internet Explorer",
                                                   "Windows Media Player", "Windows NT",
                                                   "Windows Photo Viewer", "Microsoft.NET",
                                                   "Windows Defender", "Windows Mail"]

    static func scan(_ bottle: Bottle) -> [URL] {
        let fm = FileManager.default
        let roots = ["Program Files", "Program Files (x86)", "Games", "GOG Games"]
            .map { bottle.driveC.appendingPathComponent($0, isDirectory: true) }
        var results: [URL] = []
        for root in roots where fm.fileExists(atPath: root.path) {
            guard let e = fm.enumerator(at: root,
                                        includingPropertiesForKeys: [.isDirectoryKey],
                                        options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in e {
                if skipFolders.contains(url.lastPathComponent) {
                    e.skipDescendants()
                    continue
                }
                if e.level >= 5 { e.skipDescendants() }
                guard url.pathExtension.lowercased() == "exe" else { continue }
                let lower = url.lastPathComponent.lowercased()
                if skipNames.contains(where: { lower.contains($0) }) { continue }
                results.append(url)
            }
        }
        return results.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }
}

/// Downloads Valve's Windows Steam installer and locates the result.
enum SteamInstaller {
    static let setupURL = URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!

    static func steamExe(in bottle: Bottle) -> URL {
        bottle.driveC.appendingPathComponent("Program Files (x86)/Steam/steam.exe")
    }

    static func isInstalled(in bottle: Bottle) -> Bool {
        FileManager.default.fileExists(atPath: steamExe(in: bottle).path)
    }

    /// Saves SteamSetup.exe into the bottle's C: drive and returns its location.
    static func download(into bottle: Bottle) async throws -> URL {
        let (temp, response) = try await URLSession.shared.download(from: setupURL)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw CellarError.io("Couldn't download Steam's installer (HTTP \(status)). Check your internet connection.")
        }
        let fm = FileManager.default
        let size = ((try? fm.attributesOfItem(atPath: temp.path))?[.size] as? NSNumber)?.intValue ?? 0
        guard size > 500_000 else {
            throw CellarError.io("The Steam installer download looks incomplete (\(size) bytes).")
        }
        let dest = bottle.driveC.appendingPathComponent("SteamSetup.exe")
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: temp, to: dest)
        return dest
    }
}

/// Installs a DXMT release into a Wine engine (and the bottle), keeping the engine's originals.
enum DXMTInstaller {
    private static let markerName = ".cellar-dxmt"
    private static let manifestName = ".cellar-dxmt-files"
    private static let parts = ["x86_64-unix", "x86_64-windows", "i386-windows"]

    /// `<engine>/lib/wine`, where Wine keeps its own DLLs.
    static func libDirectory(enginePath: String) -> URL {
        URL(fileURLWithPath: enginePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lib/wine", isDirectory: true)
    }

    static func installedVersion(enginePath: String) -> String? {
        if EngineInfo.bundledDXMT(enginePath: enginePath) != nil { return "Built into this engine" }
        let marker = libDirectory(enginePath: enginePath).appendingPathComponent(markerName)
        guard let s = try? String(contentsOf: marker, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func find(_ name: String, under root: URL) -> URL? {
        if root.lastPathComponent == name { return root }
        guard let e = FileManager.default.enumerator(at: root,
                                                     includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles]) else { return nil }
        for case let url as URL in e {
            if e.level > 4 { e.skipDescendants(); continue }
            if url.lastPathComponent == name { return url }
        }
        return nil
    }

    /// `folder` is an extracted DXMT release (it contains x86_64-unix and x86_64-windows somewhere inside).
    @discardableResult
    static func install(from folder: URL, enginePath: String, bottle: Bottle) throws -> String {
        let fm = FileManager.default
        let lib = libDirectory(enginePath: enginePath)
        guard fm.fileExists(atPath: lib.appendingPathComponent("x86_64-windows").path) else {
            throw CellarError.dxvk("This Wine engine has no lib/wine/x86_64-windows folder, so DXMT can't be installed into it. Use a recent 64-bit Wine build.")
        }
        guard let unix = find("x86_64-unix", under: folder),
              fm.fileExists(atPath: unix.appendingPathComponent("winemetal.so").path),
              find("x86_64-windows", under: folder) != nil else {
            throw CellarError.dxvk("That doesn't look like a DXMT release. Choose the extracted folder that contains x86_64-unix (with winemetal.so) and x86_64-windows.")
        }

        let backupRoot = lib.appendingPathComponent(".cellar-backup/dxmt", isDirectory: true)
        let manifestURL = lib.appendingPathComponent(manifestName)
        var manifest = Set((try? String(contentsOf: manifestURL, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? [])

        do {
            for part in parts {
                guard let source = find(part, under: folder) else { continue }
                let dest = lib.appendingPathComponent(part, isDirectory: true)
                guard fm.fileExists(atPath: dest.path) else { continue }
                let backup = backupRoot.appendingPathComponent(part, isDirectory: true)
                try fm.createDirectory(at: backup, withIntermediateDirectories: true)
                for file in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                    let ext = file.pathExtension.lowercased()
                    guard ext == "dll" || ext == "so" else { continue }
                    let target = dest.appendingPathComponent(file.lastPathComponent)
                    if fm.fileExists(atPath: target.path) {
                        let saved = backup.appendingPathComponent(file.lastPathComponent)
                        if !fm.fileExists(atPath: saved.path) && !manifest.contains("\(part)/\(file.lastPathComponent)") {
                            try fm.copyItem(at: target, to: saved)
                        }
                        try fm.removeItem(at: target)
                    }
                    try fm.copyItem(at: file, to: target)
                    manifest.insert("\(part)/\(file.lastPathComponent)")
                }
            }
            try manifest.sorted().joined(separator: "\n").write(to: manifestURL, atomically: true, encoding: .utf8)
        } catch let error as CocoaError where error.code == .fileWriteNoPermission {
            throw CellarError.dxvk("macOS wouldn't let Cellar change the Wine engine at \(lib.path). Move the Wine app to ~/Applications and try again.")
        }

        // The bottle needs winemetal.dll in its own Windows folder too.
        for (part, sys) in [("x86_64-windows", "system32"), ("i386-windows", "syswow64")] {
            guard let source = find(part, under: folder) else { continue }
            let dll = source.appendingPathComponent("winemetal.dll")
            let dir = bottle.driveC.appendingPathComponent("windows/\(sys)", isDirectory: true)
            guard fm.fileExists(atPath: dll.path), fm.fileExists(atPath: dir.path) else { continue }
            let target = dir.appendingPathComponent("winemetal.dll")
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: dll, to: target)
        }

        let label = folder.lastPathComponent
        try label.write(to: lib.appendingPathComponent(markerName), atomically: true, encoding: .utf8)
        return label
    }

    /// Puts the engine's original DLLs back.
    static func remove(enginePath: String) throws {
        let fm = FileManager.default
        let lib = libDirectory(enginePath: enginePath)
        let manifestURL = lib.appendingPathComponent(manifestName)
        let backupRoot = lib.appendingPathComponent(".cellar-backup/dxmt", isDirectory: true)
        let entries = (try? String(contentsOf: manifestURL, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
        for entry in entries {
            let target = lib.appendingPathComponent(entry)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            let saved = backupRoot.appendingPathComponent(entry)
            if fm.fileExists(atPath: saved.path) { try fm.copyItem(at: saved, to: target) }
        }
        try? fm.removeItem(at: manifestURL)
        try? fm.removeItem(at: lib.appendingPathComponent(markerName))
    }
}

/// Makes Steam's window draw under Wine.
///
/// Steam's interface is Chromium (steamwebhelper.exe). With its GPU process on, the window is
/// black under Wine on macOS. CrossOver fixes this inside its Wine (a kernelbase patch that adds
/// flags to steamwebhelper's command line). Stock Wine has no such patch, so Cellar gets the same
/// effect from outside: it renames Valve's helper to steamwebhelper_real.exe and puts a tiny
/// wrapper in its place that starts the real one with the flags added.
/// Wrapper source: ThirdParty/steamwebhelper-wrapper (MIT, from notpop/steam-on-m1-wine).
enum SteamWindowFix {
    /// Valve's helper is several MB; the wrapper is about 250 KB.
    private static let wrapperSizeCeiling = 500_000

    static var wrapperURL: URL? {
        Bundle.main.url(forResource: "steamwebhelper-wrapper", withExtension: "exe")
    }

    static func isSteam(_ file: URL) -> Bool {
        file.lastPathComponent.lowercased() == "steam.exe"
    }

    private static func size(_ url: URL) -> Int? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue
    }

    /// Puts Valve's helper back where the wrapper was. Returns lines for the log.
    static func remove(from bottle: Bottle) -> [String] {
        let fm = FileManager.default
        var notes: [String] = []
        let cefRoot = bottle.driveC.appendingPathComponent("Program Files (x86)/Steam/bin/cef", isDirectory: true)
        for dir in (try? fm.contentsOfDirectory(at: cefRoot, includingPropertiesForKeys: nil)) ?? []
        where dir.lastPathComponent.hasPrefix("cef.win") {
            let target = dir.appendingPathComponent("steamwebhelper.exe")
            let real = dir.appendingPathComponent("steamwebhelper_real.exe")
            guard let targetSize = size(target), targetSize < wrapperSizeCeiling,
                  let realSize = size(real), realSize >= wrapperSizeCeiling else { continue }
            do {
                try fm.removeItem(at: target)
                try fm.moveItem(at: real, to: target)
                notes.append("Restored Steam's own helper in \(dir.lastPathComponent); this engine doesn't need the wrapper.")
            } catch {
                notes.append("⚠️ Couldn't restore Steam's helper in \(dir.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return notes
    }

    /// Installs or refreshes the wrapper and clears stale browser locks. Returns lines for the log.
    static func apply(to bottle: Bottle) -> [String] {
        let fm = FileManager.default
        var notes: [String] = []
        guard let wrapper = wrapperURL else {
            return ["⚠️ Steam window fix is missing from this copy of Cellar. Rebuild with build.sh."]
        }
        let cefRoot = bottle.driveC.appendingPathComponent("Program Files (x86)/Steam/bin/cef", isDirectory: true)
        let dirs = ((try? fm.contentsOfDirectory(at: cefRoot, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("cef.win") }
        if dirs.isEmpty {
            notes.append("Steam hasn't downloaded its browser yet. If its window is black after it finishes updating, stop it and launch it again.")
        }
        for dir in dirs {
            let target = dir.appendingPathComponent("steamwebhelper.exe")
            let real = dir.appendingPathComponent("steamwebhelper_real.exe")
            guard let targetSize = size(target) else { continue }
            do {
                if targetSize < wrapperSizeCeiling {
                    // Wrapper already in place. Valve's original must be sitting next to it.
                    guard let realSize = size(real), realSize >= wrapperSizeCeiling else {
                        notes.append("⚠️ \(dir.lastPathComponent): Valve's steamwebhelper is missing. Reinstall Steam in this bottle.")
                        continue
                    }
                } else {
                    // Valve's helper (first run, or Steam updated it). Keep it as the real one.
                    if fm.fileExists(atPath: real.path) { try fm.removeItem(at: real) }
                    try fm.copyItem(at: target, to: real)
                }
                try fm.removeItem(at: target)
                try fm.copyItem(at: wrapper, to: target)
                notes.append("Steam window fix applied in \(dir.lastPathComponent).")
            } catch {
                notes.append("⚠️ Couldn't apply the Steam window fix in \(dir.lastPathComponent): \(error.localizedDescription)")
            }
        }

        // A crashed Steam leaves Chromium lock files that make the next launch start with no window.
        let users = bottle.driveC.appendingPathComponent("users", isDirectory: true)
        for user in (try? fm.contentsOfDirectory(at: users, includingPropertiesForKeys: nil)) ?? [] {
            let cache = user.appendingPathComponent("AppData/Local/Steam/htmlcache", isDirectory: true)
            guard let e = fm.enumerator(at: cache, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in e {
                if e.level > 2 { e.skipDescendants(); continue }
                if url.lastPathComponent.hasPrefix("Singleton") { try? fm.removeItem(at: url) }
            }
        }
        return notes
    }
}

/// One-click DXMT: a pinned, checksum-verified release, plus a check that the engine can load it.
extension DXMTInstaller {
    static let pinnedVersion = "0.80"
    static let pinnedURL = URL(string: "https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz")!
    static let pinnedSHA256 = "8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d"

    /// DXMT draws by calling functions inside Wine's Mac driver (winemac.so). Stock WineHQ builds
    /// hide those functions; builds made from CrossOver's sources export them.
    /// Returns nil when it can't be checked (for example, Xcode's tools aren't installed).
    static func engineCanLoadDXMT(enginePath: String) -> Bool? {
        let driver = libDirectory(enginePath: enginePath).appendingPathComponent("x86_64-unix/winemac.so")
        let nm = "/usr/bin/nm"
        guard FileManager.default.fileExists(atPath: driver.path),
              FileManager.default.isExecutableFile(atPath: nm),
              let output = runTool(nm, ["-g", driver.path]) else { return nil }
        return output.contains("macdrv_functions") || output.contains("macdrv_view_create_metal_view")
    }

    /// Downloads the pinned release, checks it, extracts it, and returns the extracted folder.
    static func downloadPinned() async throws -> URL {
        let (temp, response) = try await URLSession.shared.download(from: pinnedURL)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw CellarError.dxvk("Couldn't download DXMT (HTTP \(status)). Check your internet connection.")
        }
        let data = try Data(contentsOf: temp)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == pinnedSHA256 else {
            throw CellarError.dxvk("The DXMT download doesn't match the expected checksum, so Cellar didn't install it.")
        }
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cellar/Downloads/dxmt-v\(pinnedVersion)", isDirectory: true)
        if fm.fileExists(atPath: base.path) { try fm.removeItem(at: base) }
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let archive = base.appendingPathComponent("dxmt.tar.gz")
        try fm.moveItem(at: temp, to: archive)
        guard runTool("/usr/bin/tar", ["-xzf", archive.path, "-C", base.path]) != nil else {
            throw CellarError.dxvk("Couldn't extract the DXMT download.")
        }
        return base
    }

    /// Runs a command-line tool and returns its output, or nil if it failed.
    private static func runTool(_ path: String, _ arguments: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
