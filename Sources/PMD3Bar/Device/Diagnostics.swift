import AppKit
import Foundation
import Observation
import PMD3BarCore

/// Shows a short message in the device window (DeviceTools.banner): text, isError, busy.
typealias Reporter = (String, Bool, Bool) -> Void

/// A command that applies something on the iPhone for as long as it keeps running
/// (`simulate-location set`, `condition set`): pymobiledevice3 prints "Press Ctrl+C" once it is
/// applied, and the device drops it when the command ends.
@MainActor
final class HeldCommand {
    private var process: Process?
    var isRunning: Bool { process?.isRunning == true }

    /// - onApplied: the device has applied it.
    /// - onExit: the command ended on its own (not through `stop()`), with its output.
    func start(_ args: [String], udid: String, onApplied: @escaping () -> Void, onExit: @escaping (RunResult) -> Void) {
        stop()
        guard let p = try? PMD3.makeProcess(args, udid: udid) else {
            onExit(RunResult(status: -1, stdout: Data(), stderr: "Python non trovato"))
            return
        }
        let pipe = Pipe()  // the hint goes to stdout, errors to stderr: read both
        p.standardOutput = pipe
        p.standardError = pipe
        final class Box: @unchecked Sendable {
            private var data = Data()
            private let lock = NSLock()
            func append(_ d: Data) { lock.withLock { data.append(d) } }
            var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
        }
        let box = Box()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            box.append(d)
        }
        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            let text = box.text
            let status = proc.terminationStatus
            Task { @MainActor in
                PMD3.log("$ pymobiledevice3 \(args.joined(separator: " ")) -> exit \(status)\n\(text)")
                guard let self, self.process === proc else { return }
                self.process = nil
                onExit(RunResult(status: status, stdout: Data(), stderr: text))
            }
        }
        do { try p.run() } catch {
            onExit(RunResult(status: -1, stdout: Data(), stderr: error.localizedDescription))
            return
        }
        process = p
        Task {
            for _ in 0..<120 {
                guard self.process === p else { return }
                if box.text.contains("Ctrl+C") { onApplied(); return }
                try? await Task.sleep(for: .milliseconds(500))
            }
            if self.process === p { onApplied() }
        }
    }

    /// Ends the command; the device drops what it applied.
    func stop() {
        guard let p = process else { return }
        process = nil
        if p.isRunning {
            p.interrupt()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if p.isRunning { p.terminate() } }
        }
    }
}

// MARK: - Conditions (network link, thermal state, GPU performance)

@MainActor
@Observable
final class ConditionsTool {
    struct Profile: Identifiable, Hashable, Decodable {
        let identifier: String
        let name: String
        let description: String?
        var id: String { identifier }
    }

    struct Group: Identifiable, Decodable {
        let identifier: String
        let name: String
        let profiles: [Profile]
        var id: String { identifier }
    }

    enum State: Equatable {
        case off
        case starting(Profile)
        case active(Profile)
        case failed(String)
    }

    let udid: String
    private let report: Reporter
    var groups: [Group] = []
    var loading = false
    var error: String?
    var state: State = .off
    @ObservationIgnored private let held = HeldCommand()

    init(udid: String, report: @escaping Reporter) {
        self.udid = udid
        self.report = report
    }

    func refresh() async {
        loading = true
        defer { loading = false }
        let r = await PMD3.run(["developer", "dvt", "condition", "list"], udid: udid, timeout: 90)
        if r.ok, let list = try? JSONDecoder().decode([Group].self, from: r.stdout) {
            groups = list
            error = nil
        } else {
            error = r.errorSummary
        }
    }

    /// One condition at a time, like Xcode: it lasts while the command runs.
    func activate(_ profile: Profile) {
        state = .starting(profile)
        held.start(["developer", "dvt", "condition", "set", profile.identifier], udid: udid,
                   onApplied: { [weak self] in
                       guard let self, self.state == .starting(profile) else { return }
                       self.state = .active(profile)
                       self.report("Condizione attiva: \(profile.name)", false, false)
                   },
                   onExit: { [weak self] r in
                       guard let self else { return }
                       self.state = .failed(r.errorSummary)
                       self.report("Condizione interrotta: \(r.errorSummary)", true, false)
                   })
    }

    func deactivate() {
        held.stop()
        state = .off
        report("Condizione disattivata", false, false)
    }

    func shutdown() {
        held.stop()
        state = .off
    }
}

// MARK: - Processes

@MainActor
@Observable
final class ProcessesTool {
    struct Proc: Identifiable, Hashable {
        let pid: Int
        let name: String
        /// Percent of one core (can exceed 100 on several cores).
        let cpu: Double
        let memory: Int64
        var id: Int { pid }
    }

