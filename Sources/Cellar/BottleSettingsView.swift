import SwiftUI

struct BottleSettingsView: View {
    let bottle: Bottle

    @EnvironmentObject var store: BottleStore
    @EnvironmentObject var runner: WineRunner
    @EnvironmentObject var engines: EngineStore

    @State private var draft: BottleConfig
    @State private var pickingDXVK = false
    enum LayerPick { case dxvk, dxmt }
    @State private var layerPick: LayerPick = .dxvk
    @State private var layerRefresh = 0
    @State private var dxmtCompatible: Bool?
    @State private var downloadingDXMT = false
    @State private var message: String?
    @State private var applying = false

    init(bottle: Bottle) {
        self.bottle = bottle
        _draft = State(initialValue: bottle.config)
    }

    /// The saved config with the draft's program list, so program edits don't count as setting changes.
    private var saved: BottleConfig? {
        guard var c = store.bottle(bottle.url)?.config else { return nil }
        c.programs = draft.programs
        return c
    }

    private var hasChanges: Bool { saved != draft }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                engineSection
                windowsSection
                graphicsSection
                performanceSection
                advancedSection
            }
            .formStyle(.grouped)

            HStack {
                if let message {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
                if applying { ProgressView().controlSize(.small) }
                Spacer()
                Button("Revert") {
                    if let c = store.bottle(bottle.url)?.config { draft = c }
                }
                .disabled(!hasChanges || applying)
                Button("Apply") { apply() }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasChanges || applying)
            }
            .padding(.top, 10)
        }
        .fileImporter(isPresented: $pickingDXVK, allowedContentTypes: [.folder]) { result in
            guard case .success(let folder) = result,
                  let current = store.bottle(bottle.url) else { return }
            do {
                switch layerPick {
                case .dxvk:
                    let version = try DXVKInstaller.install(from: folder, into: current)
                    message = "Installed \(version). Set Graphics to DXVK and Apply to use it."
                case .dxmt:
                    let version = try DXMTInstaller.install(from: folder,
                                                           enginePath: draft.enginePath,
                                                           bottle: current)
                    message = "Installed \(version) into the engine. Set Graphics to DXMT and Apply to use it."
                }
                layerRefresh += 1
            } catch {
                message = error.localizedDescription
            }
        }
    }

    // MARK: Sections

    private var engineSection: some View {
        Section("Wine engine") {
            Picker("Engine", selection: $draft.enginePath) {
                ForEach(engines.engines) { Text($0.name).tag($0.path) }
                if !engines.engines.contains(where: { $0.path == draft.enginePath }) {
                    Text("Missing: \(draft.enginePath)").tag(draft.enginePath)
                }
            }
            if let v = engines.versions[draft.enginePath] {
                LabeledContent("Version", value: v)
            }
            Text("Each bottle can use a different Wine build. Add more in Cellar → Settings.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var windowsSection: some View {
        Section("Windows") {
            Picker("Reports itself as", selection: $draft.windowsVersion) {
                ForEach(WindowsVersion.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Retina mode", isOn: $draft.retinaMode)
            Text("Retina mode renders at full display resolution. Sharper, but heavier on the GPU.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var graphicsSection: some View {
        Section("Graphics") {
            Picker("Backend", selection: $draft.graphics) {
                ForEach(GraphicsBackend.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Text(draft.graphics.detail).font(.caption).foregroundStyle(.secondary)

            if draft.graphics == .dxvk {
                let installed = DXVKInstaller.installedVersion(in: bottle)
                LabeledContent("DXVK in this bottle") {
                    Text(installed ?? "Not installed")
                        .foregroundStyle(installed == nil ? Color.red : Color.secondary)
                }
                Button("Install DXVK from Folder…") {
                    layerPick = .dxvk
                    pickingDXVK = true
                }
                TextField("DXVK HUD", text: $draft.dxvkHUD, prompt: Text("off — try fps or full"))
            }
            if draft.graphics == .dxmt {
                let installed = DXMTInstaller.installedVersion(enginePath: draft.enginePath)
                LabeledContent("DXMT in this engine") {
                    Text(installed ?? "Not installed")
                        .foregroundStyle(installed == nil ? Color.red : Color.secondary)
                }
                .id(layerRefresh)
                LabeledContent("Engine check") {
                    switch dxmtCompatible {
                    case .some(true):
                        Text("This engine can load DXMT").foregroundStyle(Color.secondary)
                    case .some(false):
                        Text("This engine can't load DXMT").foregroundStyle(Color.red)
                    case .none:
                        Text("Couldn't check").foregroundStyle(Color.secondary)
                    }
                }
                .task(id: draft.enginePath) {
                    let path = draft.enginePath
                    dxmtCompatible = await Task.detached {
                        DXMTInstaller.engineCanLoadDXMT(enginePath: path)
                    }.value
                }
                let builtIn = EngineInfo.bundledDXMT(enginePath: draft.enginePath) != nil
                if builtIn {
                    LabeledContent("DirectX 12") {
                        Text(EngineInfo.bundledD3D12 != nil ? "Included (VKD3D-Proton)" : "Not in this copy of Cellar")
                            .foregroundStyle(Color.secondary)
                    }
                    Text("This engine carries its own DXMT, the same arrangement CrossOver uses. Nothing to install: choose DXMT and click Apply.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if dxmtCompatible == false {
                    Text("DXMT needs a Wine built from CrossOver's sources. A stock Wine build hides the functions DXMT calls, so games would fail to start. On this engine use WineD3D (Vulkan → Metal) for DirectX 11 instead.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !builtIn {
                    Button(downloadingDXMT ? "Downloading DXMT…" : "Download and Install DXMT \(DXMTInstaller.pinnedVersion)") {
                        downloadAndInstallDXMT()
                    }
                    .disabled(downloadingDXMT)
                    Button("Install DXMT from Folder…") {
                        layerPick = .dxmt
                        pickingDXVK = true
                    }
                }
                if installed != nil && !builtIn {
                    Button("Remove DXMT from Engine") {
                        do {
                            try DXMTInstaller.remove(enginePath: draft.enginePath)
                            message = "Removed DXMT. The engine's original files are back."
                        } catch {
                            message = error.localizedDescription
                        }
                        layerRefresh += 1
                    }
                }
                if !builtIn {
                    Text("DXMT replaces Direct3D 11 for every bottle that uses this engine. Remove it to go back to WineD3D or DXVK on this engine.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("Metal performance HUD", isOn: $draft.metalHUD)
        }
    }

    private var performanceSection: some View {
        Section("Performance") {
            Toggle("MSync (macOS-native sync; big speedup on builds that support it)", isOn: $draft.msync)
            Toggle("ESync", isOn: $draft.esync)
            TextField("WINEDEBUG", text: $draft.wineDebug, prompt: Text("-all"))
            Text("-all keeps logging off for speed. Use something like +loaddll to debug a crash.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var advancedSection: some View {
        Section("Advanced") {
            TextField("DLL overrides", text: $draft.dllOverrides,
                      prompt: Text("xinput1_3=n,b;winmm=n,b"))
            Text("Added after the graphics overrides. n = native (the game's DLL), b = builtin (Wine's).")
                .font(.caption).foregroundStyle(.secondary)

            ForEach($draft.environment) { $variable in
                HStack {
                    TextField("NAME", text: $variable.key)
                        .font(.body.monospaced())
                    TextField("value", text: $variable.value)
                        .font(.body.monospaced())
                    Button {
                        let id = variable.id
                        draft.environment.removeAll { $0.id == id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button {
                draft.environment.append(EnvVar(key: "", value: ""))
            } label: {
                Label("Add Environment Variable", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
        }
    }

    private func downloadAndInstallDXMT() {
        guard let current = store.bottle(bottle.url) else { return }
        let enginePath = draft.enginePath
        downloadingDXMT = true
        message = "Downloading DXMT…"
        Task { @MainActor in
            defer { downloadingDXMT = false }
            do {
                let folder = try await DXMTInstaller.downloadPinned()
                let version = try DXMTInstaller.install(from: folder, enginePath: enginePath, bottle: current)
                message = "Installed \(version) into the engine. Set Graphics to DXMT and Apply to use it."
            } catch {
                message = error.localizedDescription
            }
            layerRefresh += 1
        }
    }

    // MARK: Apply

    private func apply() {
        guard var current = store.bottle(bottle.url) else { return }
        let old = current.config
        var updated = draft
        updated.programs = old.programs     // programs are edited on their own tab
        updated.created = old.created
        current.config = updated
        do {
            try store.save(current)
            draft = updated
        } catch {
            message = error.localizedDescription
            return
        }

        let registryChanged = old.retinaMode != updated.retinaMode
            || old.windowsVersion != updated.windowsVersion
            || old.enginePath != updated.enginePath
            || old.graphics != updated.graphics
        if registryChanged {
            applying = true
            message = "Applying Windows settings…"
            let snapshot = current
            Task {
                await runner.applyRegistrySettings(bottle: snapshot)
                applying = false
                message = "Saved. Settings take effect the next time you launch a program."
            }
        } else {
            message = "Saved. Settings take effect the next time you launch a program."
        }
    }
}
