import Foundation

/// Runs Wine (and wineserver / winetricks) for a bottle with that bottle's settings,
/// and keeps a per-bottle log of everything they print.
@MainActor
final class WineRunner: ObservableObject {
    @Published private(set) var logs: [URL: String] = [:]
    @Published private(set) var runningCount: [URL: Int] = [:]

    private let maxLogLength = 400_000

    // MARK: Environment

    /// The full environment a bottle runs with. This is where every setting turns into behavior.
    func environment(for bottle: Bottle) -> [String: String] {
        let c = bottle.config
        var env = ProcessInfo.processInfo.environment
        let binDir = URL(fileURLWithPath: c.enginePath).deletingLastPathComponent().path

        env["WINEPREFIX"] = bottle.url.path
        env["WINE"] = c.enginePath                     // used by winetricks
        env["WINESERVER"] = binDir + "/wineserver"
        env["PATH"] = [binDir, "/opt/homebrew/bin", "/usr/local/bin",
                       env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"].joined(separator: ":")

        let bundledDXMT = EngineInfo.bundledDXMT(enginePath: c.enginePath)
        if bundledDXMT != nil {
            // A relocated CrossOver-source build finds its own libraries and DLLs through these.
            let root = EngineInfo.root(enginePath: c.enginePath).path
            env["DYLD_FALLBACK_LIBRARY_PATH"] = root + "/lib:/usr/lib"
            env["WINEDLLPATH"] = root + "/lib/wine"
        }

        if !c.wineDebug.isEmpty { env["WINEDEBUG"] = c.wineDebug }
        if c.msync { env["WINEMSYNC"] = "1" }
        if c.esync { env["WINEESYNC"] = "1" }
        if c.metalHUD { env["MTL_HUD_ENABLED"] = "1" }

        var overrides: [String] = []
        switch c.graphics {
        case .wined3d, .wined3dVulkan:
            // Force Wine's own DLLs so a bottle that once had DXVK can switch back.
            overrides.append("d3d9,d3d10core,d3d11,dxgi=b")
        case .dxvk:
            overrides.append("d3d9,d3d10core,d3d11,dxgi=n,b")
            if !c.dxvkHUD.isEmpty { env["DXVK_HUD"] = c.dxvkHUD }
        case .dxmt:
            if let dxmt = bundledDXMT {
                // The CrossOver way: DXMT sits beside Wine and is searched before Wine's own Direct3D.
                env["WINEDLLPATH_PREPEND"] = dxmt.path
                if let d3d12 = EngineInfo.bundledD3D12 {
                    // DirectX 12 games skip DXMT and get VKD3D-Proton, drawing through its own MoltenVK.
                    env["WINEDLLPATH_PREPEND_D3D12"] = d3d12.path
                    let moltenvk = d3d12.appendingPathComponent("moltenvk").path
                    env["DYLD_LIBRARY_PATH"] = [moltenvk, env["DYLD_LIBRARY_PATH"]]
                        .compactMap { $0 }.joined(separator: ":")
                }
            } else {
                // DXMT's DLLs replaced the engine's own, so they load as builtin.
                overrides.append("d3d10core,d3d11,dxgi,winemetal=b")
            }
        case .d3dmetal:
            overrides.append("d3d9,d3d10core,d3d11,d3d12,dxgi=b")
        }
        if SteamInstaller.isInstalled(in: bottle) {
            // Steam's in-game overlay hooks Direct3D and hangs games under Wine; keep it from loading.
            overrides.append("bcrypt,ncrypt=b;gameoverlayrenderer,gameoverlayrenderer64=d")
        }
        let user = c.dllOverrides.trimmingCharacters(in: .whitespacesAndNewlines)
        if !user.isEmpty { overrides.append(user) }
        env["WINEDLLOVERRIDES"] = overrides.joined(separator: ";")

        // Your own variables win over everything above.
        for v in c.environment where !v.key.trimmingCharacters(in: .whitespaces).isEmpty {
            env[v.key.trimmingCharacters(in: .whitespaces)] = v.value
        }
        return env
    }

    // MARK: Launching

    /// Starts a process for the bottle. `executable` defaults to the bottle's Wine engine.
    @discardableResult
    func launch(bottle: Bottle,
                executable: String? = nil,
                arguments: [String],
                label: String,
                workingDirectory: URL? = nil,
                onExit: ((Int32) -> Void)? = nil) -> Bool {
        let key = bottle.url
        let exe = executable ?? bottle.config.enginePath

        guard FileManager.default.isExecutableFile(atPath: exe) else {
            appendLog(key, "⚠️ Can't run \(exe): file is missing or not executable. Pick a Wine engine in this bottle's Settings.\n")
            onExit?(-1)
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = arguments
        process.environment = environment(for: bottle)
        if let wd = workingDirectory { process.currentDirectoryURL = wd }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.appendLog(key, text) }
        }
        process.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            Task { @MainActor in
                self?.appendLog(key, "■ \(label) finished (exit code \(code))\n")
                self?.changeRunning(key, by: -1)
                onExit?(code)
            }
        }

