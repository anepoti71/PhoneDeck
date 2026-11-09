import AppKit
import CoreLocation
import Foundation
import Observation

/// pymobiledevice3 features the web viewer doesn't expose, for one iPhone:
/// apps (install/launch/uninstall), files (/var/mobile/Media over AFC), simulated location, system log.
@MainActor
@Observable
final class DeviceTools {
    let udid: String

    /// Short feedback shown in the window (last action result).
    var banner: Banner?
    struct Banner: Equatable {
        var text: String
        var isError: Bool
        var busy: Bool = false
    }

    init(udid: String) {
        self.udid = udid
    }

    private func report(_ text: String, error: Bool = false, busy: Bool = false) {
        banner = Banner(text: text, isError: error, busy: busy)
        PMD3.log("[\(udid.prefix(8))] \(text)")
    }

    // MARK: Apps

    struct AppInfo: Identifiable, Hashable, Decodable {
        let bundle_id: String
        let name: String
        let version: String
        var id: String { bundle_id }
    }

    var apps: [AppInfo] = []
    var appsLoading = false
    var appsError: String?

    func refreshApps() async {
        appsLoading = true
        defer { appsLoading = false }
        let r = await PMD3.runHelper(["apps"], udid: udid, timeout: 60)
        if r.ok, let list = try? JSONDecoder().decode([AppInfo].self, from: r.stdout) {
            apps = list
            appsError = nil
        } else {
            appsError = r.errorSummary
        }
    }

    func install(_ url: URL) async {
        report("Installo \(url.lastPathComponent)…", busy: true)
        let r = await PMD3.run(["apps", "install", url.path], udid: udid, timeout: 900)
        if r.ok {
            report("\(url.lastPathComponent) installata")
            await refreshApps()
        } else {
            report("Installazione fallita: \(r.errorSummary)", error: true)
        }
    }

    func launch(_ app: AppInfo) async {
        report("Avvio \(app.name)…", busy: true)
        let r = await PMD3.run(["developer", "core-device", "launch-application", app.bundle_id], udid: udid, timeout: 90)
        report(r.ok ? "\(app.name) avviata" : "Avvio fallito: \(r.errorSummary)", error: !r.ok)
    }

    func uninstall(_ app: AppInfo) async {
        report("Disinstallo \(app.name)…", busy: true)
        let r = await PMD3.run(["apps", "uninstall", app.bundle_id], udid: udid, timeout: 180)
        if r.ok {
            report("\(app.name) disinstallata")
            apps.removeAll { $0.id == app.id }
        } else {
            report("Disinstallazione fallita: \(r.errorSummary)", error: true)
        }
    }

    // MARK: Files (AFC, rooted at /var/mobile/Media)

    struct FileEntry: Identifiable, Hashable, Decodable {
        let name: String
        let dir: Bool
        let size: Int
        let mtime: String?
        var id: String { name }
    }

    var filesPath = "/"
    var files: [FileEntry] = []
    var filesLoading = false
    var filesError: String?

    func path(for entry: FileEntry) -> String {
        (filesPath as NSString).appendingPathComponent(entry.name)
    }

    func openDirectory(_ path: String) async {
        filesPath = path.isEmpty ? "/" : path
        await refreshFiles()
    }

    func goUp() async {
        await openDirectory((filesPath as NSString).deletingLastPathComponent)
    }

    func refreshFiles() async {
        filesLoading = true
        defer { filesLoading = false }
        let requested = filesPath
        let r = await PMD3.runHelper(["afc-ls", requested], udid: udid, timeout: 60)
        guard requested == filesPath else { return }
        if r.ok, let list = try? JSONDecoder().decode([FileEntry].self, from: r.stdout) {
            files = list.sorted { ($0.dir ? 0 : 1, $0.name.lowercased()) < ($1.dir ? 0 : 1, $1.name.lowercased()) }
            filesError = nil
        } else {
            files = []
            filesError = r.errorSummary
        }
    }

