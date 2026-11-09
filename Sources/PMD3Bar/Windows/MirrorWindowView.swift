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
                    .overlay(Text("Rilascia: .ipa per installare, altri file in \(tools.filesPath)")
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
                    Text("Il mirroring dello schermo richiede iOS \(Device.mirrorMinimumIOS) o successivo.\nQuesto iPhone ha iOS \(device?.productVersion ?? "?").")
                        .multilineTextAlignment(.center)
                    Text("App, file, posizione e log funzionano: usa gli Strumenti.").font(.caption).foregroundStyle(.secondary)
                    Button("Mostra Strumenti") { showTools = true }
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
            placeholder { ProgressView("Avvio del mirroring…").controlSize(.large) }
        case .stopping:
            placeholder { ProgressView("Arresto…") }
        case .stopped:
            placeholder {
                VStack(spacing: 12) {
                    Image(systemName: "iphone.slash").font(.system(size: 44)).foregroundStyle(.secondary)
                    Text("Mirroring fermo")
                    Button("Avvia") { session.start() }.disabled(device?.reachable != true)
                }
            }
        case .failed(let msg):
            placeholder {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 40)).foregroundStyle(.orange)
                    Text(msg).multilineTextAlignment(.center).padding(.horizontal)
                    if model.mountStates[udid] == .notMounted {
                        Button("Monta Developer Disk Image") { Task { await model.mount(udid) } }
                    }
                    HStack {
                        Button("Riprova") { session.start() }
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
                Button { viewer.startRecording() } label: { Label("Registra", systemImage: "record.circle") }
                    .help("Registra lo schermo, con l'audio dell'iPhone, in Download")
                    .disabled(session.state != .running || !mirroringSupported)
            case .recording(let since):
                Button { viewer.stopRecording() } label: {
                    Label {
                        Text("Ferma registrazione")
                    } icon: {
                        Image(systemName: "stop.circle.fill").foregroundStyle(.red)
                    }
                }
                .help("Registrazione in corso da \(since.formatted(date: .omitted, time: .standard))")
            case .saving:
                ProgressView().controlSize(.small)
            }
            Button { NSWorkspace.shared.open(session.viewerURL) } label: { Label("Apri nel browser", systemImage: "safari") }
                .disabled(session.state != .running)
            if !mirroringSupported {
                EmptyView()
            } else if session.isActive {
                Button { session.stop() } label: { Label("Ferma", systemImage: "stop.fill") }
            } else {
                Button { session.start() } label: { Label("Avvia", systemImage: "play.fill") }
                    .disabled(device?.reachable != true)
            }
            Button { viewer.deviceOnly.toggle() } label: {
                Label(viewer.deviceOnly ? "Mostra controlli" : "Solo iPhone",
                      systemImage: viewer.deviceOnly ? "slider.horizontal.3" : "iphone")
            }
            .help(viewer.deviceOnly
                  ? "Mostra i controlli del viewer: zoom, rotazione, tasti, appunti, accessibilità"
                  : "Mostra solo l'iPhone")
            .disabled(!mirroringSupported)
            Button { showTools.toggle() } label: { Label("Strumenti", systemImage: "sidebar.right") }
                .help("App, file, posizione e log")
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
