import SwiftUI
import PMD3BarCore

/// stdout and stderr of an app launched with "Show its output" (Apps ▸ Launch with Options…).
struct ConsoleTab: View {
    let tool: AppConsoleTool
    @State private var autoScroll = true

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                if tool.running {
                    ProgressView().controlSize(.small)
                    Text(tool.appName ?? "").font(.callout.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Button { tool.stop() } label: { Label("Detach", systemImage: "stop.fill") }
                        .help("Stop showing the output; the app keeps running")
                } else {
                    Text(tool.appName ?? "No app").font(.callout.weight(.semibold)).lineLimit(1)
                    Spacer()
                }
                Toggle("Scroll", isOn: $autoScroll).toggleStyle(.checkbox)
                Button { tool.export() } label: { Image(systemName: "square.and.arrow.down") }
                    .help("Export to Downloads").disabled(tool.buffer.lines.isEmpty)
                Button { tool.clear() } label: { Image(systemName: "trash") }.help("Clear")
            }
            ScrollViewReader { proxy in
                List(tool.buffer.lines) { line in
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .id(line.id)
                }
                .overlay {
                    if tool.buffer.lines.isEmpty {
                        Text(tool.running ? "Waiting for output…" : "Nothing yet")
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: tool.buffer.lines.last?.id) { _, last in
                    if autoScroll, let last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            if let ended = tool.ended {
                Text(ended).font(.caption).foregroundStyle(.secondary)
            }
            Text("Apps ▸ right-click ▸ Launch with Options… ▸ \"Show its output\". What the app prints and logs (print, NSLog, os_log, Logger), as in Xcode's console. Last 5000 lines.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
    }
}
