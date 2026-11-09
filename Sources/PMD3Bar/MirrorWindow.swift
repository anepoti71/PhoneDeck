import AppKit
import MapKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// MARK: - Window management

/// One native window per mirrored iPhone. Closing the window stops that iPhone's stream.
@MainActor
final class MirrorWindows: NSObject, NSWindowDelegate {
    static let shared = MirrorWindows()
    private var windows: [String: NSWindow] = [:]
    weak var model: AppModel?

    /// What the window size follows: in "device only" mode with the tools closed, the window is
    /// as wide as the iPhone screen needs for its height (and keeps that shape when resized).
    private struct Fit {
        var ratio: Double?
        var deviceOnly = true
        var tools = false
        var active: Bool { deviceOnly && !tools && ratio != nil }
    }
    private var fits: [String: Fit] = [:]
    /// Width the tools panel takes (inspectorColumnWidth ideal).
    static let toolsWidth: CGFloat = 340
    private static let minWidth: CGFloat = 300

    /// Reports a change of screen proportions, layout mode or tools panel for a window.
    func updateFit(_ udid: String, ratio: Double? = nil, deviceOnly: Bool? = nil, tools: Bool? = nil) {
        var fit = fits[udid] ?? Fit()
        let wasTools = fit.tools
        if let ratio { fit.ratio = ratio }
        if let deviceOnly { fit.deviceOnly = deviceOnly }
        if let tools { fit.tools = tools }
        let firstReport = fits[udid] == nil
        fits[udid] = fit
        guard let w = windows[udid] else { return }
        if !firstReport, let tools, tools != wasTools, tools {
            // Make room for the panel instead of squeezing the iPhone.
            resize(w, widthBy: Self.toolsWidth)
            return
        }
        if fit.active { fitToScreen(w, fit) }
    }

    private func fitToScreen(_ w: NSWindow, _ fit: Fit) {
        guard let web = webView(in: w), let ratio = fit.ratio else { return }
        let target = Self.viewportWidth(forHeight: web.bounds.height, ratio: ratio)
        resize(w, widthBy: target - web.bounds.width)
    }

    /// Viewport width that lets the screen fill the viewport height (see ViewerLayout).
    private static func viewportWidth(forHeight height: CGFloat, ratio: Double) -> CGFloat {
        ViewerLayout.reservedWidth + max(100, height - ViewerLayout.ownReservedHeight) * CGFloat(ratio)
    }

    private func resize(_ w: NSWindow, widthBy delta: CGFloat) {
        guard abs(delta) > 1 else { return }
        var frame = w.frame
        let newWidth = max(Self.minWidth, frame.width + delta)
        frame.origin.x += (frame.width - newWidth) / 2  // keep the window centred where it is
        frame.size.width = newWidth
        w.setFrame(frame, display: true, animate: true)
    }

    private func webView(in w: NSWindow) -> WKWebView? {
        func find(_ v: NSView) -> WKWebView? {
            if let web = v as? WKWebView { return web }
            for sub in v.subviews { if let web = find(sub) { return web } }
            return nil
        }
        return w.contentView.flatMap(find)
    }

