import SwiftUI
import UniformTypeIdentifiers

struct EnginesView: View {
    @EnvironmentObject var engines: EngineStore
    @State private var picking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Wine Engines").font(.title2.bold())
            Text("Cellar finds Wine builds in /Applications, ~/Applications, Homebrew and Game Porting Toolkit locations. You can also add any wine or wine64 binary yourself.")
                .font(.callout)
                .foregroundStyle(.secondary)

            List {
                if engines.engines.isEmpty {
                    Text("No engines found yet.").foregroundStyle(.secondary)
                }
                ForEach(engines.engines) { engine in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(engine.name).font(.headline)
                            Text(engines.versions[engine.path] ?? "Checking version…")
                                .font(.caption)
                            Text(engine.path)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        if engine.isCustom {
                            Button("Remove") { engines.removeCustom(path: engine.path) }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            HStack {
                Button("Add Wine Binary…") { picking = true }
                Button("Rescan") { engines.refresh() }
                Spacer()
            }
        }
        .padding(20)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.unixExecutable, .item]) { result in
            if case .success(let url) = result { engines.addCustom(path: url.path) }
        }
    }
}