    /// Copies Mac files/folders into the current folder on the iPhone.
    func upload(_ urls: [URL]) async {
        for url in urls {
            let remote = (filesPath as NSString).appendingPathComponent(url.lastPathComponent)
            report("Copio \(url.lastPathComponent) su iPhone…", busy: true)
            let r = await PMD3.run(["afc", "push", url.path, remote], udid: udid, timeout: 1800)
            if !r.ok {
                report("Copia fallita: \(r.errorSummary)", error: true)
                return
            }
        }
        report(urls.count == 1 ? "\(urls[0].lastPathComponent) copiato in \(filesPath)" : "\(urls.count) elementi copiati in \(filesPath)")
        await refreshFiles()
    }

    /// Downloads a file or folder into ~/Downloads and shows it in Finder.
    func download(_ entry: FileEntry) async {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let dest = uniqueURL(downloads.appendingPathComponent(entry.name))
        report("Scarico \(entry.name)…", busy: true)
        let r = await PMD3.run(["afc", "pull", path(for: entry), dest.path], udid: udid, timeout: 1800)
        if r.ok {
            report("\(entry.name) salvato in Download")
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } else {
            report("Download fallito: \(r.errorSummary)", error: true)
        }
    }

    func delete(_ entry: FileEntry) async {
        report("Elimino \(entry.name)…", busy: true)
        let r = await PMD3.run(["afc", "rm", path(for: entry)], udid: udid, timeout: 300)
        report(r.ok ? "\(entry.name) eliminato" : "Eliminazione fallita: \(r.errorSummary)", error: !r.ok)
        await refreshFiles()
    }

    // MARK: Simulated location (needs the Developer Disk Image)

    enum LocationState: Equatable {
        case off, starting
        case active(CLLocationCoordinate2D)
        case failed(String)

        static func == (a: LocationState, b: LocationState) -> Bool {
            switch (a, b) {
            case (.off, .off), (.starting, .starting): return true
            case let (.active(x), .active(y)): return x.latitude == y.latitude && x.longitude == y.longitude
            case let (.failed(x), .failed(y)): return x == y
            default: return false
            }
        }
    }

    var locationState: LocationState = .off
    private var locationProcess: Process?

    /// The simulated location lasts as long as the `simulate-location set` process runs.
    func setLocation(_ c: CLLocationCoordinate2D) {
        stopLocationProcess()
        let args = ["developer", "dvt", "simulate-location", "set", "--",
                    String(format: "%.6f", c.latitude), String(format: "%.6f", c.longitude)]
        guard let p = try? PMD3.makeProcess(args, udid: udid) else { return }
        let err = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = err
        final class Box: @unchecked Sendable { var data = Data() }
        let box = Box()
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { box.data.append(d) }
        }
        p.terminationHandler = { [weak self] proc in
            err.fileHandleForReading.readabilityHandler = nil
            let text = String(decoding: box.data, as: UTF8.self)
            let status = proc.terminationStatus
            Task { @MainActor in
                guard let self, self.locationProcess === proc else { return }
                self.locationProcess = nil
                PMD3.log("simulate-location set terminato (exit \(status))\n\(text)")
                if case .off = self.locationState { return }
                self.locationState = .failed(RunResult(status: status, stdout: Data(), stderr: text).errorSummary)
            }
        }
        do { try p.run() } catch {
            locationState = .failed(error.localizedDescription)
            return
        }
        locationProcess = p
        locationState = .starting
        // pymobiledevice3 prints the "Press Ctrl+C" hint once the location is set and keeps running.
        Task {
            for _ in 0..<60 {
                guard locationProcess === p else { return }
                if String(decoding: box.data, as: UTF8.self).contains("Ctrl+C") {
                    locationState = .active(c)
                    report(String(format: "Posizione simulata: %.5f, %.5f", c.latitude, c.longitude))
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            if locationProcess === p { locationState = .active(c) }
        }
    }

    func clearLocation() async {
        locationState = .off
        stopLocationProcess()
        let r = await PMD3.run(["developer", "dvt", "simulate-location", "clear"], udid: udid, timeout: 90)
        report(r.ok ? "Posizione reale ripristinata" : "Ripristino fallito: \(r.errorSummary)", error: !r.ok)
    }

    private func stopLocationProcess() {
        guard let p = locationProcess else { return }
        locationProcess = nil
        if p.isRunning {
            p.interrupt()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if p.isRunning { p.terminate() } }
        }
    }

    // MARK: System log