    /// While fitting, resizing keeps the window around the iPhone: the width follows the height.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard let udid = sender.identifier?.rawValue, let fit = fits[udid], fit.active,
              let ratio = fit.ratio, let web = webView(in: sender) else { return frameSize }
        let chromeW = sender.frame.width - web.bounds.width
        let chromeH = sender.frame.height - web.bounds.height
        let width = chromeW + Self.viewportWidth(forHeight: frameSize.height - chromeH, ratio: ratio)
        return NSSize(width: max(Self.minWidth, width), height: frameSize.height)
    }

    func show(_ udid: String) {
        guard let model else { return }
        // Session and tools exist before the view renders (no state changes during a view update).
        _ = model.tools(for: udid)
        let session = model.session(for: udid)
        // Below iOS 27 there is no screen streaming: the window still offers the tools.
        if !session.isActive, model.device(udid)?.supportsMirroring != false { model.startMirroring(udid) }
        if let w = windows[udid] {
            activate(w)
            return
        }
        let name = model.device(udid)?.name ?? "iPhone"
        let content = MirrorWindowView(model: model, udid: udid)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.title = name
        w.contentViewController = NSHostingController(rootView: content)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setFrameAutosaveName("PMD3Bar.mirror.\(udid)")
        if !w.setFrameUsingName("PMD3Bar.mirror.\(udid)") { w.center() }
        w.identifier = NSUserInterfaceItemIdentifier(udid)
        windows[udid] = w
        // Windows open: behave like a regular app (Dock, Cmd-Tab); back to menu-bar only when all close.
        NSApp.setActivationPolicy(.regular)
        activate(w)
    }

    /// ⌥⌘M: closes the window if it is the one in front, otherwise shows it.
    func toggle(_ udid: String) {
        if let w = windows[udid], w.isKeyWindow, NSApp.isActive {
            w.performClose(nil)
        } else {
            show(udid)
        }
    }

    private func activate(_ w: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    // MARK: Grid

    private var gridWindow: NSWindow?
    /// Sessions the grid started itself: closing the grid stops them unless they have their own window.
    private var gridStarted: Set<String> = []

    /// One window with every iPhone that can be mirrored, side by side, showing only the iPhones.
    func showGrid() {
        guard let model else { return }
        for d in model.devices where d.reachable && d.supportsMirroring {
            let s = model.session(for: d.id)
            if !s.isActive {
                model.startMirroring(d.id)
                gridStarted.insert(d.id)
            }
        }
        if let w = gridWindow { activate(w); return }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.title = "Tutti gli iPhone"
        w.contentViewController = NSHostingController(rootView: GridView(model: model))
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setFrameAutosaveName("PMD3Bar.grid")
        if !w.setFrameUsingName("PMD3Bar.grid") { w.center() }
        w.identifier = NSUserInterfaceItemIdentifier(Self.gridID)
        gridWindow = w
        NSApp.setActivationPolicy(.regular)
        activate(w)
    }

    private static let gridID = "PMD3Bar.grid"

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, let id = w.identifier?.rawValue else { return }
        if id == Self.gridID {
            gridWindow = nil
            for udid in gridStarted where windows[udid] == nil { model?.stopMirroring(udid) }
            gridStarted.removeAll()
            if windows.isEmpty { NSApp.setActivationPolicy(.accessory) }
            return
        }
        let udid = id
        gridStarted.remove(udid)
        windows[udid] = nil
        fits[udid] = nil
        // The grid may still be showing this iPhone: keep its stream then.
        model?.closeWindow(udid, keepMirroring: gridWindow != nil)
        if windows.isEmpty && gridWindow == nil { NSApp.setActivationPolicy(.accessory) }
    }
}

// MARK: - Grid content

struct GridView: View {
    let model: AppModel
    /// One viewer controller per iPhone, made on first use. A plain (unobserved) cache, so a cell
    /// can create its controller while rendering instead of waiting for onAppear/onChange.
    @State private var cache = ControllerCache()

    final class ControllerCache {
        private var controllers: [String: ViewerController] = [:]
        @MainActor func controller(for udid: String, name: String) -> ViewerController {
            if let c = controllers[udid] { return c }
            let c = ViewerController(deviceOnly: true)  // grid: always only the iPhones, not remembered
            c.deviceName = name
            controllers[udid] = c
            return c
        }
    }

    private var sessions: [MirrorSession] { model.activeSessions }

