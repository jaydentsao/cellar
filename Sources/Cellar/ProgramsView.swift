import SwiftUI
import AppKit
import UniformTypeIdentifiers

let windowsFileTypes: [UTType] = ["exe", "msi", "bat", "lnk"]
    .compactMap { UTType(filenameExtension: $0) }

struct ProgramsView: View {
    let bottle: Bottle

    @EnvironmentObject var store: BottleStore
    @EnvironmentObject var runner: WineRunner

    enum ImportMode { case addProgram, runInstaller }
    @State private var showImporter = false
    @State private var importMode: ImportMode = .addProgram
    @State private var scanResults: [URL]?
    @State private var editing: Program?
    @State private var errorMessage: String?
    @State private var errorTitle = "Couldn't save"
    @State private var installingSteam = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    importMode = .runInstaller
                    showImporter = true
                } label: {
                    Label("Run Installer…", systemImage: "square.and.arrow.down")
                }
                .help("Run a setup .exe or .msi once inside this bottle")

                Button {
                    importMode = .addProgram
                    showImporter = true
                } label: {
                    Label("Add Program…", systemImage: "plus")
                }

                Menu {
                    Button("Install Steam") { installSteam() }
                        .disabled(installingSteam || SteamInstaller.isInstalled(in: bottle))
                    Button("Add Deadlock (through Steam)") { addDeadlock() }
                        .disabled(!SteamInstaller.isInstalled(in: bottle)
                                  || bottle.config.programs.contains { $0.name == "Deadlock" })
                } label: {
                    Label(installingSteam ? "Installing Steam…" : "Steam", systemImage: "cloud")
                }
                .fixedSize()
                .disabled(!bottle.isInitialized)

                Button {
                    scanResults = ProgramScanner.scan(bottle)
                } label: {
                    Label("Find Installed Games", systemImage: "magnifyingglass")
                }
                .disabled(!bottle.isInitialized)
                Spacer()
            }

            if bottle.config.programs.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text("No programs yet").font(.title3)
                    Text("Run a game's installer, then use Find Installed Games to add it here.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(bottle.config.programs) { program in
                        programRow(program)
                    }
                }
            }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: windowsFileTypes.isEmpty ? [.item] : windowsFileTypes) { result in
            guard case .success(let url) = result else { return }
            switch importMode {
            case .runInstaller:
                runInstaller(url)
            case .addProgram:
                addProgram(url)
            }
        }
        .sheet(isPresented: Binding(get: { scanResults != nil },
                                    set: { if !$0 { scanResults = nil } })) {
            ScanResultsSheet(results: scanResults ?? [],
                             existing: Set(bottle.config.programs.map(\.path))) { url in
                addProgram(url)
            }
        }
        .sheet(item: $editing) { program in
            ProgramEditSheet(program: program) { updated in
                update { config in
                    if let i = config.programs.firstIndex(where: { $0.id == updated.id }) {
                        config.programs[i] = updated
                    }
                }
            }
        }
        .alert(errorTitle, isPresented: Binding(get: { errorMessage != nil },
                                                set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorTitle = "Couldn't save" }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func programRow(_ program: Program) -> some View {
        HStack(spacing: 12) {
            Button {
                runner.run(program: program, in: bottle)
            } label: {
                Image(systemName: "play.fill")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderedProminent)
            .help("Launch \(program.name)")

            VStack(alignment: .leading, spacing: 2) {
                Text(program.name).font(.headline)
                Text(displayPath(program.path))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !program.arguments.isEmpty {
                    Text("Arguments: \(program.arguments)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Edit") { editing = program }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Edit…") { editing = program }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: program.path)])
            }
            Divider()
            Button("Remove from List", role: .destructive) {
                update { $0.programs.removeAll { $0.id == program.id } }
            }
        }
    }

    /// Shows paths inside the bottle as C:\… style so they're readable.
    private func displayPath(_ path: String) -> String {
        let drive = bottle.driveC.path
        if path.hasPrefix(drive) {
            return "C:" + path.dropFirst(drive.count).replacingOccurrences(of: "/", with: "\\")
        }
        return path
    }

    private func addProgram(_ url: URL) {
        guard let current = store.bottle(bottle.url),
              !current.config.programs.contains(where: { $0.path == url.path }) else { return }
        let program = Program(name: url.deletingPathExtension().lastPathComponent,
                              path: url.path,
                              arguments: ProgramPresets.defaultArguments(for: url))
        update { $0.programs.append(program) }
    }

    /// Downloads Valve's installer, runs it silently, and adds Steam with its window fix.
    private func installSteam() {
        installingSteam = true
        Task { @MainActor in
            defer { installingSteam = false }
            do {
                guard let current = store.bottle(bottle.url) else { return }
                runner.appendLog(current.url, "▶ Downloading SteamSetup.exe from Valve…\n")
                let setup = try await SteamInstaller.download(into: current)
                let code = await runner.runAndWait(bottle: current,
                                                   arguments: [setup.path, "/S"],
                                                   label: "Install Steam")
                let exe = SteamInstaller.steamExe(in: current)
                if FileManager.default.fileExists(atPath: exe.path) {
                    addProgram(exe)
                } else {
                    errorTitle = "Steam didn't install"
                    errorMessage = "The installer exited with code \(code) and steam.exe isn't in the bottle. The Log tab shows what Wine reported."
                }
            } catch {
                errorTitle = "Steam didn't install"
                errorMessage = error.localizedDescription
            }
        }
    }

    private func addDeadlock() {
        let exe = SteamInstaller.steamExe(in: bottle)
        let program = Program(name: "Deadlock", path: exe.path,
                              arguments: ProgramPresets.deadlockArguments)
        update { $0.programs.append(program) }
    }

    /// Runs a setup file, then looks for whatever it installed and offers to add it.
    private func runInstaller(_ url: URL) {
        let before = Set(ProgramScanner.scan(bottle).map(\.path))
        runner.open(file: url, in: bottle, label: "Installer: \(url.lastPathComponent)") { code in
            guard let current = store.bottle(bottle.url) else { return }
            if code != 0 {
                errorTitle = "The installer stopped with an error"
                errorMessage = "It exited with code \(code). The Log tab shows what Wine reported."
            }
            let existing = Set(current.config.programs.map(\.path))
            let found = ProgramScanner.scan(current)
                .filter { !before.contains($0.path) && !existing.contains($0.path) }
            if !found.isEmpty { scanResults = found }
        }
    }

    private func update(_ change: (inout BottleConfig) -> Void) {
        guard var current = store.bottle(bottle.url) else { return }
        change(&current.config)
        do { try store.save(current) } catch {
            errorTitle = "Couldn't save"
            errorMessage = error.localizedDescription
        }
    }
}

struct ScanResultsSheet: View {
    let results: [URL]
    let existing: Set<String>
    let onAdd: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var added: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Programs Found").font(.title2.bold())
            if results.isEmpty {
                Text("Nothing found in Program Files. Use Add Program… to pick the game's .exe yourself.")
                    .foregroundStyle(.secondary)
            } else {
                List(results, id: \.self) { url in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(url.deletingPathExtension().lastPathComponent)
                            Text(url.deletingLastPathComponent().lastPathComponent)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if existing.contains(url.path) || added.contains(url.path) {
                            Text("Added").foregroundStyle(.secondary)
                        } else {
                            Button("Add") {
                                onAdd(url)
                                added.insert(url.path)
                            }
                        }
                    }
                }
                .frame(minHeight: 260)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 420)
    }
}

struct ProgramEditSheet: View {
    @State var program: Program
    let onSave: (Program) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var picking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Program").font(.title2.bold())
            Form {
                TextField("Name", text: $program.name)
                HStack {
                    TextField("File", text: $program.path)
                    Button("Choose…") { picking = true }
                }
                TextField("Launch arguments", text: $program.arguments,
                          prompt: Text("-dx11 -windowed"))
                Text("Use quotes for arguments with spaces.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(program)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 520)
        .fileImporter(isPresented: $picking,
                      allowedContentTypes: windowsFileTypes.isEmpty ? [.item] : windowsFileTypes) { result in
            if case .success(let url) = result { program.path = url.path }
        }
    }
}
