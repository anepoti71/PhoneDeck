import AppKit
import SwiftUI
import PMD3BarCore

/// Identity, storage and battery of the iPhone, plus restart and shut down.
struct InfoTab: View {
    let model: AppModel
    let tools: DeviceTools
    let udid: String
    @State private var confirmPower: DeviceTools.PowerAction?

    private var deviceName: String { model.device(udid)?.name ?? "iPhone" }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button("Restart…") { confirmPower = .restart }
                Button("Shut Down…") { confirmPower = .shutdown }
                Spacer()
                Button { Task { await tools.refreshInfo() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
            }
            .padding(.horizontal, 10).padding(.top, 8)
            if let err = tools.infoError { Text(err).font(.caption).foregroundStyle(.red).padding(.horizontal, 10) }
            if let info = tools.info {
                Form {
                    if let battery = info.battery { batterySection(battery) }
                    if let storage = info.storage { storageSection(storage) }
                    Section("Device") {
                        ForEach(info.rows) { row in
                            LabeledContent(row.label) {
                                Text(row.value).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                            }
                            .contextMenu {
                                Button("Copy \(row.label)") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(row.value, forType: .string)
                                }
                            }
                        }
                    }
                    if !info.errors.isEmpty {
                        Section {
                            ForEach(info.errors, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                .formStyle(.grouped)
            } else {
                Spacer()
                if tools.infoLoading { ProgressView() }
                Spacer()
            }
        }
        .task { if tools.info == nil { await tools.refreshInfo() } }
        .confirmationDialog("\(confirmPower?.rawValue ?? "") \(deviceName)?", isPresented: .init(
            get: { confirmPower != nil }, set: { if !$0 { confirmPower = nil } })
        ) {
            if let action = confirmPower {
                Button(action.rawValue, role: .destructive) {
                    Task { await model.power(action, udid: udid) }
                }
            }
        } message: {
            Text(confirmPower == .shutdown
                 ? "Mirroring and running tools stop. The iPhone has to be turned on again by hand."
                 : "Mirroring and running tools stop until the iPhone is back.")
        }
    }

    private func batterySection(_ b: DeviceInfo.Battery) -> some View {
        Section("Battery") {
            if let pct = b.percent {
                LabeledContent("Charge") {
                    HStack(spacing: 6) {
                        Image(systemName: b.charging ? "battery.100.bolt" : batteryIcon(pct))
                            .foregroundStyle(pct <= 20 && !b.charging ? .red : .primary)
                        Text("\(pct)%" + (b.charging ? " · charging" : b.pluggedIn ? " · plugged in" : ""))
                    }
                }
            }
            if let h = b.health {
                LabeledContent("Maximum capacity") {
                    Text("\(h)%").foregroundStyle(h < 80 ? .orange : .primary)
                }
            }
            if let c = b.cycles { LabeledContent("Cycles", value: "\(c)") }
            if let t = b.temperatureC {
                LabeledContent("Temperature", value: t.formatted(.number.precision(.fractionLength(1))) + " °C")
            }
        }
    }

    private func storageSection(_ s: DeviceInfo.Storage) -> some View {
        Section("Storage") {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: s.usedFraction)
                    .tint(s.usedFraction > 0.9 ? .red : .accentColor)
                Text("\(bytes(s.used)) used of \(bytes(s.total)) · \(bytes(s.available)) free")
                    .font(.caption).foregroundStyle(.secondary)
                if let more = s.availableWithPurgeable {
                    Text("\(bytes(more)) free once iOS clears purgeable data (caches, offloadable apps)")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    private func batteryIcon(_ pct: Int) -> String {
        switch pct {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }
}