        appendLog(key, "▶ \(label): \(([exe] + arguments).joined(separator: " "))\n")
        do {
            try process.run()
            changeRunning(key, by: 1)
            return true
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            appendLog(key, "⚠️ \(label) failed to start: \(error.localizedDescription)\n")
            onExit?(-1)
            return false
        }
    }

    /// Runs and waits for exit. Returns the exit code (-1 if it couldn't start).
    func runAndWait(bottle: Bottle,
                    executable: String? = nil,
                    arguments: [String],
                    label: String) async -> Int32 {
        var continuation: AsyncStream<Int32>.Continuation?
        let exits = AsyncStream<Int32> { continuation = $0 }
        let cont = continuation
        launch(bottle: bottle, executable: executable, arguments: arguments, label: label) { code in
            cont?.yield(code)
            cont?.finish()
        }
        for await code in exits { return code }
        return -1
    }

    /// Launches a program file with the right Wine verb for its type.
    func open(file: URL, in bottle: Bottle, extraArguments: [String] = [], label: String? = nil,
              onExit: ((Int32) -> Void)? = nil) {
        let ext = file.pathExtension.lowercased()
        let args: [String]
        if ext == "exe" {
            args = [file.path] + extraArguments
        } else {
            // .msi, .bat, .lnk and friends go through Windows' "start", which picks the handler.
            args = ["start", "/wait", "/unix", file.path] + extraArguments
        }
        launch(bottle: bottle,
               arguments: args,
               label: label ?? file.lastPathComponent,
               workingDirectory: file.deletingLastPathComponent(),
               onExit: onExit)
    }

    func run(program: Program, in bottle: Bottle) {
        let file = URL(fileURLWithPath: program.path)
        var arguments = program.arguments
        if SteamWindowFix.isSteam(file), EngineInfo.handlesSteamWindow(enginePath: bottle.config.enginePath) {
            // This engine fixes Steam's window itself, so undo Cellar's wrapper and its launch flags.
            for note in SteamWindowFix.remove(from: bottle) { appendLog(bottle.url, note + "\n") }
            let preset = splitArguments(ProgramPresets.steamArguments)
                + ["-cef-disable-gpu", "-cef-disable-gpu-compositing", "-cef-in-process-gpu"]
            arguments = splitArguments(arguments).filter { !preset.contains($0) }.joined(separator: " ")
        } else if SteamWindowFix.isSteam(file) {
            for note in SteamWindowFix.apply(to: bottle) { appendLog(bottle.url, note + "\n") }
            // Steam needs these on every launch, including entries saved with older or no arguments.
            for flag in splitArguments(ProgramPresets.steamArguments) where !splitArguments(arguments).contains(flag) {
                arguments += " " + flag
            }
            // Flags from earlier Cellar versions that don't work on stock Wine.
            for stale in ["-cef-disable-gpu", "-cef-disable-gpu-compositing", "-cef-in-process-gpu"] {
                arguments = splitArguments(arguments).filter { $0 != stale }.joined(separator: " ")
            }
        }
        open(file: file,
             in: bottle,
             extraArguments: splitArguments(arguments),
             label: program.name)
    }

    /// Stops every Windows process in the bottle.
    func killAll(bottle: Bottle) {
        let server = URL(fileURLWithPath: bottle.config.enginePath)
            .deletingLastPathComponent().appendingPathComponent("wineserver").path
        launch(bottle: bottle, executable: server, arguments: ["-k"], label: "Stop all processes")
    }

    /// Writes settings that live in the Windows registry rather than the environment.
    func applyRegistrySettings(bottle: Bottle) async {
        let c = bottle.config
        _ = await runAndWait(bottle: bottle,
                             arguments: ["reg", "add", "HKCU\\Software\\Wine\\Mac Driver",
                                         "/v", "RetinaMode", "/t", "REG_SZ",
                                         "/d", c.retinaMode ? "y" : "n", "/f"],
                             label: "Set Retina mode \(c.retinaMode ? "on" : "off")")
        // WineD3D draws through OpenGL (DirectX 9 era) or Vulkan (what DirectX 10/11 needs on a Mac).
        let renderer = c.graphics == .wined3dVulkan ? "vulkan" : "gl"
        _ = await runAndWait(bottle: bottle,
                             arguments: ["reg", "add", "HKCU\\Software\\Wine\\Direct3D",
                                         "/v", "renderer", "/t", "REG_SZ", "/d", renderer, "/f"],
                             label: "Set WineD3D renderer to \(renderer)")
        _ = await runAndWait(bottle: bottle,
                             arguments: ["winecfg", "-v", c.windowsVersion.rawValue],
                             label: "Set \(c.windowsVersion.title)")
    }

    // MARK: Log

    func isRunning(_ bottle: Bottle) -> Bool { (runningCount[bottle.url] ?? 0) > 0 }

    func log(for bottle: Bottle) -> String { logs[bottle.url] ?? "" }

    func clearLog(for bottle: Bottle) { logs[bottle.url] = "" }

    func appendLog(_ key: URL, _ text: String) {
        var current = logs[key] ?? ""
        current += text
        if current.count > maxLogLength {
            current = String(current.suffix(maxLogLength))
        }
        logs[key] = current
    }

    private func changeRunning(_ key: URL, by delta: Int) {
        runningCount[key] = max(0, (runningCount[key] ?? 0) + delta)
    }
}