    var body: some View {
        Group {
            if sessions.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "iphone.slash").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("Nessun iPhone in mirroring").foregroundStyle(.white)
                    Text("Servono iPhone con iOS \(Device.mirrorMinimumIOS) o successivo, raggiungibili.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 1) {
                    ForEach(sessions) { s in cell(s) }
                }
            }
        }
        .background(Color.black)
    }

    @ViewBuilder private func cell(_ s: MirrorSession) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(model.device(s.udid)?.name ?? "iPhone").font(.caption.weight(.semibold))
                Spacer()
                Button { MirrorWindows.shared.show(s.udid) } label: { Image(systemName: "macwindow") }
                    .buttonStyle(.borderless).help("Apri nella sua finestra (con gli Strumenti)")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.top, 6)
            if s.state == .running {
                ViewerWebView(url: s.viewerURL, generation: s.generation,
                              controller: cache.controller(for: s.udid, name: model.device(s.udid)?.name ?? "iPhone"))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).environment(\.colorScheme, .dark)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

// MARK: - Window content

enum ToolTab: String, CaseIterable, Identifiable {
    case apps = "App", files = "File", location = "Posizione", conditions = "Condizioni",
         processes = "Processi", crashes = "Crash", log = "Log"
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
        }
    }
}

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

// MARK: - Tools panel

struct ToolsPanel: View {
    let model: AppModel
    let tools: DeviceTools
    let udid: String
    @Binding var tab: ToolTab

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(ToolTab.allCases) { t in
                    Image(systemName: t.icon).help(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10).padding(.top, 10)
            Text(tab.rawValue).font(.headline).padding(.vertical, 6)
            Divider()
            switch tab {
            case .apps: AppsTab(tools: tools)
            case .files: FilesTab(tools: tools)
            case .location: LocationTab(model: model, tools: tools, udid: udid)
            case .conditions: ConditionsTab(model: model, tool: tools.conditions, udid: udid)
            case .processes: ProcessesTab(tool: tools.processes)
            case .crashes: CrashesTab(tool: tools.crashes)
            case .log: LogTab(tools: tools)
            }
        }
    }
}

private struct AppsTab: View {
    let tools: DeviceTools
    @State private var search = ""
    @State private var confirmUninstall: DeviceTools.AppInfo?

    private var filtered: [DeviceTools.AppInfo] {
        search.isEmpty ? tools.apps : tools.apps.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.bundle_id.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Cerca", text: $search).textFieldStyle(.roundedBorder)
                Button { pickIPA() } label: { Label("Installa .ipa", systemImage: "plus") }
                Button { Task { await tools.refreshApps() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Aggiorna")
            }
            .padding(.horizontal, 10).padding(.top, 8)
            if let err = tools.appsError { Text(err).font(.caption).foregroundStyle(.red).padding(.horizontal, 10) }
            List(filtered) { app in
                HStack {
                    Group {
                        if let img = tools.icon(for: app.bundle_id) {
                            Image(nsImage: img).resizable().interpolation(.high)
                        } else {
                            RoundedRectangle(cornerRadius: 7).fill(.quaternary)
                        }
                    }
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name).lineLimit(1)
                        Text("\(app.bundle_id) · \(app.version)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { Task { await tools.launch(app) } } label: { Image(systemName: "play.circle") }
                        .buttonStyle(.borderless).help("Avvia")
                }
                .contextMenu {
                    Button("Avvia") { Task { await tools.launch(app) } }
                    Button("Copia bundle ID") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(app.bundle_id, forType: .string)
                    }
                    Divider()
                    Button("Disinstalla…", role: .destructive) { confirmUninstall = app }
                }
            }
            .overlay { if tools.appsLoading && tools.apps.isEmpty { ProgressView() } }
            Text("Trascina un .ipa sulla finestra per installarlo. Avvia richiede la Developer Disk Image.")
                .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 8)
        }
        .task { if tools.apps.isEmpty { await tools.refreshApps() } }
        .confirmationDialog("Disinstallare \(confirmUninstall?.name ?? "")?", isPresented: .init(
            get: { confirmUninstall != nil }, set: { if !$0 { confirmUninstall = nil } })
        ) {
            Button("Disinstalla", role: .destructive) {
                if let app = confirmUninstall { Task { await tools.uninstall(app) } }
            }
        } message: {
            Text("L'app e tutti i suoi dati verranno eliminati dall'iPhone.")
        }
    }

    private func pickIPA() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ipa") ?? .data]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        Task { for url in panel.urls { await tools.install(url) } }
    }
}

