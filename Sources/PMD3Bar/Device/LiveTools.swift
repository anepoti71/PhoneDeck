import AppKit
import Foundation
import Observation
import PMD3BarCore

/// A long-running child process whose stdout reaches the main actor in batches (at most 4 per second)
/// and whose stderr is kept for the error message.
@MainActor
final class ProcessStream {
    private(set) var process: Process?
    var isRunning: Bool { process != nil }

    /// - onData: stdout received since the last call.
    /// - onExit: exit status and stderr. Not called after `stop()`.
    @discardableResult
    func start(_ p: Process, label: String, onData: @escaping (Data) -> Void,
               onExit: @escaping (Int32, String) -> Void) -> Bool {
        stop()
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err

        final class Reader: @unchecked Sendable {
            let lock = NSLock()
            var pending = Data()
            var errors = Data()
            var timer: Timer?
            func take() -> Data { lock.withLock { defer { pending.removeAll() }; return pending } }
        }
        let reader = Reader()
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { reader.lock.withLock { reader.pending.append(d) } }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { reader.lock.withLock { reader.errors.append(d) } }
        }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            let d = reader.take()
            guard !d.isEmpty else { return }
            MainActor.assumeIsolated {
                guard let self, self.process === p else { return }
                onData(d)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        reader.timer = timer
        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            let restOut = (try? out.fileHandleForReading.readToEnd()) ?? Data()
            let restErr = (try? err.fileHandleForReading.readToEnd()) ?? Data()
            let status = proc.terminationStatus
            Task { @MainActor in
                reader.timer?.invalidate()
                let tail = reader.take() + restOut
                let errText = reader.lock.withLock { String(decoding: reader.errors + restErr, as: UTF8.self) }
                PMD3.log("$ \(label) -> exit \(status)" + (errText.isEmpty ? "" : "\n" + errText))
                guard let self, self.process === proc else { return }
                if !tail.isEmpty { onData(tail) }
                self.process = nil
                onExit(status, errText)
            }
        }
        do { try p.run() } catch {
            timer.invalidate()
            onExit(-1, error.localizedDescription)
            return false
        }
        process = p
        return true
    }

    /// Ends the process (SIGINT, then SIGTERM after `grace` seconds, or SIGTERM right away).
    func stop(interruptFirst: Bool = true, grace: Double = 2) {
        guard let p = process else { return }
        process = nil
        guard p.isRunning else { return }
        if interruptFirst {
            p.interrupt()
            DispatchQueue.main.asyncAfter(deadline: .now() + grace) { if p.isRunning { p.terminate() } }
        } else {
            p.terminate()
        }
    }
}

// MARK: - App containers mounted in Finder (WebDAV)

/// `pymobiledevice3 apps webdav --mount`: serves an app's container over WebDAV on 127.0.0.1 and mounts
/// it in a temporary folder that Finder shows, for as long as the command runs.
@MainActor
@Observable
final class ContainerMounts {
    enum State: Equatable {
        case mounting
        case mounted(path: String, documentsOnly: Bool)
    }

    let udid: String
    private let report: Reporter
    /// By bundle id.
    private(set) var states: [String: State] = [:]
    @ObservationIgnored private var streams: [String: ProcessStream] = [:]

    init(udid: String, report: @escaping Reporter) {
        self.udid = udid
        self.report = report
    }

    func isMounted(_ bundleID: String) -> Bool {
        if case .mounted = states[bundleID] { return true }
        return false
    }

