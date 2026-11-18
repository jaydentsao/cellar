import SwiftUI

struct BottleDetailView: View {
    let bottleURL: URL

    @EnvironmentObject var store: BottleStore
    @EnvironmentObject var runner: WineRunner
    @EnvironmentObject var engines: EngineStore

    enum Tab: Hashable { case programs, settings, tools, log }
    @State private var tab: Tab = .programs

    var body: some View {
        if let bottle = store.bottle(bottleURL) {
            TabView(selection: $tab) {
                ProgramsView(bottle: bottle)
                    .tabItem { Label("Programs", systemImage: "gamecontroller") }
                    .tag(Tab.programs)
                BottleSettingsView(bottle: bottle)
                    .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
                    .tag(Tab.settings)
                ToolsView(bottle: bottle)
                    .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
                    .tag(Tab.tools)
                LogView(bottle: bottle)
                    .tabItem { Label("Log", systemImage: "text.alignleft") }
                    .tag(Tab.log)
            }
            .padding()
            .navigationTitle(bottle.config.name)
            .navigationSubtitle(engines.name(for: bottle.config.enginePath))
            .toolbar {
                ToolbarItem {
                    Button {
                        runner.killAll(bottle: bottle)
                    } label: {
                        Label("Stop All", systemImage: "stop.fill")
                    }
                    .help("Force-quit everything running in this bottle")
                }
            }
        }
    }
}
