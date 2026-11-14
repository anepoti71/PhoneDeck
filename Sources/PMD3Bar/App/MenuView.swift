import AppKit
import SwiftUI
import PMD3BarCore

struct MenuView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            deviceSection
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 360)
        // The first focusable control got keyboard focus when the menu opened, and a blue ring
        // around it (the Settings header, then the device row).
        .focusEffectDisabled()
        // Each row shows its own Developer Disk Image: check the iPhones never checked yet.
        .task {
            for device in model.devices where device.reachable && model.mountStates[device.id] == nil {
                await model.refreshMount(device.id)
            }
        }
    }

    // MARK: Devices

    @ViewBuilder private var deviceSection: some View {
        if PMD3.python == nil {
            Label("Python with pymobiledevice3 not found. Run `make python`.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        } else if model.devices.isEmpty {
            noDevice
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Devices (\(model.devices.count))")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.leading, 4)
                GroupBox {
                    VStack(spacing: 0) {
                        ForEach(Array(model.devices.enumerated()), id: \.element.id) { index, device in
                            if index > 0 { Divider().padding(.leading, 56).padding(.trailing, 8) }
                            row(device)
                        }
                    }
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
        return GroupBox {
            HStack(spacing: 10) {
                Image(systemName: "iphone.slash").font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No devices").font(.headline)
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
        }
    }

    private func row(_ device: Device) -> some View {
        let udid = device.id
        return DeviceRow(
            device: device,
            selected: udid == model.selectedUDID,
            mirror: model.sessions[udid],
            mountState: model.mountStates[udid] ?? .unknown,
            select: { model.select(udid) },
            openWindow: { MirrorWindows.shared.show(udid) },
            stop: { model.stopMirroring(udid) },
            mount: { Task { await model.mount(udid) } },
            power: { model.confirmPower($0, udid: udid) }
        )
    }

    // MARK: Settings

    @AppStorage("settingsExpanded") private var settingsExpanded = false

    /// Plain button instead of a DisclosureGroup: the DisclosureGroup took keyboard focus when the
    /// menu opened and drew its focus ring offset over the label.
    private var settings: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { settingsExpanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "gearshape")
                    Text("Settings")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(settingsExpanded ? 90 : 0))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(settingsExpanded ? "Hide settings" : "Show settings")
            .accessibilityLabel("Settings")
            .accessibilityValue(settingsExpanded ? "expanded" : "collapsed")

            if settingsExpanded {
                GroupBox { settingsContent }
                    .padding(.top, 8)
            }
        }
        .font(.caption)
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Mount the Developer Disk Image as soon as an iPhone connects", isOn: $model.autoMountDDI)
            Toggle("Notifications", isOn: $model.notificationsEnabled)
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
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Footer

    @State private var refreshing = false

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            settings
            HStack(spacing: 2) {
                Text("pymobiledevice3 \(model.pmd3Version)")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Group {
                    if refreshing {
                        ProgressView().controlSize(.mini).frame(width: 22, height: 18)
                    } else {
                        FooterButton(icon: "arrow.clockwise", help: "Refresh devices and Developer Disk Images") {
                            refreshing = true
                            Task {
                                await model.refreshDevices()
                                for device in model.devices where device.reachable {
                                    await model.refreshMount(device.id)
                                }
                                refreshing = false
                            }
                        }
                    }
                    FooterButton(icon: "doc.text.magnifyingglass", help: "Open the log") { model.openLog() }
                    FooterButton(icon: "power", help: "Quit PhoneDeck") { NSApplication.shared.terminate(nil) }
                        .keyboardShortcut("q")
                }
            }
            if model.updateAvailable, let latest = model.latestPMD3 {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.circle.fill").foregroundStyle(.blue)
                    Text("\(latest) available").font(.caption)
                    Spacer()
                    Button("What's new") { NSWorkspace.shared.open(AppModel.releasesURL) }
                    Button("Copy command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("PMD3_VERSION=\(latest) make lock && make python && make install", forType: .string)
                    }
                    .help("Run it in the project folder: installs the new version only if it passes the check")
                }
                .controlSize(.small)
            }
        }
    }
}

/// One device in the menu, with its own Developer Disk Image on the line below: click to select it;
/// the buttons on the right start its mirroring in its own window.
struct DeviceRow: View {
    let device: Device
    let selected: Bool
    let mirror: MirrorSession?
    let mountState: MountState
    let select: () -> Void
    let openWindow: () -> Void
    let stop: () -> Void
    let mount: () -> Void
    let power: (DeviceTools.PowerAction) -> Void
    @State private var hovering = false

    private var mirrorState: MirrorState { mirror?.state ?? .stopped }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: select) { label }
                .buttonStyle(.plain)
            HStack(spacing: 6) { mirrorButtons }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(hovering ? Color.primary.opacity(0.06) : .clear))
        .onHover { hovering = $0 }
        .contextMenu {
            if device.reachable {
                Button("Restart…") { power(.restart) }
                Button("Shut Down…") { power(.shutdown) }
            }
        }
    }

    private var label: some View {
        let detailStyle: AnyShapeStyle = device.reachable ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange)
        let linkIcon = device.hasUSB ? "cable.connector" : (device.reachable ? "wifi" : "wifi.slash")
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            Image(systemName: linkIcon)
                .frame(width: 16)
                .foregroundStyle(device.reachable ? AnyShapeStyle(.primary) : AnyShapeStyle(.orange))
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.body.weight(selected ? .semibold : .regular)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(detailStyle).lineLimit(2)
                if let err = device.unreachableError {
                    Text("Unlock the iPhone and check the Wi-Fi network (\(err))")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                if device.reachable && mountState != .unknown {
                    diskImage.padding(.top, 1)
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

    /// This iPhone's Developer Disk Image: a status dot, and Mount when it is missing.
    private var diskImage: some View {
        HStack(spacing: 6) {
            switch mountState {
            case .unknown, .checking: diskStatus("Disk Image: checking…", .secondary)
            case .mounted: diskStatus("Disk Image mounted", .green)
            case .notMounted: diskStatus("Disk Image not mounted", .orange)
            case .mounting: diskStatus("Disk Image mounting…", .secondary)
            case .failed(let msg): diskStatus("Disk Image: \(msg)", .red)
            }
            switch mountState {
            case .notMounted, .failed:
                Button("Mount", action: mount)
                    .controlSize(.mini)
                    .help("Needed for mirroring, simulated location and launching apps")
            case .checking, .mounting:
                ProgressView().controlSize(.mini)
            default:
                EmptyView()
            }
        }
    }

    private func diskStatus(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
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

/// Small icon button for the menu footer: borderless, highlighted on hover, name as tooltip.
private struct FooterButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 22, height: 18)
                .background(RoundedRectangle(cornerRadius: 4).fill(hovering ? Color.primary.opacity(0.1) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
    }
}
