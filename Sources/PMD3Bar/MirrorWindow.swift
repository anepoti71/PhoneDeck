import AppKit
import MapKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Window management

/// One native window per mirrored iPhone. Closing the window stops that iPhone's stream.
@MainActor
final class MirrorWindows: NSObject, NSWindowDelegate {
    static let shared = MirrorWindows()
    private var windows: [String: NSWindow] = [:]
    weak var model: AppModel?

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

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, let udid = w.identifier?.rawValue else { return }
        windows[udid] = nil
        model?.closeWindow(udid)
        if windows.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }
}

// MARK: - Window content

enum ToolTab: String, CaseIterable, Identifiable {
    case apps = "App", files = "File", location = "Posizione", log = "Log"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .apps: return "square.grid.2x2"
        case .files: return "folder"
        case .location: return "location"
        case .log: return "text.alignleft"
        }
    }
}

struct MirrorWindowView: View {
    let model: AppModel
    let udid: String
    @State private var viewer = ViewerController()
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
            ToolsPanel(model: model, tools: tools, udid: udid, tab: $tab)
                .inspectorColumnWidth(min: 300, ideal: 340, max: 520)
        }
        .toolbar { toolbar }
        .navigationTitle(device?.name ?? "iPhone")
        .navigationSubtitle(subtitle)
        .onAppear {
            viewer.deviceName = device?.name ?? "iPhone"
            if !mirroringSupported { showTools = true }
        }
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
                    .help("Registra lo schermo (video, senza audio) in Download")
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
                ForEach(ToolTab.allCases) { t in Label(t.rawValue, systemImage: t.icon).tag(t) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()
            switch tab {
            case .apps: AppsTab(tools: tools)
            case .files: FilesTab(tools: tools)
            case .location: LocationTab(model: model, tools: tools, udid: udid)
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
