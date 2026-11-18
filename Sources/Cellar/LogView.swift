import SwiftUI
import AppKit

struct LogView: View {
    let bottle: Bottle
    @EnvironmentObject var runner: WineRunner
    @State private var follow = true

    var body: some View {
        let log = runner.log(for: bottle)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Follow output", isOn: $follow)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log, forType: .string)
                }
                .disabled(log.isEmpty)
                Button("Clear") { runner.clearLog(for: bottle) }
                    .disabled(log.isEmpty)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(log.isEmpty ? "Wine output for this bottle appears here." : log)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(log.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                        Color.clear.frame(height: 1).id("bottom")
                    }
                }
                .background(Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 6))
                .onChange(of: log.count) { _ in
                    if follow { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }
}