    let udid: String
    private let report: Reporter
    var processes: [Proc] = []
    var loading = false
    var error: String?
    var lastUpdate: Date?
    var autoRefresh = false {
        didSet { autoRefresh ? startAutoRefresh() : autoTask?.cancel() }
    }
    @ObservationIgnored private var autoTask: Task<Void, Never>?

    init(udid: String, report: @escaping Reporter) {
        self.udid = udid
        self.report = report
    }

    /// One sysmon sample (about 10 s: it opens a tunnel and samples every process).
    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let r = await PMD3.run(["developer", "dvt", "sysmon", "process", "single",
                                "-k", "pid", "-k", "name", "-k", "cpuUsage", "-k", "physFootprint"],
                               udid: udid, timeout: 90)
        guard r.ok, let items = try? JSONSerialization.jsonObject(with: r.stdout) as? [[String: Any]] else {
            error = r.errorSummary
            return
        }
        processes = items.compactMap { item in
            guard let pid = item["pid"] as? Int else { return nil }
            return Proc(pid: pid,
                        name: item["name"] as? String ?? "?",
                        cpu: ((item["cpuUsage"] as? Double) ?? 0) * 100,
                        memory: (item["physFootprint"] as? NSNumber)?.int64Value ?? 0)
        }
        error = nil
        lastUpdate = Date()
    }

    func kill(_ proc: Proc) async {
        report("Chiudo \(proc.name)…", false, true)
        let r = await PMD3.run(["developer", "dvt", "kill", String(proc.pid)], udid: udid, timeout: 60)
        report(r.ok ? "\(proc.name) chiuso" : "Chiusura fallita: \(r.errorSummary)", !r.ok, false)
        if r.ok { processes.removeAll { $0.pid == proc.pid } }
    }

    private func startAutoRefresh() {
        autoTask?.cancel()
        autoTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func shutdown() {
        autoRefresh = false
    }
}

// MARK: - Crash reports

@MainActor
@Observable
final class CrashesTool {
    let udid: String
    private let report: Reporter
    var path = "/"
    var entries: [DeviceTools.FileEntry] = []
    var loading = false
    var error: String?
    /// Parsed report shown in a sheet.
    var openedReport: (name: String, text: String)?

    init(udid: String, report: @escaping Reporter) {
        self.udid = udid
        self.report = report
    }

    func fullPath(_ e: DeviceTools.FileEntry) -> String { (path as NSString).appendingPathComponent(e.name) }

    func open(_ dir: String) async {
        path = dir.isEmpty ? "/" : dir
        await refresh()
    }

    func refresh() async {
        loading = true
        defer { loading = false }
        let requested = path
        let r = await PMD3.runHelper(["crash-ls", requested], udid: udid, timeout: 90)
        guard requested == path else { return }
        if r.ok, let list = try? JSONDecoder().decode([DeviceTools.FileEntry].self, from: r.stdout) {
            // Folders first, then newest reports first.
            entries = list.sorted {
                if $0.dir != $1.dir { return $0.dir }
                return ($0.mtime ?? "") > ($1.mtime ?? "")
            }
            error = nil
        } else {
            entries = []
            error = r.errorSummary
        }
    }

    func show(_ e: DeviceTools.FileEntry) async {
        report("Apro \(e.name)…", false, true)
        let r = await PMD3.run(["crash", "parse", fullPath(e)], udid: udid, timeout: 90)
        if r.ok {
            report("", false, false)
            openedReport = (e.name, String(decoding: r.stdout, as: UTF8.self))
        } else {
            report("Lettura fallita: \(r.errorSummary)", true, false)
        }
    }

    func download(_ e: DeviceTools.FileEntry) async {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dest = uniqueURL(downloads.appendingPathComponent("iPhone crash \(stamp)"))
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        report("Scarico \(e.name)…", false, true)
        let r = await PMD3.run(["crash", "pull", dest.path, fullPath(e)], udid: udid, timeout: 600)
        if r.ok {
            report("\(e.name) salvato in Download", false, false)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } else {
            report("Download fallito: \(r.errorSummary)", true, false)
        }
    }

    func delete(_ e: DeviceTools.FileEntry) async {
        report("Elimino \(e.name)…", false, true)
        let r = await PMD3.runHelper(["crash-rm", fullPath(e)], udid: udid, timeout: 120)
        report(r.ok ? "\(e.name) eliminato" : "Eliminazione fallita: \(r.errorSummary)", !r.ok, false)
        await refresh()
    }
}