private struct FilesTab: View {
    let tools: DeviceTools
    @State private var confirmDelete: DeviceTools.FileEntry?

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button { Task { await tools.goUp() } } label: { Image(systemName: "chevron.up") }
                    .disabled(tools.filesPath == "/").help("Cartella superiore")
                Text(tools.filesPath).font(.callout.monospaced()).lineLimit(1).truncationMode(.head)
                Spacer()
                Button { pickUpload() } label: { Image(systemName: "square.and.arrow.up") }.help("Carica qui")
                Button { Task { await tools.refreshFiles() } } label: { Image(systemName: "arrow.clockwise") }.help("Aggiorna")
            }
            .padding(.horizontal, 10).padding(.top, 8)
            if let err = tools.filesError { Text(err).font(.caption).foregroundStyle(.red).padding(.horizontal, 10) }
            List(tools.files) { entry in
                HStack {
                    Image(systemName: entry.dir ? "folder.fill" : "doc").foregroundStyle(entry.dir ? Color.accentColor : .secondary)
                    Text(entry.name).lineLimit(1)
                    Spacer()
                    if !entry.dir {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    if entry.dir { Task { await tools.openDirectory(tools.path(for: entry)) } }
                }
                .contextMenu {
                    if entry.dir { Button("Apri") { Task { await tools.openDirectory(tools.path(for: entry)) } } }
                    Button("Scarica in Download") { Task { await tools.download(entry) } }
                    Divider()
                    Button("Elimina…", role: .destructive) { confirmDelete = entry }
                }
            }
            .overlay { if tools.filesLoading && tools.files.isEmpty { ProgressView() } }
            Text("Cartella Media dell'iPhone (foto in DCIM). Doppio clic per aprire, tasto destro per scaricare. Trascina file sulla finestra per copiarli qui.")
                .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 8)
        }
        .task { if tools.files.isEmpty { await tools.refreshFiles() } }
        .confirmationDialog("Eliminare \(confirmDelete?.name ?? "")?", isPresented: .init(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })
        ) {
            Button("Elimina", role: .destructive) {
                if let e = confirmDelete { Task { await tools.delete(e) } }
            }
        } message: {
            Text(confirmDelete?.dir == true ? "La cartella e tutto il suo contenuto verranno eliminati dall'iPhone." : "Il file verrà eliminato dall'iPhone.")
        }
    }

    private func pickUpload() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        Task { await tools.upload(panel.urls) }
    }
}

