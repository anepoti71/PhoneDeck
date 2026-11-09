import SwiftUI
import PMD3BarCore

struct ProcessesTab: View {
    @Bindable var tool: ProcessesTool
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\ProcessesTool.Proc.cpu, order: .reverse)]
    @State private var confirmKill: ProcessesTool.Proc?

    private var rows: [ProcessesTool.Proc] {
        let filtered = search.isEmpty ? tool.processes
            : tool.processes.filter { $0.name.localizedCaseInsensitiveContains(search) || String($0.pid) == search }
        return filtered.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Cerca", text: $search).textFieldStyle(.roundedBorder)
                Toggle("Ogni 15 s", isOn: $tool.autoRefresh).toggleStyle(.checkbox).font(.caption)
                if tool.loading {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await tool.refresh() } } label: { Image(systemName: "arrow.clockwise") }.help("Aggiorna")
                }
            }
            if let err = tool.error { Text(err).font(.caption).foregroundStyle(.red) }
            Table(rows, sortOrder: $sortOrder) {
                TableColumn("Processo", value: \.name) { p in Text(p.name).lineLimit(1) }
                TableColumn("PID", value: \.pid) { p in Text(String(p.pid)).monospacedDigit() }
                    .width(50)
                TableColumn("CPU", value: \.cpu) { p in Text(String(format: "%.1f%%", p.cpu)).monospacedDigit() }
                    .width(56)
                TableColumn("Memoria", value: \.memory) { p in
                    Text(ByteCountFormatter.string(fromByteCount: p.memory, countStyle: .memory)).monospacedDigit()
                }
                .width(70)
            }
            .contextMenu(forSelectionType: ProcessesTool.Proc.ID.self) { ids in
                if let pid = ids.first, let p = tool.processes.first(where: { $0.pid == pid }) {
                    Button("Chiudi \(p.name)…", role: .destructive) { confirmKill = p }
                }
            }
            .overlay { if tool.loading && tool.processes.isEmpty { ProgressView("Campionamento…") } }
            Text(footer).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .task { if tool.processes.isEmpty { await tool.refresh() } }
        .confirmationDialog("Chiudere \(confirmKill?.name ?? "")?", isPresented: .init(
            get: { confirmKill != nil }, set: { if !$0 { confirmKill = nil } })
        ) {
            Button("Chiudi processo", role: .destructive) {
                if let p = confirmKill { Task { await tool.kill(p) } }
            }
        } message: {
            Text("Il processo viene terminato sull'iPhone. Le app si possono riaprire; i processi di sistema vengono riavviati da iOS.")
        }
    }

    private var footer: String {
        var s = "\(tool.processes.count) processi. Tasto destro per chiudere un processo. Richiede la Developer Disk Image."
        if let t = tool.lastUpdate { s = "Aggiornato alle \(t.formatted(date: .omitted, time: .standard)). " + s }
        return s
    }
}
