import AppKit
import SwiftUI
import PMD3BarCore

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
            Label("Python with pymobiledevice3 not found. Run `make python`.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        } else if model.devices.isEmpty {
            noDevice
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Devices (\(model.devices.count))").font(.caption).foregroundStyle(.secondary)
                ForEach(model.devices) { device in
                    row(device)
                }
            }
            HStack {
                if model.devices.filter({ $0.reachable && $0.supportsMirroring }).count > 1 {
                    Button("All in grid") { MirrorWindows.shared.showGrid() }
                        .help("One window with all iPhones side by side")
                }
                if model.activeSessions.count > 1 {
                    Button("Stop all") { for s in model.activeSessions { s.stop() } }
                }
            }
            .font(.caption)
        }
    }

    private var noDevice: some View {
        let hint = model.deviceError
            ?? "Connect the iPhone via USB (the first time the cable is needed for pairing) or unlock it on the same Wi-Fi network."
        return HStack(spacing: 10) {
            Image(systemName: "iphone.slash").font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("No devices").font(.headline)
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
            Text("Needed for mirroring, simulated location and launching apps.")
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
            Button("Mount") { Task { await model.mount() } }
                .disabled(model.selectedDevice?.reachable != true)
        }
    }

    @ViewBuilder private var mountStatus: some View {
        switch model.mountState {
        case .unknown: status("—", .secondary)
        case .checking: status("Checking…", .secondary)
        case .mounted: status("Mounted", .green)
        case .notMounted: status("Not mounted", .orange)
        case .mounting: status("Mounting…", .secondary)
        case .failed(let msg): status(msg, .red)
        }
    }

    @AppStorage("settingsExpanded") private var settingsExpanded = false

    private var settings: some View {
        DisclosureGroup("Settings", isExpanded: $settingsExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Mount the Developer Disk Image as soon as an iPhone connects", isOn: $model.autoMountDDI)
                HStack {
                    Toggle("Notifications (connection, mount, installs, errors)", isOn: $model.notificationsEnabled)
                    Button("Test") { model.testNotification() }
                        .controlSize(.small)
                        .disabled(!model.notificationsEnabled)
                }
                Toggle("Shortcut ⌥⌘M: show/hide the selected iPhone's window", isOn: $model.hotKeyEnabled)
                if LoginItem.available {
                    Toggle("Launch at login", isOn: Binding(
                        get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                }
                HStack {
                    Text("Starting port")
                    TextField("", value: $model.httpPort, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .help("The first iPhone uses this port, the others the next free ones")
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
                Button("Refresh") {
                    Task {
                        await model.refreshDevices()
                        await model.refreshMount()
                    }
                }
                Button("Log") { model.openLog() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            Text("pymobiledevice3 \(model.pmd3Version)")
                .font(.caption2).foregroundStyle(.tertiary)
            if model.updateAvailable, let latest = model.latestPMD3 {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.circle.fill").foregroundStyle(.blue)
                    Text("\(latest) available").font(.caption)
                    Spacer()
                    Button("What's new") { NSWorkspace.shared.open(AppModel.releasesURL) }
                    Button("Copy command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("PMD3_VERSION=\(latest) make python && make install", forType: .string)
                    }
                    .help("Run it in the project folder: installs the new version only if it passes the check")
                }
                .controlSize(.small)
            }
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
                    Text("Unlock the iPhone and check the Wi-Fi network (\(err))")
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
        case .starting: s += " · starting…"
        case .failed(let msg): s += " · \(msg)"
        default: break
        }
        return s
    }

    @ViewBuilder private var mirrorButtons: some View {
        switch mirrorState {
        case .running:
            Button(action: openWindow) { Image(systemName: "macwindow") }
                .help("Show window")
            Button(action: stop) { Image(systemName: "stop.fill") }
                .help("Stop mirroring")
        case .starting, .stopping:
            ProgressView().controlSize(.small)
        case .stopped, .failed:
            if device.supportsMirroring {
                Button(action: openWindow) { Image(systemName: "play.fill") }
                    .help("Start mirroring in a window")
                    .disabled(!device.reachable)
            } else {
                Button(action: openWindow) { Image(systemName: "wrench.and.screwdriver") }
                    .help("Tools: apps, files, location, developer (mirroring needs iOS \(Device.mirrorMinimumIOS)+)")
                    .disabled(!device.reachable)
            }
        }
    }
}
