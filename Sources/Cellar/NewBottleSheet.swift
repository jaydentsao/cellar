import SwiftUI

struct NewBottleSheet: View {
    @EnvironmentObject var store: BottleStore
    @EnvironmentObject var runner: WineRunner
    @EnvironmentObject var engines: EngineStore
    @Environment(\.dismiss) private var dismiss

    var onCreate: (Bottle) -> Void

    @State private var name = "Games"
    @State private var enginePath = ""
    @State private var windowsVersion: WindowsVersion = .win10
    @State private var graphics: GraphicsBackend = .wined3d
    @State private var retina = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Bottle").font(.title2.bold())

            Form {
                TextField("Name", text: $name)

                Picker("Wine engine", selection: $enginePath) {
                    if engines.engines.isEmpty {
                        Text("None found").tag("")
                    }
                    ForEach(engines.engines) { engine in
                        Text(engine.name).tag(engine.path)
                    }
                }
                if let v = engines.versions[enginePath] {
                    Text(v).font(.caption).foregroundStyle(.secondary)
                }

                Picker("Windows version", selection: $windowsVersion) {
                    ForEach(WindowsVersion.allCases) { Text($0.title).tag($0) }
                }

                Picker("Graphics", selection: $graphics) {
                    ForEach(GraphicsBackend.allCases) { Text($0.title).tag($0) }
                }
                Text(graphics.detail).font(.caption).foregroundStyle(.secondary)

                Toggle("Retina mode (sharper, but games run at higher resolution)", isOn: $retina)
            }
            .formStyle(.grouped)

            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }

            HStack {
                if working {
                    ProgressView().controlSize(.small)
                    Text("Setting up Windows… a Mono or Gecko installer may pop up; accept it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(working || enginePath.isEmpty
                              || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear {
            if enginePath.isEmpty { enginePath = engines.engines.first?.path ?? "" }
        }
    }

    private func create() {
        working = true
        error = nil
        var config = BottleConfig(name: name.trimmingCharacters(in: .whitespaces), enginePath: enginePath)
        config.windowsVersion = windowsVersion
        config.graphics = graphics
        config.retinaMode = retina
        Task {
            do {
                let bottle = try await store.create(config: config, runner: runner)
                onCreate(bottle)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}