private struct LocationTab: View {
    let model: AppModel
    let tools: DeviceTools
    let udid: String
    @State private var position: MapCameraPosition = .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 41.9028, longitude: 12.4964),
        span: MKCoordinateSpan(latitudeDelta: 8, longitudeDelta: 8)))
    @State private var pin: CLLocationCoordinate2D?
    @State private var latText = ""
    @State private var lonText = ""
    @State private var search = ""
    /// Once the user picks a point, the map stops following the Mac's position.
    @State private var userMoved = false
    private var mac: MacLocation { MacLocation.shared }

    private static let presets: [(String, Double, Double)] = [
        ("Roma", 41.9028, 12.4964), ("Milano", 45.4642, 9.1900), ("Londra", 51.5074, -0.1278),
        ("New York", 40.7128, -74.0060), ("Cupertino", 37.3349, -122.0090), ("Tokyo", 35.6762, 139.6503),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.mountStates[udid] == .notMounted {
                HStack {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text("Serve la Developer Disk Image").font(.caption)
                    Spacer()
                    Button("Monta") { Task { await model.mount(udid) } }
                }
            }
            HStack {
                TextField("Cerca un luogo", text: $search).textFieldStyle(.roundedBorder).onSubmit { geocode() }
                Button { centerOnMac() } label: { Image(systemName: "location.circle") }
                    .help("Centra sulla posizione del Mac (vicino all'iPhone)")
                Menu("Città") {
                    ForEach(Self.presets, id: \.0) { p in
                        Button(p.0) { choose(CLLocationCoordinate2D(latitude: p.1, longitude: p.2), zoom: true) }
                    }
                }
                .fixedSize()
            }
            MapReader { proxy in
                Map(position: $position) {
                    if let c = mac.coordinate {
                        Annotation("Questo Mac", coordinate: c) {
                            Image(systemName: "laptopcomputer").font(.caption).padding(4)
                                .background(.gray, in: Circle()).foregroundStyle(.white)
                        }
                    }
                    if let last = tools.lastSimulated, !isActive {
                        Marker("Ultima simulata", systemImage: "clock.arrow.circlepath", coordinate: last).tint(.gray)
                    }
                    if let pin { Marker("", coordinate: pin).tint(.red) }
                    if case .active(let c) = tools.locationState {
                        Annotation("iPhone", coordinate: c) {
                            Image(systemName: "iphone.gen3").padding(4).background(.blue, in: Circle()).foregroundStyle(.white)
                        }
                    }
                }
                .onTapGesture { point in
                    if let c = proxy.convert(point, from: .local) { choose(c, zoom: false) }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(minHeight: 260)
            HStack {
                TextField("Latitudine", text: $latText).textFieldStyle(.roundedBorder)
                TextField("Longitudine", text: $lonText).textFieldStyle(.roundedBorder)
            }
            HStack {
                Button("Imposta posizione") {
                    if let c = coordinateFromFields() { tools.setLocation(c) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(coordinateFromFields() == nil || tools.locationState == .starting)
                Button("Ripristina reale") { Task { await tools.clearLocation() } }
                    .disabled(tools.locationState == .off)
                Spacer()
                locationStatus
            }
            macStatus
            Text("Clic sulla mappa per scegliere il punto. La posizione resta simulata finché la finestra è aperta; chiudendola torna quella reale. L'iPhone non comunica al Mac la sua posizione reale: la mappa parte dal Mac, che è vicino, o dall'ultima posizione simulata.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .onAppear(perform: initialCamera)
        .onChange(of: mac.coordinate?.latitude) { _, _ in
            // First fix of the Mac's position: follow it unless something better is already shown.
            if !userMoved, !isActive, tools.lastSimulated == nil, let c = mac.coordinate { focus(c, span: 0.02) }
        }
    }

    private var isActive: Bool {
        if case .active = tools.locationState { return true }
        return false
    }

    @ViewBuilder private var macStatus: some View {
        switch mac.status {
        case .denied:
            Text("Posizione del Mac non disponibile: consentila in Impostazioni di Sistema ▸ Privacy e sicurezza ▸ Localizzazione ▸ PMD3Bar.")
                .font(.caption2).foregroundStyle(.orange)
        case .failed(let msg):
            Text("Posizione del Mac non disponibile (\(msg)).").font(.caption2).foregroundStyle(.orange)
        case .locating:
            Label("Cerco la posizione del Mac…", systemImage: "location").font(.caption2).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    /// Start from what is known about the iPhone: its active simulated position, the last one
    /// simulated, or else the Mac's position (asked now, applied when it arrives).
    private func initialCamera() {
        if case .active(let c) = tools.locationState {
            focus(c, span: 0.02)
        } else if let last = tools.lastSimulated {
            focus(last, span: 0.02)
        } else if let c = mac.coordinate {
            focus(c, span: 0.02)
        }
        mac.refresh()
    }

    private func centerOnMac() {
        guard let c = mac.coordinate else { mac.refresh(); return }
        choose(c, zoom: true)
    }

    private func focus(_ c: CLLocationCoordinate2D, span: Double) {
        position = .region(MKCoordinateRegion(center: c, span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)))
    }

    @ViewBuilder private var locationStatus: some View {
        switch tools.locationState {
        case .off: EmptyView()
        case .starting: ProgressView().controlSize(.small)
        case .active: Label("Attiva", systemImage: "location.fill").foregroundStyle(.blue).font(.caption)
        case .failed(let msg): Text(msg).font(.caption).foregroundStyle(.red).lineLimit(2)
        }
    }

    private func choose(_ c: CLLocationCoordinate2D, zoom: Bool) {
        userMoved = true
        pin = c
        latText = String(format: "%.6f", c.latitude)
        lonText = String(format: "%.6f", c.longitude)
        if zoom {
            position = .region(MKCoordinateRegion(center: c, span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)))
        }
    }

    private func coordinateFromFields() -> CLLocationCoordinate2D? {
        let norm = { (s: String) in Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) }
        guard let lat = norm(latText), let lon = norm(lonText), (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private func geocode() {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = search
        Task {
            if let item = try? await MKLocalSearch(request: request).start().mapItems.first {
                choose(item.placemark.coordinate, zoom: true)
            }
        }
    }
}

private struct LogTab: View {
    @Bindable var tools: DeviceTools
    @State private var autoScroll = true

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Processo (es. SpringBoard)", text: $tools.logProcessFilter).textFieldStyle(.roundedBorder)
                TextField("Testo", text: $tools.logTextFilter).textFieldStyle(.roundedBorder)
            }
            .onSubmit { tools.startLog() }
            HStack {
                if tools.logRunning {
                    Button { tools.stopLog() } label: { Label("Ferma", systemImage: "pause.fill") }
                } else {
                    Button { tools.startLog() } label: { Label("Avvia", systemImage: "play.fill") }
                }
                Toggle("Info", isOn: $tools.logIncludeInfo).toggleStyle(.checkbox)
                    .help("Includi i messaggi di livello Info (molto più numerosi)")
                Toggle("Scorri", isOn: $autoScroll).toggleStyle(.checkbox)
                Spacer()
                Button { tools.exportLog() } label: { Image(systemName: "square.and.arrow.down") }
                    .help("Esporta in Download").disabled(tools.logEntries.isEmpty)
                Button { tools.clearLog() } label: { Image(systemName: "trash") }.help("Svuota")
            }
            ScrollViewReader { proxy in
                List(tools.logEntries) { e in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(e.time).foregroundStyle(.secondary)
                            Text(e.process).foregroundStyle(color(e.level)).fontWeight(.semibold)
                        }
                        Text(e.message).textSelection(.enabled).lineLimit(6)
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .id(e.id)
                }
                .onChange(of: tools.logEntries.last?.id) { _, last in
                    if autoScroll, let last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            Text("Filtri applicati con Invio o Avvia. Ultime 2000 righe.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
    }

    private func color(_ level: String) -> Color {
        switch level.uppercased() {
        case "ERROR", "FAULT": return .red
        case "DEFAULT", "NOTICE": return .primary
        default: return .secondary
        }
    }
}

// MARK: - Conditions / Processes / Crashes tabs

/// Shown on tabs whose commands need the Developer Disk Image.
private struct NeedsDDI: View {
    let model: AppModel
    let udid: String
    var body: some View {
        if model.mountStates[udid] == .notMounted {
            HStack {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text("Serve la Developer Disk Image").font(.caption)
                Spacer()
                Button("Monta") { Task { await model.mount(udid) } }
            }
        }
    }
}

private struct ConditionsTab: View {
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
                    Button("Disattiva") { tool.deactivate() }
                } else if case .starting = tool.state {
                    Button("Annulla") { tool.deactivate() }
                }
                Button { Task { await tool.refresh() } } label: { Image(systemName: "arrow.clockwise") }.help("Aggiorna")
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
                                    Button("Attiva") { tool.activate(profile) }
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
            Text("Una condizione alla volta. Resta attiva finché la finestra è aperta; chiudendola l'iPhone torna normale.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .task { if tool.groups.isEmpty { await tool.refresh() } }
    }

    private static func title(_ g: ConditionsTool.Group) -> String {
        switch g.identifier {
        case "SlowNetworkCondition": return "Rete"
        case "ThermalCondition": return "Stato termico"
        case "GPUPerformanceState": return "Prestazioni GPU"
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
        case .off: Label("Nessuna condizione", systemImage: "circle").foregroundStyle(.secondary).font(.caption)
        case .starting(let p): Label("Attivo \(p.name)…", systemImage: "hourglass").font(.caption)
        case .active(let p): Label(p.name, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        case .failed(let msg): Text(msg).foregroundStyle(.red).font(.caption).lineLimit(2)
        }
    }
}

private struct ProcessesTab: View {
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

private struct CrashesTab: View {
    @Bindable var tool: CrashesTool
    @State private var confirmDelete: DeviceTools.FileEntry?

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button { Task { await tool.open((tool.path as NSString).deletingLastPathComponent) } } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(tool.path == "/").help("Cartella superiore")
                Text(tool.path).font(.callout.monospaced()).lineLimit(1).truncationMode(.head)
                Spacer()
                Button { Task { await tool.refresh() } } label: { Image(systemName: "arrow.clockwise") }.help("Aggiorna")
            }
            if let err = tool.error { Text(err).font(.caption).foregroundStyle(.red) }
            List(tool.entries) { e in
                HStack {
                    Image(systemName: e.dir ? "folder.fill" : "doc.text").foregroundStyle(e.dir ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.name).lineLimit(1).truncationMode(.middle)
                        if let d = Self.date(e.mtime) {
                            Text(d.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    Task { e.dir ? await tool.open(tool.fullPath(e)) : await tool.show(e) }
                }
                .contextMenu {
                    if e.dir {
                        Button("Apri") { Task { await tool.open(tool.fullPath(e)) } }
                    } else {
                        Button("Mostra") { Task { await tool.show(e) } }
                    }
                    Button("Scarica in Download") { Task { await tool.download(e) } }
                    Divider()
                    Button("Elimina…", role: .destructive) { confirmDelete = e }
                }
            }
            .overlay { if tool.loading && tool.entries.isEmpty { ProgressView() } }
            Text("Report di crash e diagnostica dell'iPhone, dal più recente. Doppio clic per leggerli.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .task { if tool.entries.isEmpty { await tool.refresh() } }
        .sheet(isPresented: .init(get: { tool.openedReport != nil }, set: { if !$0 { tool.openedReport = nil } })) {
            if let rep = tool.openedReport { CrashReportSheet(name: rep.name, text: rep.text) { tool.openedReport = nil } }
        }
        .confirmationDialog("Eliminare \(confirmDelete?.name ?? "")?", isPresented: .init(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })
        ) {
            Button("Elimina", role: .destructive) { if let e = confirmDelete { Task { await tool.delete(e) } } }
        } message: {
            Text("Il report viene eliminato dall'iPhone.")
        }
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate, .withFractionalSeconds]
        return f
    }()
    private static let isoNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        return f
    }()

    /// The helper writes naive local times ("2026-11-09T11:05:09.123456").
    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        if let d = iso.date(from: s) ?? isoNoFraction.date(from: s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}

private struct CrashReportSheet: View {
    let name: String
    let text: String
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(name).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Copia") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Chiudi", action: close).keyboardShortcut(.cancelAction)
            }
            ScrollView([.vertical, .horizontal]) {
                Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(minWidth: 640, minHeight: 480)
    }
}
