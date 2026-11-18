import SwiftUI
import AppKit

@main
struct CellarApp: App {
    @StateObject private var store = BottleStore()
    @StateObject private var runner = WineRunner()
    @StateObject private var engines = EngineStore()

    init() {
        // Make sure we get a Dock icon and a real window even when launched outside a bundle.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Cellar") {
            ContentView()
                .environmentObject(store)
                .environmentObject(runner)
                .environmentObject(engines)
                .frame(minWidth: 940, minHeight: 600)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }

        Settings {
            EnginesView()
                .environmentObject(engines)
                .frame(width: 620, height: 460)
        }
    }
}