    struct LogEntry: Identifiable {
        let id: Int
        let time: String
        let level: String
        let process: String
        let message: String
    }

    var logEntries: [LogEntry] = []
    var logRunning = false
    var logProcessFilter = ""
    var logTextFilter = ""
    var logIncludeInfo = false
    private var logProcess: Process?
    private var logCounter = 0
    private let logLimit = 2000

    func startLog() {
        stopLog()
        var args = ["syslog", "live", "--format", "json", "--no-debug"]
        if !logIncludeInfo { args.append("--no-info") }
        let proc = logProcessFilter.trimmingCharacters(in: .whitespaces)
        if !proc.isEmpty { args += ["--process-name", proc] }
        let text = logTextFilter.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { args += ["--match-insensitive", text] }
        guard let p = try? PMD3.makeProcess(args, udid: udid) else { return }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = PMD3.logHandle()

        // Parsing happens off the main thread; the UI gets at most ~4 batches per second.
        final class Reader: @unchecked Sendable {
            var buffer = Data()
            var pending: [LogEntry] = []
            var counter = 0
            let lock = NSLock()
        }
        let reader = Reader()
        reader.counter = logCounter
        out.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { return }
            reader.lock.lock()
            reader.buffer.append(chunk)
            while let nl = reader.buffer.firstIndex(of: 0x0A) {
                let line = reader.buffer[reader.buffer.startIndex..<nl]
                reader.buffer.removeSubrange(reader.buffer.startIndex...nl)
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                reader.counter += 1
                let ts = (obj["timestamp"] as? String ?? "")
                let file = (obj["filename"] as? String ?? "")
                reader.pending.append(LogEntry(
                    id: reader.counter,
                    time: String(ts.split(separator: "T").last?.prefix(12) ?? ""),
                    level: obj["level"] as? String ?? "",
                    process: (file as NSString).lastPathComponent,
                    message: obj["message"] as? String ?? ""
                ))
            }
            if reader.pending.count > 5000 { reader.pending.removeFirst(reader.pending.count - 5000) }
            reader.lock.unlock()
        }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            reader.lock.lock()
            let batch = reader.pending
            reader.pending.removeAll()
            let counter = reader.counter
            reader.lock.unlock()
            guard !batch.isEmpty else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.logCounter = counter
                self.logEntries.append(contentsOf: batch)
                if self.logEntries.count > self.logLimit {
                    self.logEntries.removeFirst(self.logEntries.count - self.logLimit)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                timer.invalidate()
                guard let self, self.logProcess === proc else { return }
                self.logProcess = nil
                self.logRunning = false
            }
        }
        do { try p.run() } catch { return }
        logProcess = p
        logRunning = true
    }

    func stopLog() {
        guard let p = logProcess else { return }
        logProcess = nil
        logRunning = false
        // syslog live can ignore SIGINT while flooded with output: follow up with SIGTERM.
        p.interrupt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if p.isRunning { p.terminate() } }
    }

    func clearLog() { logEntries.removeAll() }

    func exportLog() {
        let text = logEntries.map { "\($0.time) \($0.level) \($0.process): \($0.message)" }.joined(separator: "\n")
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = uniqueURL(downloads.appendingPathComponent("iPhone-syslog-\(stamp).txt"))
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            report("Esportazione fallita: \(error.localizedDescription)", error: true)
        }
    }

    // MARK: Lifecycle

    /// Stops every long-running process (window closed or app quitting).
    func shutdown(clearLocation: Bool) {
        stopLog()
        let hadLocation = locationProcess != nil
        stopLocationProcess()
        locationState = .off
        if clearLocation && hadLocation {
            Task { _ = await PMD3.run(["developer", "dvt", "simulate-location", "clear"], udid: udid, timeout: 60) }
        }
    }
}

/// `name.ext` → `name 2.ext` … when the file already exists.
func uniqueURL(_ url: URL) -> URL {
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) else { return url }
    let base = url.deletingPathExtension().lastPathComponent
    let ext = url.pathExtension
    for i in 2... {
        let name = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
        let candidate = url.deletingLastPathComponent().appendingPathComponent(name)
        if !fm.fileExists(atPath: candidate.path) { return candidate }
    }
    return url
}
