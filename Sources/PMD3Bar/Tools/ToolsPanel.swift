import SwiftUI
import PMD3BarCore

enum ToolTab: String, CaseIterable, Identifiable {
    case apps = "Apps", files = "Files", location = "Location", conditions = "Conditions",
         processes = "Processes", crashes = "Crashes", log = "Log", console = "Console", network = "Network",
         info = "Info"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .apps: return "square.grid.2x2"
        case .files: return "folder"
        case .location: return "location"
        case .conditions: return "gauge.with.dots.needle.33percent"
        case .processes: return "cpu"
        case .crashes: return "exclamationmark.triangle"
        case .log: return "text.alignleft"
        case .console: return "terminal"
        case .network: return "network"
        case .info: return "info.circle"
        }
    }
    var isDeveloper: Bool { ToolTab.developerTabs.contains(self) }
    static let developerTabs: [ToolTab] = [.conditions, .processes, .crashes, .log, .console, .network]
}

/// First level of the tools menu: developer tools are grouped under one entry.
enum ToolGroup: String, CaseIterable, Identifiable {
    case apps = "Apps", files = "Files", location = "Location", developer = "Developer", info = "Info"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .apps: return "square.grid.2x2"
        case .files: return "folder"
        case .location: return "location"
        case .developer: return "hammer"
        case .info: return "info.circle"
        }
    }
}

struct ToolsPanel: View {
    let model: AppModel
    let tools: DeviceTools
    let udid: String
    @Binding var tab: ToolTab
    @AppStorage("developerToolTab") private var lastDeveloperTab: ToolTab = .conditions

    private var group: Binding<ToolGroup> {
        Binding {
            switch tab {
            case .apps: return .apps
            case .files: return .files
            case .location: return .location
            case .info: return .info
            default: return .developer
            }
        } set: { g in
            switch g {
            case .apps: tab = .apps
            case .files: tab = .files
            case .location: tab = .location
            case .info: tab = .info
            case .developer: tab = lastDeveloperTab.isDeveloper ? lastDeveloperTab : .conditions
            }
        }
    }

    private var developerTab: Binding<ToolTab> {
        Binding { tab } set: { t in tab = t; lastDeveloperTab = t }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: group) {
                ForEach(ToolGroup.allCases) { g in
                    Image(systemName: g.icon).help(g.rawValue).tag(g)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10).padding(.top, 10)
            if tab.isDeveloper {
                // Names when the panel is wide enough, icons (with the name as tooltip) otherwise.
                ViewThatFits(in: .horizontal) {
                    developerPicker(icons: false)
                    developerPicker(icons: true)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            } else {
                Text(tab.rawValue).font(.headline).padding(.vertical, 6)
            }
            Divider()
            switch tab {
            case .apps: AppsTab(tools: tools) { tab = $0 }
            case .files: FilesTab(tools: tools)
            case .location: LocationTab(model: model, tools: tools, udid: udid)
            case .conditions: ConditionsTab(model: model, tool: tools.conditions, udid: udid)
            case .processes: ProcessesTab(tool: tools.processes)
            case .crashes: CrashesTab(tool: tools.crashes)
            case .log: LogTab(tools: tools)
            case .console: ConsoleTab(tool: tools.console)
            case .network: NetworkTab(tool: tools.capture, deviceName: model.device(udid)?.name ?? "iPhone")
            case .info: InfoTab(model: model, tools: tools, udid: udid)
            }
        }
    }
}

extension ToolsPanel {
    fileprivate func developerPicker(icons: Bool) -> some View {
        Picker("", selection: developerTab) {
            ForEach(ToolTab.developerTabs) { t in
                if icons {
                    Image(systemName: t.icon).help(t.rawValue).tag(t)
                } else {
                    Text(t.rawValue).tag(t)
                }
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
    }
}

/// Shown on tabs whose commands need the Developer Disk Image.
struct NeedsDDI: View {
    let model: AppModel
    let udid: String
    var body: some View {
        if model.mountStates[udid] == .notMounted {
            HStack {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text("Developer Disk Image needed").font(.caption)
                Spacer()
                Button("Mount") { Task { await model.mount(udid) } }
            }
        }
    }
}
