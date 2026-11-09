import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    var devices: [Device] = []
    /// Device the menu's Developer Disk Image / mirroring controls apply to.
    var selectedUDID: String? {
        didSet {
            if let id = selectedUDID, oldValue != id, mountStates[id] == nil { Task { await refreshMount(id) } }
        }
    }
    /// Developer Disk Image state per device.
    var mountStates: [String: MountState] = [:]
    var mountState: MountState { selectedUDID.flatMap { mountStates[$0] } ?? .unknown }
    /// One mirroring session per device; several can run at once, each on its own port.
    var sessions: [String: MirrorSession] = [:]
    var deviceError: String?
    var pmd3Version: String = "…"
    /// First port tried for the viewers; further iPhones get the next free ones.
    var httpPort: Int = UserDefaults.standard.object(forKey: "httpPort") as? Int ?? 8080 {
        didSet { UserDefaults.standard.set(httpPort, forKey: "httpPort") }
    }

    var selectedDevice: Device? { devices.first { $0.id == selectedUDID } }
    var activeSessions: [MirrorSession] { sessions.values.filter(\.isActive).sorted { $0.port < $1.port } }

    @ObservationIgnored private var tools: [String: DeviceTools] = [:]
    private var pollTask: Task<Void, Never>?
    private var refreshingDevices = false
    private var signalSources: [DispatchSourceSignal] = []

    init() {
        PMD3.log("PMD3Bar avviato, python: \(PMD3.python.map { "\($0.url.path) (\($0.source.rawValue))" } ?? "non trovato")")
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdownAll() }
        }
        // Killed with a signal (e.g. by the build script) willTerminate never fires: clean up here too.
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.shutdownAll() }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
        startPolling()
        Task { await loadVersion() }
    }

    func device(_ udid: String) -> Device? { devices.first { $0.id == udid } }

    // MARK: Devices

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshDevices()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func refreshDevices() async {
        guard !refreshingDevices else { return }
        refreshingDevices = true
        defer { refreshingDevices = false }

        let result = await PMD3.runHelper(["list"], timeout: 30)
        guard result.ok else {
            deviceError = result.errorSummary
            return
        }
        deviceError = nil
        let previous = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        let previousSelected = selectedDevice
        let list = Device.parseHelperList(result.stdout)
        // Keep devices being mirrored in the list even if they vanish for a moment.
        var merged = list
        for s in activeSessions where !list.contains(where: { $0.id == s.udid }) {
            if var d = previous[s.udid] { d.connections = []; d.unreachableError = "non visibile"; merged.append(d) }
        }
        if merged != devices { devices = merged }
        for id in mountStates.keys where !merged.contains(where: { $0.id == id }) && mountStates[id] != .mounting {
            mountStates[id] = nil
        }
        if selectedUDID == nil || !merged.contains(where: { $0.id == selectedUDID }) {
            selectedUDID = merged.first(where: \.reachable)?.id ?? merged.first?.id
        } else if let id = selectedUDID,
                  mountStates[id] == nil || (previousSelected?.reachable == false && selectedDevice?.reachable == true) {
            await refreshMount(id)
        }
        // Pulling the cable kills the USB tunnel under a running serve-web: restart it over Wi-Fi.
        for s in activeSessions {
            if let old = previous[s.udid], let new = device(s.udid), old.hasUSB, !new.hasUSB, new.reachable {
                PMD3.log("Cavo USB scollegato da \(new.name) durante il mirroring: riavvio via Wi-Fi")
                s.restart()
            }
        }
    }

    func select(_ udid: String) { selectedUDID = udid }

    // MARK: Developer Disk Image

    func refreshMount(_ udid: String? = nil) async {
        guard let udid = udid ?? selectedUDID else { return }
        if mountStates[udid] == .mounting || mountStates[udid] == .checking { return }
        mountStates[udid] = .checking
        let result = await PMD3.run(["mounter", "list", "--udid", udid], timeout: 30)
        guard mountStates[udid] == .checking else { return }
        mountStates[udid] = result.ok
            ? (isDeveloperImageMounted(result.stdout) ? .mounted : .notMounted)
            : .failed(result.errorSummary)
    }

    func mount(_ udid: String? = nil) async {
        guard let udid = udid ?? selectedUDID else { return }
        mountStates[udid] = .mounting
        // auto-mount opens its own no-root userspace tunnel on iOS 17+.
        let result = await PMD3.run(["mounter", "auto-mount", "--udid", udid], timeout: 300)
        if result.ok {
            mountStates[udid] = nil
            await refreshMount(udid)
        } else {
            mountStates[udid] = .failed(result.errorSummary)
        }
    }

    // MARK: Mirroring

    /// The device's session, created on first use with the first free port from `httpPort`.
    func session(for udid: String) -> MirrorSession {
        if let s = sessions[udid] { return s }
        let used = Set(sessions.values.map(\.port))
        var port = max(1024, httpPort)
        while used.contains(port) || !isLocalPortFree(port) { port += 1 }
        let s = MirrorSession(udid: udid, port: port)
        s.isDeviceReachable = { [weak self] in self?.device(udid)?.reachable == true }
        sessions[udid] = s
        return s
    }

    func startMirroring(_ udid: String) {
        var s = session(for: udid)
        // The port may have been taken by something else since the session was created.
        if !s.isActive, !isLocalPortFree(s.port) {
            sessions[udid] = nil
            s = session(for: udid)
        }
        s.start()
    }

    func stopMirroring(_ udid: String) {
        sessions[udid]?.stop()
    }

    // MARK: Tools

    func tools(for udid: String) -> DeviceTools {
        if let t = tools[udid] { return t }
        let t = DeviceTools(udid: udid)
        tools[udid] = t
        return t
    }

    /// Window closed: stop its stream and the tools it started (simulated location is cleared).
    func closeWindow(_ udid: String) {
        sessions[udid]?.stop()
        tools[udid]?.shutdown(clearLocation: true)
    }

    private func shutdownAll() {
        for s in sessions.values { s.stopSync() }
        for t in tools.values { t.shutdown(clearLocation: false) }
    }

    // MARK: Misc

    func loadVersion() async {
        let result = await PMD3.run(["version"], timeout: 30)
        pmd3Version = result.ok
            ? String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            : "non disponibile"
    }

    func openLog() {
        if !FileManager.default.fileExists(atPath: PMD3.logURL.path) {
            FileManager.default.createFile(atPath: PMD3.logURL.path, contents: nil)
        }
        NSWorkspace.shared.open(PMD3.logURL)
    }
}
