import SwiftUI

@main
struct PMD3BarApp: App {
    @State private var model: AppModel

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        MirrorWindows.shared.model = model
        // `open PMD3Bar.app --args --open <UDID>` starts mirroring that iPhone in its window at launch.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--open"), i + 1 < args.count {
            let udid = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MirrorWindows.shared.show(udid) }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            Image(systemName: menuIcon)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuIcon: String {
        if !model.activeSessions.isEmpty { return "iphone.radiowaves.left.and.right" }
        return model.devices.isEmpty ? "iphone.slash" : "iphone"
    }
}

struct MenuView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            deviceSection
            if model.selectedDevice != nil {
                Divider()
                mountSection
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 350)
    }

    // MARK: Sections

    @ViewBuilder private var deviceSection: some View {
        if PMD3.python == nil {
            Label("Python con pymobiledevice3 non trovato. Esegui `make python`.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        } else if model.devices.isEmpty {
            noDevice
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Dispositivi (\(model.devices.count))").font(.caption).foregroundStyle(.secondary)
                ForEach(model.devices) { device in
                    row(device)
                }
            }
            if model.activeSessions.count > 1 {
                Button("Ferma tutti i mirroring") { for s in model.activeSessions { s.stop() } }
                    .font(.caption)
            }
        }
    }

    private var noDevice: some View {
        let hint = model.deviceError
            ?? "Collega l'iPhone via USB (la prima volta serve il cavo per l'abbinamento) oppure sbloccalo sulla stessa rete Wi-Fi."
        return HStack(spacing: 10) {
            Image(systemName: "iphone.slash").font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Nessun dispositivo").font(.headline)
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ device: Device) -> some View {
        let udid = device.id
        return DeviceRow(
            device: device,
            selected: udid == model.selectedUDID,
            mirror: model.sessions[udid],
            select: { model.select(udid) },
            openWindow: { MirrorWindows.shared.show(udid) },
            stop: { model.stopMirroring(udid) }
        )
    }

    @ViewBuilder private var mountSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Developer Disk Image · \(model.selectedDevice?.name ?? "")")
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                mountStatus
            }
            Spacer()
            mountButton
        }
        if model.mountState == .notMounted {
            Text("Serve per mirroring, posizione simulata e avvio app.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var mountButton: some View {
        switch model.mountState {
        case .mounting, .checking:
            ProgressView().controlSize(.small)
        case .mounted:
            EmptyView()
        default:
            Button("Monta") { Task { await model.mount() } }
                .disabled(model.selectedDevice?.reachable != true)
        }
    }

    @ViewBuilder private var mountStatus: some View {
        switch model.mountState {
        case .unknown: status("—", .secondary)
        case .checking: status("Verifica…", .secondary)
        case .mounted: status("Montata", .green)
        case .notMounted: status("Non montata", .orange)
        case .mounting: status("Montaggio in corso…", .secondary)
        case .failed(let msg): status(msg, .red)
        }
    }

    @AppStorage("settingsExpanded") private var settingsExpanded = false

    private var settings: some View {
        DisclosureGroup("Impostazioni", isExpanded: $settingsExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Monta la Developer Disk Image appena colleghi un iPhone", isOn: $model.autoMountDDI)
                Toggle("Notifiche (collegamento, montaggio, installazioni, errori)", isOn: $model.notificationsEnabled)
                Toggle("Scorciatoia ⌥⌘M: mostra/nascondi la finestra dell'iPhone selezionato", isOn: $model.hotKeyEnabled)
                if LoginItem.available {
                    Toggle("Avvia al login", isOn: Binding(
                        get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                }
                HStack {
                    Text("Porta iniziale")
                    TextField("", value: $model.httpPort, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .help("Il primo iPhone usa questa porta, gli altri le successive libere")
                }
                if let err = model.settingsError {
                    Text(err).foregroundStyle(.red)
                }
            }
            .toggleStyle(.checkbox)
            .font(.caption)
            .padding(.top, 4)
        }
        .font(.caption)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            settings
            HStack {
                Button("Aggiorna") {
                    Task {
                        await model.refreshDevices()
                        await model.refreshMount()
                    }
                }
                Button("Log") { model.openLog() }
                Spacer()
                Button("Esci") { NSApplication.shared.terminate(nil) }
            }
            Text("pymobiledevice3 \(model.pmd3Version) · \(PMD3.python?.source.rawValue ?? "—")")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func status(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(3)
        }
    }
}

/// One device in the menu: click to select it (the Developer Disk Image section follows the selection);
/// the button on the right starts its mirroring in its own window.
struct DeviceRow: View {
    let device: Device
    let selected: Bool
    let mirror: MirrorSession?
    let select: () -> Void
    let openWindow: () -> Void
    let stop: () -> Void
    @State private var hovering = false

    private var mirrorState: MirrorState { mirror?.state ?? .stopped }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: select) { label }
                .buttonStyle(.plain)
            mirrorButtons
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.08) : .clear))
        .onHover { hovering = $0 }
    }

    private var label: some View {
        let detailStyle: AnyShapeStyle = device.reachable ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange)
        let linkIcon = device.hasUSB ? "cable.connector" : (device.reachable ? "wifi" : "wifi.slash")
        return HStack(spacing: 8) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            Image(systemName: linkIcon)
                .frame(width: 16)
                .foregroundStyle(device.reachable ? AnyShapeStyle(.primary) : AnyShapeStyle(.orange))
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).font(.body.weight(selected ? .semibold : .regular)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(detailStyle).lineLimit(2)
                if let err = device.unreachableError {
                    Text("Sblocca l'iPhone e verifica la rete Wi-Fi (\(err))")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 4)
        }
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        var s = "iOS \(device.productVersion) · \(device.connectionLabel)"
        switch mirrorState {
        case .running: s += " · :\(mirror?.port ?? 0)"
        case .starting: s += " · avvio…"
        case .failed(let msg): s += " · \(msg)"
        default: break
        }
        return s
    }

    @ViewBuilder private var mirrorButtons: some View {
        switch mirrorState {
        case .running:
            Button(action: openWindow) { Image(systemName: "macwindow") }
                .help("Mostra la finestra")
            Button(action: stop) { Image(systemName: "stop.fill") }
                .help("Ferma il mirroring")
        case .starting, .stopping:
            ProgressView().controlSize(.small)
        case .stopped, .failed:
            if device.supportsMirroring {
                Button(action: openWindow) { Image(systemName: "play.fill") }
                    .help("Avvia il mirroring in una finestra")
                    .disabled(!device.reachable)
            } else {
                Button(action: openWindow) { Image(systemName: "wrench.and.screwdriver") }
                    .help("Strumenti: app, file, posizione, log (il mirroring richiede iOS \(Device.mirrorMinimumIOS)+)")
                    .disabled(!device.reachable)
            }
        }
    }
}
