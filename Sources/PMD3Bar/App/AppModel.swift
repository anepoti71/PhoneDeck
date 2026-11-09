import AppKit
import Foundation
import Observation
import PMD3BarCore

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

    // Settings (menu ▸ Impostazioni)
    var autoMountDDI: Bool = UserDefaults.standard.object(forKey: "autoMountDDI") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoMountDDI, forKey: "autoMountDDI") }
    }
    var notificationsEnabled: Bool = UserDefaults.standard.object(forKey: "notifications") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(notificationsEnabled, forKey: "notifications")
            if notificationsEnabled { Notifier.requestAuthorization() }
        }
    }
    var hotKeyEnabled: Bool = UserDefaults.standard.object(forKey: "hotKey") as? Bool ?? true {
        didSet { UserDefaults.standard.set(hotKeyEnabled, forKey: "hotKey"); updateHotKey() }
    }
    var launchAtLogin: Bool = LoginItem.available && LoginItem.enabled
    var settingsError: String?

    var selectedDevice: Device? { devices.first { $0.id == selectedUDID } }
    var activeSessions: [MirrorSession] { sessions.values.filter(\.isActive).sorted { $0.port < $1.port } }

    @ObservationIgnored private var tools: [String: DeviceTools] = [:]
    /// Devices auto-mount already tried on since they connected (no retry loop on failure).
    @ObservationIgnored private var autoMountTried: Set<String> = []
    /// Presence bookkeeping for connect/disconnect notifications.
    @ObservationIgnored private var firstListing = true
    @ObservationIgnored private var goneSince: [String: Date] = [:]
    @ObservationIgnored private var announcedGone: Set<String> = []
    @ObservationIgnored private var knownNames: [String: String] = [:]
    @ObservationIgnored private var hotKey: GlobalHotKey?
    private var pollTask: Task<Void, Never>?
    private var refreshingDevices = false
    private var signalSources: [DispatchSourceSignal] = []

    init() {
        PMD3.log("PMD3Bar started, python: \(PMD3.python.map { "\($0.url.path) (\($0.source.rawValue))" } ?? "not found")")
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
        updateHotKey()
        if notificationsEnabled { Notifier.requestAuthorization() }
        Task {
            await loadVersion()
            // Then look for a newer pymobiledevice3 now and every 12 hours.
            while !Task.isCancelled {
                await checkForUpdates()
                try? await Task.sleep(for: .seconds(12 * 3600))
            }
        }
    }

    private func notify(_ title: String, _ body: String = "") {
        Notifier.post(title, body, enabled: notificationsEnabled)
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
            if var d = previous[s.udid] { d.connections = []; d.unreachableError = "not visible"; merged.append(d) }
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
        trackPresence(list)
        // Newly reachable devices: read their mount state (and auto-mount if enabled).
        for d in list where d.reachable && d.id != selectedUDID
            && (previous[d.id] == nil || previous[d.id]?.reachable == false) {
            Task { await refreshMount(d.id) }
        }
        // Pulling the cable kills the USB tunnel under a running serve-web: restart it over Wi-Fi.
        for s in activeSessions {
            if let old = previous[s.udid], let new = device(s.udid), old.hasUSB, !new.hasUSB, new.reachable {
                PMD3.log("USB cable unplugged from \(new.name) while mirroring: restarting over Wi-Fi")
                s.restart()
            }
        }
    }

    func select(_ udid: String) { selectedUDID = udid }

    /// Notifies connections and disconnections. A Wi-Fi iPhone that dozes off vanishes for a few
    /// seconds: only absences longer than 20 s count, and it is announced again only after that.
    private func trackPresence(_ list: [Device]) {
        let now = Date()
        let present = Set(list.filter(\.reachable).map(\.id))
        for d in list { knownNames[d.id] = d.name }
        defer { firstListing = false }
        for d in list where d.reachable {
            goneSince[d.id] = nil
            let isNew = !seenBefore.contains(d.id)
            let isBack = announcedGone.remove(d.id) != nil
            if !firstListing && (isNew || isBack) {
                notify("iPhone connected", "\(d.name) · \(d.connectionLabel)")
            }
            seenBefore.insert(d.id)
        }
        for id in seenBefore where !present.contains(id) {
            let since = goneSince[id] ?? now
            goneSince[id] = since
            if now.timeIntervalSince(since) >= 20, !announcedGone.contains(id) {
                announcedGone.insert(id)
                autoMountTried.remove(id)  // next connection may need a new mount (e.g. after a reboot)
                notify("iPhone disconnected", knownNames[id] ?? id)
            }
        }
    }

    @ObservationIgnored private var seenBefore: Set<String> = []

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
        if autoMountDDI, mountStates[udid] == .notMounted, device(udid)?.reachable == true,
           !autoMountTried.contains(udid) {
            autoMountTried.insert(udid)
            PMD3.log("Auto-mounting the DDI on \(device(udid)?.name ?? udid)")
            await mount(udid, automatic: true)
        }
    }

    func mount(_ udid: String? = nil, automatic: Bool = false) async {
        guard let udid = udid ?? selectedUDID else { return }
        let name = device(udid)?.name ?? udid
        mountStates[udid] = .mounting
        // auto-mount opens its own no-root userspace tunnel on iOS 17+.
        let result = await PMD3.run(["mounter", "auto-mount", "--udid", udid], timeout: 300)
        if result.ok {
            mountStates[udid] = nil
            await refreshMount(udid)
            if automatic { notify("Developer Disk Image mounted", name) }
        } else {
            mountStates[udid] = .failed(result.errorSummary)
            notify("DDI mount failed", "\(name): \(result.errorSummary)")
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
        s.onFailure = { [weak self] msg in
            self?.notify("Mirroring stopped", "\(self?.device(udid)?.name ?? udid): \(msg)")
        }
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
        t.notify = { [weak self] title, body in self?.notify(title, body) }
        tools[udid] = t
        return t
    }

    /// Window closed: stop its stream and the tools it started (simulated location is cleared).
    func closeWindow(_ udid: String, keepMirroring: Bool = false) {
        if !keepMirroring { sessions[udid]?.stop() }
        tools[udid]?.shutdown(clearLocation: true)
    }

    private func shutdownAll() {
        for s in sessions.values { s.stopSync() }
        for t in tools.values { t.shutdown(clearLocation: false) }
    }

    // MARK: Settings

    private func updateHotKey() {
        if hotKeyEnabled, hotKey == nil {
            hotKey = GlobalHotKey { [weak self] in
                MainActor.assumeIsolated { self?.toggleSelectedWindow() }
            }
            if hotKey == nil { settingsError = "Shortcut ⌥⌘M is already used by another app" }
        } else if !hotKeyEnabled {
            hotKey = nil
        }
    }

    /// ⌥⌘M: shows the selected iPhone's window, or closes it if it is already in front.
    func toggleSelectedWindow() {
        guard let udid = selectedUDID ?? devices.first(where: \.reachable)?.id else { NSSound.beep(); return }
        MirrorWindows.shared.toggle(udid)
    }

    func testNotification() {
        let names = devices.filter(\.reachable).map(\.name).joined(separator: ", ")
        notify("PMD3Bar", names.isEmpty ? "Notifications work." : "Notifications work. Connected iPhones: \(names)")
    }

    func setLaunchAtLogin(_ on: Bool) {
        settingsError = LoginItem.set(on)
        launchAtLogin = LoginItem.enabled
    }

    // MARK: pymobiledevice3 updates

    /// Latest version on PyPI, when known.
    var latestPMD3: String?
    var updateAvailable: Bool {
        guard let latest = latestPMD3 else { return false }
        return Versions.isVersion(latest, newerThan: pmd3Version)
    }
    static let releasesURL = URL(string: "https://github.com/doronz88/pymobiledevice3/releases")!

    /// Asks PyPI for the latest pymobiledevice3 (public JSON API, nothing about the user is sent).
    func checkForUpdates() async {
        var request = URLRequest(url: URL(string: "https://pypi.org/pypi/pymobiledevice3/json")!)
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = obj["info"] as? [String: Any], let version = info["version"] as? String
        else { return }
        latestPMD3 = version
        guard updateAvailable else { return }
        PMD3.log("pymobiledevice3 \(version) available (bundled: \(pmd3Version))")
        if UserDefaults.standard.string(forKey: "notifiedPMD3Version") != version {
            UserDefaults.standard.set(version, forKey: "notifiedPMD3Version")
            notify("pymobiledevice3 \(version) available",
                   "The app bundles \(pmd3Version). To update: PMD3_VERSION=\(version) make python && make install")
        }
    }

    // MARK: Misc

    func loadVersion() async {
        let result = await PMD3.run(["version"], timeout: 30)
        pmd3Version = result.ok
            ? String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            : "not available"
    }

    func openLog() {
        if !FileManager.default.fileExists(atPath: PMD3.logURL.path) {
            FileManager.default.createFile(atPath: PMD3.logURL.path, contents: nil)
        }
        NSWorkspace.shared.open(PMD3.logURL)
    }
}