    /// Mounts the container (or shows it again in Finder when already mounted).
    func open(_ bundleID: String, name: String, documentsOnly: Bool = false) {
        switch states[bundleID] {
        case .mounted(let path, _):
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        case .mounting:
            return
        case nil:
            break
        }
        let args = ["apps", "webdav", "--mount"] + (documentsOnly ? ["--documents"] : []) + ["--", bundleID]
        guard let p = try? PMD3.makeProcess(args, udid: udid) else {
            report("Python with pymobiledevice3 not found", true, false)
            return
        }
        let stream = ProcessStream()
        streams[bundleID] = stream
        states[bundleID] = .mounting
        report("Mounting \(name)'s \(documentsOnly ? "Documents folder" : "container")…", false, true)
        var output = ""
        stream.start(p, label: "pymobiledevice3 " + args.joined(separator: " "), onData: { [weak self] data in
            guard let self else { return }
            output += String(decoding: data, as: UTF8.self)
            if self.states[bundleID] == .mounting, let path = WebDAVOutput.mountPath(in: output) {
                // pymobiledevice3 has already revealed it in Finder.
                self.states[bundleID] = .mounted(path: path, documentsOnly: documentsOnly)
                self.report("\(name)'s \(documentsOnly ? "Documents folder" : "container") is open in Finder. "
                            + "Edits go straight to the iPhone.", false, false)
            } else if WebDAVOutput.mountUnavailable(in: output) {
                self.report("macOS couldn't mount \(name)'s container", true, false)
                self.unmount(bundleID)
            }
        }, onExit: { [weak self] status, errText in
            guard let self else { return }
            let wasMounted = self.isMounted(bundleID)
            self.states[bundleID] = nil
            self.streams[bundleID] = nil
            if wasMounted {
                // The iPhone went away: pymobiledevice3 unmounted it before exiting.
                self.report("\(name)'s container was unmounted (iPhone disconnected)", false, false)
            } else if !documentsOnly {
                // Not development-signed: the whole container is refused, its Documents may not be.
                PMD3.log("[\(self.udid.prefix(8))] container of \(bundleID) refused, mounting Documents")
                self.open(bundleID, name: name, documentsOnly: true)
            } else {
                let summary = RunResult(status: status, stdout: Data(), stderr: errText).errorSummary
                self.report("Can't open \(name)'s files: \(summary). Only development-signed apps, "
                            + "or apps that share their Documents, can be opened.", true, false)
            }
        })
    }

    /// Unmounts and stops the server. Synchronous: also used when the app quits, when there is no
    /// later turn of the run loop to finish it.
    func unmount(_ bundleID: String) {
        let state = states[bundleID]
        states[bundleID] = nil
        let stream = streams.removeValue(forKey: bundleID)
        if case .mounted(let path, _) = state { Self.unmountVolume(path) }
        // After a SIGINT the command unmounts but then hangs: SIGTERM it once the volume is gone.
        stream?.stop(interruptFirst: false)
    }

    func unmountAll() {
        for id in Array(states.keys) { unmount(id) }
    }

    private static func unmountVolume(_ path: String) {
        for args in [[path], ["-f", path]] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/sbin/umount")
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { continue }
            let deadline = Date().addingTimeInterval(5)
            while p.isRunning && Date() < deadline { usleep(50_000) }
            if p.isRunning { p.terminate() }
            if !p.isRunning && p.terminationStatus == 0 { break }
        }
        try? FileManager.default.removeItem(atPath: path)  // the empty mount point
    }
}

// MARK: - App console

/// `launch-application --console`: the app's stdout and stderr, until it exits.
@MainActor
@Observable
final class AppConsoleTool {
    let udid: String
    private let report: Reporter
    var buffer = ConsoleBuffer()
    var appName: String?
    var running = false
    /// Why the stream ended, shown under the output.
    var ended: String?
    @ObservationIgnored private let stream = ProcessStream()

    init(udid: String, report: @escaping Reporter) {
        self.udid = udid
        self.report = report
    }

