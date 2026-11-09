import AppKit
import SwiftUI
import PMD3BarCore

struct MirrorWindowView: View {
    let model: AppModel
    let udid: String

    init(model: AppModel, udid: String) {
        self.model = model
        self.udid = udid
        _viewer = State(initialValue: ViewerController(udid: udid))
    }
    @State private var viewer: ViewerController
    @State private var showTools = false
    @AppStorage("toolTab") private var tab: ToolTab = .apps
    @State private var dropTargeted = false

    private var session: MirrorSession { model.session(for: udid) }
    private var tools: DeviceTools { model.tools(for: udid) }
    private var device: Device? { model.device(udid) }
    private var mirroringSupported: Bool { device?.supportsMirroring ?? true }

    var body: some View {
        ZStack(alignment: .bottom) {
            screen
            if let banner = tools.banner { BannerView(banner: banner) { tools.banner = nil } }
        }
        .frame(minWidth: 300, minHeight: 420)
        .background(Color.black)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 4)
                    .overlay(Text("Drop: .ipa to install, other files to \(tools.filesPath)")
                        .padding(8).background(.regularMaterial, in: Capsule()))
                    .padding(6)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .inspector(isPresented: $showTools) {
            // Built only while open: SwiftUI builds hidden inspector content too, and every tab
            // loads its data (apps, conditions, processes…) as soon as it appears.
            Group {
                if showTools { ToolsPanel(model: model, tools: tools, udid: udid, tab: $tab) }
            }
            .inspectorColumnWidth(min: 300, ideal: MirrorWindows.toolsWidth, max: 520)
        }
        .toolbar { toolbar }
        .navigationTitle(device?.name ?? "iPhone")
        .navigationSubtitle(subtitle)
        .onAppear {
            viewer.deviceName = device?.name ?? "iPhone"
            if !mirroringSupported { showTools = true }
            viewer.onCanvasRatio = { [udid] r in MirrorWindows.shared.updateFit(udid, ratio: r) }
            MirrorWindows.shared.updateFit(udid, deviceOnly: viewer.deviceOnly, tools: showTools)
        }
        .onChange(of: showTools) { _, on in MirrorWindows.shared.updateFit(udid, tools: on) }
        .onChange(of: viewer.deviceOnly) { _, on in MirrorWindows.shared.updateFit(udid, deviceOnly: on) }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let d = device { parts.append(d.connectionLabel) }
        if session.state == .running { parts.append(":\(session.port)") }
        if case .recording = viewer.recording { parts.append("● REC") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var screen: some View {
        if !mirroringSupported {
            placeholder {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.slash").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("Screen mirroring needs iOS \(Device.mirrorMinimumIOS) or later.\nThis iPhone has iOS \(device?.productVersion ?? "?").")
                        .multilineTextAlignment(.center)
                    Text("Apps, files, location and developer tools work: use Tools.").font(.caption).foregroundStyle(.secondary)
                    Button("Show Tools") { showTools = true }
                }
                .padding()
            }
        } else {
            mirrorScreen
        }
    }

    @ViewBuilder private var mirrorScreen: some View {
        switch session.state {
        case .running:
            ViewerWebView(url: session.viewerURL, generation: session.generation, controller: viewer)
        case .starting:
            placeholder { ProgressView("Starting mirroring…").controlSize(.large) }
        case .stopping:
            placeholder { ProgressView("Stopping…") }
        case .stopped:
            placeholder {
                VStack(spacing: 12) {
                    Image(systemName: "iphone.slash").font(.system(size: 44)).foregroundStyle(.secondary)
                    Text("Mirroring stopped")
                    Button("Start") { session.start() }.disabled(device?.reachable != true)
                }
            }
        case .failed(let msg):
            placeholder {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 40)).foregroundStyle(.orange)
                    Text(msg).multilineTextAlignment(.center).padding(.horizontal)
                    if model.mountStates[udid] == .notMounted {
                        Button("Mount Developer Disk Image") { Task { await model.mount(udid) } }
                    }
                    HStack {
                        Button("Retry") { session.start() }
                        Button("Log") { model.openLog() }
                    }
                }
            }
        }
    }

    private func placeholder<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content().frame(maxWidth: .infinity, maxHeight: .infinity).foregroundStyle(.white).environment(\.colorScheme, .dark)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            switch viewer.recording {
            case .idle:
                Button { viewer.startRecording() } label: { Label("Record", systemImage: "record.circle") }
                    .help("Record the screen, with the iPhone's audio, to Downloads")
                    .disabled(session.state != .running || !mirroringSupported)
            case .recording(let since):
                Button { viewer.stopRecording() } label: {
                    Label {
                        Text("Stop recording")
                    } icon: {
                        Image(systemName: "stop.circle.fill").foregroundStyle(.red)
                    }
                }
                .help("Recording since \(since.formatted(date: .omitted, time: .standard))")
            case .saving:
                ProgressView().controlSize(.small)
            }
            Button { NSWorkspace.shared.open(session.viewerURL) } label: { Label("Open in browser", systemImage: "safari") }
                .disabled(session.state != .running)
            if !mirroringSupported {
                EmptyView()
            } else if session.isActive {
                Button { session.stop() } label: { Label("Stop", systemImage: "stop.fill") }
            } else {
                Button { session.start() } label: { Label("Start", systemImage: "play.fill") }
                    .disabled(device?.reachable != true)
            }
            Button { viewer.deviceOnly.toggle() } label: {
                Label(viewer.deviceOnly ? "Show controls" : "iPhone only",
                      systemImage: viewer.deviceOnly ? "slider.horizontal.3" : "iphone")
            }
            .help(viewer.deviceOnly
                  ? "Show the viewer controls: zoom, rotation, buttons, clipboard, accessibility"
                  : "Show only the iPhone")
            .disabled(!mirroringSupported)
            Button { showTools.toggle() } label: { Label("Tools", systemImage: "sidebar.right") }
                .help("Apps, files, location and developer tools")
        }
    }

    private func handleDrop(_ urls: [URL]) {
        let ipas = urls.filter { ["ipa", "ipcc"].contains($0.pathExtension.lowercased()) }
        let others = urls.filter { !ipas.contains($0) }
        Task {
            for ipa in ipas { await tools.install(ipa) }
            if !others.isEmpty { await tools.upload(others) }
        }
    }
}

private struct BannerView: View {
    let banner: DeviceTools.Banner
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if banner.busy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(banner.isError ? .orange : .green)
            }
            Text(banner.text).lineLimit(3).font(.callout)
            if !banner.busy {
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(12)
        .task(id: banner) {
            guard !banner.busy, !banner.isError else { return }
            try? await Task.sleep(for: .seconds(4))
            dismiss()
        }
    }
}
