import SwiftUI
import PMD3BarCore

struct ConditionsTab: View {
    let model: AppModel
    @Bindable var tool: ConditionsTool
    let udid: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NeedsDDI(model: model, udid: udid)
            HStack {
                status
                Spacer()
                if case .active = tool.state {
                    Button("Deactivate") { tool.deactivate() }
                } else if case .starting = tool.state {
                    Button("Cancel") { tool.deactivate() }
                }
                Button { Task { await tool.refresh() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
            }
            if let err = tool.error { Text(err).font(.caption).foregroundStyle(.red) }
            List {
                ForEach(tool.groups) { group in
                    Section(Self.title(group)) {
                        ForEach(group.profiles) { profile in
                            HStack {
                                Text(profile.name)
                                Spacer()
                                if isCurrent(profile) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                } else {
                                    Button("Activate") { tool.activate(profile) }
                                        .controlSize(.small)
                                        .disabled(isStarting)
                                }
                            }
                            .help(profile.description ?? profile.name)
                        }
                    }
                }
            }
            .overlay { if tool.loading && tool.groups.isEmpty { ProgressView() } }
            Text("One condition at a time. It stays active while the window is open; closing it returns the iPhone to normal.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .task { if tool.groups.isEmpty { await tool.refresh() } }
    }

    private static func title(_ g: ConditionsTool.Group) -> String {
        switch g.identifier {
        case "SlowNetworkCondition": return "Network"
        case "ThermalCondition": return "Thermal state"
        case "GPUPerformanceState": return "GPU performance"
        default: return g.name
        }
    }

    private var isStarting: Bool { if case .starting = tool.state { return true }; return false }

    private func isCurrent(_ p: ConditionsTool.Profile) -> Bool {
        switch tool.state {
        case .active(let a), .starting(let a): return a == p
        default: return false
        }
    }

    @ViewBuilder private var status: some View {
        switch tool.state {
        case .off: Label("No condition", systemImage: "circle").foregroundStyle(.secondary).font(.caption)
        case .starting(let p): Label("Activating \(p.name)…", systemImage: "hourglass").font(.caption)
        case .active(let p): Label(p.name, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        case .failed(let msg): Text(msg).foregroundStyle(.red).font(.caption).lineLimit(2)
        }
    }
}