    /// `args` from `LaunchOptions.command(bundleID:)` with `console` on.
    func start(_ args: [String], appName: String) {
        stop()
        guard let p = try? PMD3.makeProcess(args, udid: udid) else {
            report("Python with pymobiledevice3 not found", true, false)
            return
        }
        self.appName = appName
        ended = nil
        buffer.removeAll()
        running = true
        report("Launching \(appName)…", false, true)
        var first = true
        stream.start(p, label: "pymobiledevice3 " + args.joined(separator: " "), onData: { [weak self] data in
            guard let self else { return }
            if first { first = false; self.report("\(appName) launched", false, false) }
            self.buffer.append(data)
        }, onExit: { [weak self] status, errText in
            guard let self else { return }
            self.buffer.finish()
            self.running = false
            if status == 0 {
                self.ended = "\(appName) exited"
                if first { self.report("\(appName) launched and exited", false, false) }
            } else {
                let summary = RunResult(status: status, stdout: Data(), stderr: errText).errorSummary
                self.ended = "Stopped: \(summary)"
                self.report("Launch failed: \(summary)", true, false)
            }
        })
    }

    /// Detaches from the console; the app keeps running.
    func stop() {
        guard stream.isRunning else { return }
        stream.stop()
        buffer.finish()
        running = false
        ended = "Detached: \(appName ?? "the app") keeps running"
    }

    func clear() { buffer.removeAll() }

    func export() {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let base = (appName ?? "app").replacingOccurrences(of: "/", with: "-")
        let url = uniqueURL(downloads.appendingPathComponent("\(base)-console-\(stamp).txt"))
        do {
            try buffer.text.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            report("Export failed: \(error.localizedDescription)", true, false)
        }
    }
}

// MARK: - Network capture

/// `pmd3bar_helper.py pcap`: the iPhone's traffic into a .pcapng in ~/Downloads, with live totals.
@MainActor
@Observable
final class NetworkCaptureTool {
    let udid: String
    private let report: Reporter
    var processFilter = ""
    var interface: CaptureInterface = .all
    var stats: CaptureStats?
    var running = false
    /// The file being written, then the last one saved.
    var file: URL?
    var error: String?
    @ObservationIgnored private let stream = ProcessStream()

    init(udid: String, report: @escaping Reporter) {
        self.udid = udid
        self.report = report
    }

    static let wiresharkURL: URL? = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.wireshark.Wireshark")

    func start(deviceName: String) {
        stop()
        guard let helper = PMD3.helperURL else {
            error = "pmd3bar_helper.py not found"
            return
        }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let name = deviceName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = uniqueURL(downloads.appendingPathComponent("\(name) \(stamp).pcapng"))
        var args = ["pcap", url.path]
        let proc = processFilter.trimmingCharacters(in: .whitespaces)
        if !proc.isEmpty { args += ["--process", proc] }
        if interface != .all { args += ["--interface", interface.rawValue] }
        guard let p = try? PMD3.makePythonProcess([helper.path] + args, udid: udid) else {
            error = "Python with pymobiledevice3 not found"
            return
        }
        file = url
        stats = nil
        error = nil
        running = true
        var tail = ""
        stream.start(p, label: "helper " + args.joined(separator: " "), onData: { [weak self] data in
            guard let self else { return }
            tail += String(decoding: data, as: UTF8.self)
            if let s = CaptureStats.last(in: tail) { self.stats = s }
            if let nl = tail.lastIndex(of: "\n") { tail = String(tail[tail.index(after: nl)...]) }
        }, onExit: { [weak self] status, errText in
            guard let self else { return }
            self.running = false
            if status != 0 {
                self.error = RunResult(status: status, stdout: Data(), stderr: errText).errorSummary
                if (self.stats?.packets ?? 0) == 0, let f = self.file {
                    try? FileManager.default.removeItem(at: f)
                    self.file = nil
                }
            }
        })
    }

    /// Ends the capture; the helper flushes and closes the file on SIGTERM.
    func stop() {
        guard stream.isRunning else { return }
        stream.stop(interruptFirst: false)
        running = false
        if let file {
            report("Capture saved: \(file.lastPathComponent) (\(stats?.packets ?? 0) packets)", false, false)
        }
    }

    func openFile() {
        guard let file else { return }
        if let app = Self.wiresharkURL {
            NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        }
    }

    func revealFile() {
        if let file { NSWorkspace.shared.activateFileViewerSelecting([file]) }
    }
}
