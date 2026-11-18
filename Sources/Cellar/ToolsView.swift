import SwiftUI
import AppKit

struct ToolsView: View {
    let bottle: Bottle

    @EnvironmentObject var runner: WineRunner
    @State private var verbs = ""

    private let columns = [GridItem(.adaptive(minimum: 170), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("Windows tools") {
                    LazyVGrid(columns: columns, spacing: 12) {
                        tool("Wine Configuration", "gearshape", ["winecfg"])
                        tool("Registry Editor", "list.bullet.indent", ["regedit"])
                        tool("Task Manager", "chart.bar", ["taskmgr"])
                        tool("File Explorer", "folder", ["explorer"])
                        tool("Control Panel", "slider.horizontal.below.rectangle", ["control"])
                        tool("Uninstall Programs", "trash", ["uninstaller"])
                        tool("Command Prompt", "terminal", ["start", "cmd.exe"])
                    }
                    .padding(6)
                }

                GroupBox("Bottle") {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ToolButton(title: "Open C: Drive in Finder", icon: "externaldrive") {
                            NSWorkspace.shared.open(bottle.driveC)
                        }
                        tool("Update Bottle", "arrow.triangle.2.circlepath", ["wineboot", "-u"])
                        tool("Simulate Reboot", "restart", ["wineboot", "-r"])
                        ToolButton(title: "Stop Everything", icon: "stop.circle") {
                            runner.killAll(bottle: bottle)
                        }
                    }
                    .padding(6)
                }

                GroupBox("Winetricks") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let winetricks = SystemCheck.winetricksPath {
                            Text("Install runtimes and fixes games often need. Separate verbs with spaces.")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                TextField("Verbs", text: $verbs,
                                          prompt: Text("vcrun2022 d3dcompiler_47 corefonts"))
                                    .font(.body.monospaced())
                                Button("Run") {
                                    let list = splitArguments(verbs)
                                    guard !list.isEmpty else { return }
                                    runner.launch(bottle: bottle,
                                                  executable: winetricks,
                                                  arguments: ["-q"] + list,
                                                  label: "winetricks \(list.joined(separator: " "))")
                                }
                                .disabled(verbs.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                            Text("Progress shows in the Log tab.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Winetricks isn't installed. Install it with Homebrew, then reopen this tab:")
                                .font(.callout)
                            Text("brew install winetricks")
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
            }
            .padding(4)
        }
    }

    private func tool(_ title: String, _ icon: String, _ args: [String]) -> ToolButton {
        ToolButton(title: title, icon: icon) {
            runner.launch(bottle: bottle, arguments: args, label: title)
        }
    }
}

struct ToolButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon).frame(width: 20)
                Text(title)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
    }
}
