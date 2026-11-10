import SwiftUI
import PMD3BarCore

/// Captures the iPhone's traffic to a .pcapng in ~/Downloads, with live totals per process.
struct NetworkTab: View {
    @Bindable var tool: NetworkCaptureTool
    let deviceName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Process name or PID (all if empty)", text: $tool.processFilter)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if !tool.running { tool.start(deviceName: deviceName) } }
                Picker("", selection: $tool.interface) {
                    ForEach(CaptureInterface.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            .disabled(tool.running)
            HStack {
                if tool.running {
                    Button { tool.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                } else {
                    Button { tool.start(deviceName: deviceName) } label: { Label("Capture", systemImage: "record.circle") }
                }
                if let stats = tool.stats {
                    Text("\(stats.packets) packets · \(bytes(stats.bytes)) · \(duration(stats.seconds))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else if tool.running {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if tool.file != nil && !tool.running {
                    Button { tool.openFile() } label: {
                        Label(NetworkCaptureTool.wiresharkURL != nil ? "Wireshark" : "Show", systemImage: "arrow.up.forward.app")
                    }
                    .help(NetworkCaptureTool.wiresharkURL != nil ? "Open the capture in Wireshark" : "Show the capture in Finder")
                }
            }
            if let err = tool.error { Text(err).font(.caption).foregroundStyle(.red) }
            List {
                if let stats = tool.stats, !stats.processes.isEmpty {
                    Section("Processes") {
                        ForEach(stats.processes) { row($0, total: stats.bytes) }
                    }
                    Section("Interfaces") {
                        ForEach(stats.interfaces) { row($0, total: stats.bytes) }
                    }
                }
            }
            .overlay {
                if (tool.stats?.packets ?? 0) == 0 {
                    Text(tool.running ? "Waiting for packets…" : "No capture yet").foregroundStyle(.secondary)
                }
            }
            if let file = tool.file {
                Text(file.lastPathComponent).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .onTapGesture { tool.revealFile() }
                    .help("Saved in Downloads: click to show it in Finder")
            }
            Text("Saved as .pcapng in Downloads, for Wireshark. Process names are cut at 16 characters by iOS. Unattributed packets show as \"unknown\".")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
    }

    private func row(_ e: CaptureStats.Entry, total: Int) -> some View {
        HStack {
            Text(e.name).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text("\(e.packets)").foregroundStyle(.secondary).monospacedDigit()
            Text(bytes(e.bytes)).frame(width: 70, alignment: .trailing).monospacedDigit()
        }
        .font(.callout)
        .help(total > 0 ? "\(Int((Double(e.bytes) / Double(total) * 100).rounded()))% of the bytes" : "")
    }

    private func bytes(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }

    private func duration(_ s: Double) -> String {
        let t = Int(s)
        return t >= 60 ? String(format: "%d:%02d", t / 60, t % 60) : "\(t)s"
    }
}
