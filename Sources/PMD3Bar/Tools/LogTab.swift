import SwiftUI
import PMD3BarCore

struct LogTab: View {
    @Bindable var tools: DeviceTools
    @State private var autoScroll = true

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Processo (es. SpringBoard)", text: $tools.logProcessFilter).textFieldStyle(.roundedBorder)
                TextField("Testo", text: $tools.logTextFilter).textFieldStyle(.roundedBorder)
            }
            .onSubmit { tools.startLog() }
            HStack {
                if tools.logRunning {
                    Button { tools.stopLog() } label: { Label("Ferma", systemImage: "pause.fill") }
                } else {
                    Button { tools.startLog() } label: { Label("Avvia", systemImage: "play.fill") }
                }
                Toggle("Info", isOn: $tools.logIncludeInfo).toggleStyle(.checkbox)
                    .help("Includi i messaggi di livello Info (molto più numerosi)")
                Toggle("Scorri", isOn: $autoScroll).toggleStyle(.checkbox)
                Spacer()
                Button { tools.exportLog() } label: { Image(systemName: "square.and.arrow.down") }
                    .help("Esporta in Download").disabled(tools.logEntries.isEmpty)
                Button { tools.clearLog() } label: { Image(systemName: "trash") }.help("Svuota")
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
            Text("Filtri applicati con Invio o Avvia. Ultime 2000 righe.")
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
