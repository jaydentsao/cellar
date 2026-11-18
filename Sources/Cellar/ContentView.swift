import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var store: BottleStore
    @EnvironmentObject var runner: WineRunner
    @EnvironmentObject var engines: EngineStore

    @State private var selection: URL?
    @State private var showingNewBottle = false
    @State private var bottleToTrash: Bottle?
    @State private var errorMessage: String?

    var body: some View {
        NavigationSplitView {
            List(store.bottles, selection: $selection) { bottle in
                HStack {
                    Image(systemName: "wineglass")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bottle.config.name)
                        Text(bottle.config.graphics.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if runner.isRunning(bottle) {
                        Circle().fill(.green).frame(width: 8, height: 8)
                            .help("Something is running in this bottle")
                    }
                }
                .tag(bottle.url)
                .contextMenu {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([bottle.url])
                    }
                    Divider()
                    Button("Move to Trash…", role: .destructive) { bottleToTrash = bottle }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .toolbar {
                ToolbarItem {
                    Button { showingNewBottle = true } label: {
                        Label("New Bottle", systemImage: "plus")
                    }
                    .help("Create a new bottle")
                }
            }
            .safeAreaInset(edge: .bottom) { banners }
        } detail: {
            if let url = selection, store.bottle(url) != nil {
                BottleDetailView(bottleURL: url)
                    .id(url)
            } else {
                emptyState
            }
        }
        .sheet(isPresented: $showingNewBottle) {
            NewBottleSheet { created in selection = created.url }
                .environmentObject(store)
                .environmentObject(runner)
                .environmentObject(engines)
        }
        .alert("Move “\(bottleToTrash?.config.name ?? "")” to the Trash?",
               isPresented: Binding(get: { bottleToTrash != nil },
                                    set: { if !$0 { bottleToTrash = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let b = bottleToTrash {
                    runner.killAll(bottle: b)
                    do {
                        try store.moveToTrash(b)
                        if selection == b.url { selection = nil }
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                bottleToTrash = nil
            }
            Button("Cancel", role: .cancel) { bottleToTrash = nil }
        } message: {
            Text("Everything installed in it goes with it. You can restore it from the Trash.")
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear {
            if selection == nil { selection = store.bottles.first?.url }
        }
    }

    @ViewBuilder
    private var banners: some View {
        VStack(spacing: 8) {
            if SystemCheck.isAppleSilicon && !SystemCheck.rosettaInstalled {
                Banner(icon: "exclamationmark.triangle",
                       text: "Rosetta 2 isn't installed. Wine needs it on Apple Silicon. Run in Terminal:",
                       command: "softwareupdate --install-rosetta --agree-to-license")
            }
            if engines.engines.isEmpty {
                Banner(icon: "shippingbox",
                       text: "No Wine engine found. Add one in Cellar → Settings (⌘,).",
                       command: nil)
            }
        }
        .padding(8)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "wineglass")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(store.bottles.isEmpty ? "No bottles yet" : "Select a bottle")
                .font(.title2)
            Text("A bottle is a separate Windows environment with its own settings, programs and fixes.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if store.bottles.isEmpty {
                Button("Create a Bottle") { showingNewBottle = true }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}

struct Banner: View {
    let icon: String
    let text: String
    let command: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(text, systemImage: icon)
                .font(.caption)
            if let command {
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(10)
        .background(Color.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }
}
