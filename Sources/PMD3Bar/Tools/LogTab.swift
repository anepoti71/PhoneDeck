import SwiftUI
import PMD3BarCore

struct LogTab: View {
    @Bindable var tools: DeviceTools
    @State private var autoScroll = true

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Process (e.g. SpringBoard)", text: $tools.logProcessFilter).textFieldStyle(.roundedBorder)
                TextField("Text", text: $tools.logTextFilter).textFieldStyle(.roundedBorder)
            }
            .onSubmit { tools.startLog() }
            HStack {
                if tools.logRunning {
                    Button { tools.stopLog() } label: { Label("Stop", systemImage: "pause.fill") }
                } else {
                    Button { tools.startLog() } label: { Label("Start", systemImage: "play.fill") }
                }
                Toggle("Info", isOn: $tools.logIncludeInfo).toggleStyle(.checkbox)
                    .help("Include Info-level messages (far more numerous)")
                Toggle("Scroll", isOn: $autoScroll).toggleStyle(.checkbox)
                Spacer()
                Button { tools.exportLog() } label: { Image(systemName: "square.and.arrow.down") }
                    .help("Export to Downloads").disabled(tools.logEntries.isEmpty)
                Button { tools.clearLog() } label: { Image(systemName: "trash") }.help("Clear")
            }
            ScrollViewReader { proxy in
                List(tools.logEntries) { e in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(e.time).foregroundStyle(.secondary)
                            Text(e.process).foregroundStyle(color(e.level)).fontWeight(.semibold)
                        }
                        Text(e.message).textSelection(.enabled).lineLimit(6)
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .id(e.id)
                }
                .onChange(of: tools.logEntries.last?.id) { _, last in
                    if autoScroll, let last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            Text("Filters apply on Return or Start. Last 2000 lines.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
    }

    private func color(_ level: String) -> Color {
        switch level.uppercased() {
        case "ERROR", "FAULT": return .red
        case "DEFAULT", "NOTICE": return .primary
        default: return .secondary
        }
    }
}
