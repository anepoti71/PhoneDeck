import AppKit
import CoreLocation
import Foundation
import Observation
import PMD3BarCore

/// pymobiledevice3 features the web viewer doesn't expose, for one iPhone:
/// apps (install/launch/uninstall), files (/var/mobile/Media and app containers over AFC), simulated location,
/// system log, device info and power.
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

    /// Posts a system notification (set by AppModel, follows the Notifiche setting).
    var notify: (String, String) -> Void = { _, _ in }

    @ObservationIgnored private(set) lazy var conditions = ConditionsTool(udid: udid) { [weak self] in self?.reportFromTool($0, $1, $2) }
    @ObservationIgnored private(set) lazy var processes = ProcessesTool(udid: udid) { [weak self] in self?.reportFromTool($0, $1, $2) }
    @ObservationIgnored private(set) lazy var crashes = CrashesTool(udid: udid) { [weak self] in self?.reportFromTool($0, $1, $2) }
    @ObservationIgnored private(set) lazy var mounts = ContainerMounts(udid: udid) { [weak self] in self?.reportFromTool($0, $1, $2) }
    @ObservationIgnored private(set) lazy var console = AppConsoleTool(udid: udid) { [weak self] in self?.reportFromTool($0, $1, $2) }
    @ObservationIgnored private(set) lazy var capture = NetworkCaptureTool(udid: udid) { [weak self] in self?.reportFromTool($0, $1, $2) }

    init(udid: String) {
        self.udid = udid
    }

    private func reportFromTool(_ text: String, _ isError: Bool, _ busy: Bool) {
        if text.isEmpty { banner = nil } else { report(text, error: isError, busy: busy) }
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
            await loadIcons()
        } else {
            appsError = r.errorSummary
        }
    }

    /// App icons, cached on disk by bundle id (shared by all iPhones).
    static let iconsDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PMD3Bar/icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Bumped when new icons land on disk, so the list redraws.
    var iconsGeneration = 0
    @ObservationIgnored private let iconCache = NSCache<NSString, NSImage>()

    func icon(for bundleID: String) -> NSImage? {
        _ = iconsGeneration
        if let img = iconCache.object(forKey: bundleID as NSString) { return img }
        let url = Self.iconsDir.appendingPathComponent("\(bundleID).png")
        guard let img = NSImage(contentsOf: url) else { return nil }
        iconCache.setObject(img, forKey: bundleID as NSString)
        return img
    }

    private func loadIcons() async {
        let missing = apps.map(\.bundle_id).filter {
            !FileManager.default.fileExists(atPath: Self.iconsDir.appendingPathComponent("\($0).png").path)
        }
        guard !missing.isEmpty else { return }
        let r = await PMD3.runHelper(["icons", Self.iconsDir.path] + missing, udid: udid, timeout: 120)
        if r.ok { iconsGeneration += 1 }
    }

    // MARK: Install

    /// An .ipa this iPhone would refuse as it is, shown in the window until the user decides.
    var installReview: InstallReview?

    enum InstallDecision {
        case resign(ResignPlan)
        case installAnyway
        case cancel
    }

    @MainActor
    @Observable
    final class InstallReview: Identifiable {
        let id = UUID()
        let ipa: URL
        let info: IPAInfo
        let issues: [IPAIssue]
        var plans: [ResignPlan]
        /// Profiles on this Mac that can't be used, with the reason ("Name: reason").
        var rejected: [String]
        /// What the developer portal must provide for this app and iPhone.
        let requirements: SigningRequirements
        var profileError: String?
        @ObservationIgnored let identities: [SigningIdentity]
        @ObservationIgnored private var decision: CheckedContinuation<InstallDecision, Never>?

        init(ipa: URL, info: IPAInfo, issues: [IPAIssue], plans: [ResignPlan], rejected: [String],
             requirements: SigningRequirements, identities: [SigningIdentity],
             decision: CheckedContinuation<InstallDecision, Never>) {
            self.ipa = ipa
            self.info = info
            self.issues = issues
            self.plans = plans
            self.rejected = rejected
            self.requirements = requirements
            self.identities = identities
            self.decision = decision
        }

        /// Only the first call counts (closing the sheet after a choice cancels nothing).
        func decide(_ d: InstallDecision) {
            decision?.resume(returning: d)
            decision = nil
        }
    }

    /// Checks an .ipa against this iPhone first: if it would be refused (ad-hoc signature, iPhone
    /// not in the profile…) the window explains why and offers to resign it with a profile on this Mac.
    func install(_ url: URL) async {
        guard url.pathExtension.lowercased() == "ipa" else { return await installFile(url) }
        let name = url.lastPathComponent
        report("Checking \(name)…", busy: true)
        let x: IPASigning.Extracted
        do { x = try await IPASigning.extract(url) } catch {
            report("Can't read \(name): \(error.localizedDescription)", error: true)
            return
        }
        defer { x.discard() }
        let issues = Signing.issues(x.info, udid: udid)
        if issues.isEmpty { return await installFile(url) }

        PMD3.log("[\(udid.prefix(8))] \(name) would be refused: " + issues.map(\.message).joined(separator: " "))
        let identities = await IPASigning.identities()
        let (plans, rejected) = resignOptions(x.info, identities: identities)
        let requirements = Signing.requirements(for: x.info, udid: udid, identities: identities)
        banner = nil
        let decision = await withCheckedContinuation { cont in
            installReview = InstallReview(ipa: url, info: x.info, issues: issues, plans: plans, rejected: rejected,
                                          requirements: requirements, identities: identities, decision: cont)
        }
        installReview = nil
        switch decision {
        case .cancel:
            return
        case .installAnyway:
            await installFile(url)
        case .resign(let plan):
            report("Resigning \(name)…", busy: true)
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            let out = uniqueURL(downloads.appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-resigned.ipa"))
            do { try await IPASigning.resign(x, plan: plan, to: out) } catch {
                report("Resign failed: \(error.localizedDescription)", error: true)
                return
            }
            PMD3.log("[\(udid.prefix(8))] \(name) resigned with \(plan.label) as \(plan.bundleID) -> \(out.path)")
            await installFile(out)
        }
    }

    /// Adds a profile the user picked (copied where Xcode keeps them) and looks for resign plans again.
    func addProfile(_ url: URL, to review: InstallReview) {
        do {
            let added = try IPASigning.addProfile(url)
            (review.plans, review.rejected) = resignOptions(review.info, identities: review.identities)
            review.profileError = Signing.rejection(of: added, for: review.info, udid: udid, identities: review.identities)
                .map { "\(added.name) can't be used: \($0)." }
        } catch {
            review.profileError = error.localizedDescription
        }
    }

    /// Resign plans from this Mac's profiles, and why the other profiles can't be used.
    private func resignOptions(_ info: IPAInfo, identities: [SigningIdentity]) -> ([ResignPlan], [String]) {
        let profiles = IPASigning.installedProfiles()
        let plans = Signing.plans(for: info, udid: udid, profiles: profiles, identities: identities)
        let rejected = profiles.compactMap { p in
            Signing.rejection(of: p, for: info, udid: udid, identities: identities).map { "\(p.name): \($0)" }
        }
        return (plans, rejected)
    }

    private func installFile(_ url: URL) async {
        report("Installing \(url.lastPathComponent)…", busy: true)
        let r = await PMD3.run(["apps", "install", url.path], udid: udid, timeout: 900)
        if r.ok {
            report("\(url.lastPathComponent) installed")
            notify("App installed", url.lastPathComponent)
            await refreshApps()
        } else {
            report("Install failed: \(r.errorSummary)", error: true)
            notify("Install failed", "\(url.lastPathComponent): \(r.errorSummary)")
        }
    }

    func launch(_ app: AppInfo, options: LaunchOptions = LaunchOptions()) async {
        let args: [String]
        do { args = try options.command(bundleID: app.bundle_id) } catch {
            report(error.localizedDescription, error: true)
            return
        }
        if options.console { return console.start(args, appName: app.name) }
        report("Launching \(app.name)…", busy: true)
        let r = await PMD3.run(args, udid: udid, timeout: 90)
        report(r.ok ? "\(app.name) launched" : "Launch failed: \(r.errorSummary)", error: !r.ok)
    }

    /// Last options used with "Launch with options…" for this app (shared by all iPhones).
    func launchOptions(for app: AppInfo) -> LaunchOptions {
        guard let data = UserDefaults.standard.data(forKey: "launchOptions.\(app.bundle_id)"),
              let o = try? JSONDecoder().decode(LaunchOptions.self, from: data) else { return LaunchOptions() }
        return o
    }

    func saveLaunchOptions(_ o: LaunchOptions, for app: AppInfo) {
        let key = "launchOptions.\(app.bundle_id)"
        if o.isEmpty { UserDefaults.standard.removeObject(forKey: key); return }
        if let data = try? JSONEncoder().encode(o) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// Copies the app's container (or its Documents folder, when that's all the iPhone vends) to ~/Downloads.
    func downloadContainer(_ app: AppInfo) async {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dest = uniqueURL(downloads.appendingPathComponent("\(Self.safeFileName(app.name)) container \(stamp)"))
        do { try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true) } catch {
            report("Can't create \(dest.lastPathComponent): \(error.localizedDescription)", error: true)
            return
        }
        report("Downloading \(app.name)'s container…", busy: true)
        var r = await PMD3.run(["apps", "pull", "--", app.bundle_id, "/", dest.path], udid: udid, timeout: 3600)
        var what = "container"
        if !r.ok {
            // Not development-signed: the iPhone vends only its Documents folder, if the app shares files.
            PMD3.log("[\(udid.prefix(8))] whole container of \(app.bundle_id) refused, trying Documents")
            r = await PMD3.run(["apps", "pull", "--documents", "--", app.bundle_id, "/Documents", dest.path],
                               udid: udid, timeout: 3600)
            what = "Documents folder"
        }
        if r.ok {
            report("\(app.name)'s \(what) saved to Downloads")
            notify("Container downloaded", "\(app.name): \(dest.lastPathComponent)")
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } else {
            try? FileManager.default.removeItem(at: dest)
            report("Can't download \(app.name)'s files: \(r.errorSummary). Only development-signed apps, "
                   + "or apps that share their Documents, can be read.", error: true)
        }
    }

    /// Opens the app's container in the Files tab.
    func showFiles(of app: AppInfo) async {
        await setFilesScope(.app(bundleID: app.bundle_id, documentsOnly: false))
    }

    private static func safeFileName(_ s: String) -> String {
        let cleaned = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return cleaned.trimmingCharacters(in: .whitespaces).isEmpty ? "App" : cleaned
    }

    func uninstall(_ app: AppInfo) async {
        report("Uninstalling \(app.name)…", busy: true)
        let r = await PMD3.run(["apps", "uninstall", app.bundle_id], udid: udid, timeout: 180)
        if r.ok {
            report("\(app.name) uninstalled")
            apps.removeAll { $0.id == app.id }
        } else {
            report("Uninstall failed: \(r.errorSummary)", error: true)
        }
    }

    // MARK: Files (AFC: /var/mobile/Media, or an app's container over house_arrest)

    struct FileEntry: Identifiable, Hashable, Decodable {
        let name: String
        let dir: Bool
        let size: Int
        let mtime: String?
        var id: String { name }
    }

    var filesScope: FilesScope = .media
    var filesPath = "/"
    var files: [FileEntry] = []
    var filesLoading = false
    var filesError: String?

    func path(for entry: FileEntry) -> String {
        (filesPath as NSString).appendingPathComponent(entry.name)
    }

    var canGoUp: Bool { filesScope.canGoUp(from: filesPath) }

    /// Name of what is being browsed, for the Files tab and the drop hint.
    var filesScopeName: String {
        guard let id = filesScope.bundleID else { return "Media" }
        return apps.first { $0.bundle_id == id }?.name ?? id
    }

    func setFilesScope(_ scope: FilesScope) async {
        filesScope = scope
        filesPath = scope.root
        files = []
        await refreshFiles()
    }

    func openDirectory(_ path: String) async {
        filesPath = path.isEmpty ? filesScope.root : path
        await refreshFiles()
    }

    func goUp() async {
        await openDirectory(filesScope.parent(of: filesPath))
    }

    private struct ContainerListing: Decodable {
        let documents: Bool
        let entries: [FileEntry]
    }

    func refreshFiles() async {
        filesLoading = true
        defer { filesLoading = false }
        let scope = filesScope, path = filesPath
        let r: RunResult
        switch scope {
        case .media:
            r = await PMD3.runHelper(["afc-ls", path], udid: udid, timeout: 60)
        case let .app(bundleID, documentsOnly):
            r = await PMD3.runHelper(["container-ls", bundleID, path] + (documentsOnly ? ["--documents"] : []),
                                     udid: udid, timeout: 60)
        }
        guard scope == filesScope, path == filesPath else { return }  // moved elsewhere meanwhile
        var list: [FileEntry]?
        if r.ok, case let .app(bundleID, documentsOnly) = scope {
            if let listing = try? JSONDecoder().decode(ContainerListing.self, from: r.stdout) {
                list = listing.entries
                if listing.documents && !documentsOnly {
                    // The helper fell back to the Documents folder: browse from there from now on.
                    filesScope = .app(bundleID: bundleID, documentsOnly: true)
                    if !filesScope.canGoUp(from: filesPath) { filesPath = filesScope.root }
                    report("\(filesScopeName) isn't development-signed: only its Documents folder can be read")
                }
            }
        } else if r.ok {
            list = try? JSONDecoder().decode([FileEntry].self, from: r.stdout)
        }
        if let list {
            files = list.sorted { ($0.dir ? 0 : 1, $0.name.lowercased()) < ($1.dir ? 0 : 1, $1.name.lowercased()) }
            filesError = nil
        } else {
            files = []
            filesError = r.ok ? "Unreadable folder listing" : r.errorSummary
        }
    }

    /// `afc` for the Media folder, `apps … BUNDLE` for an app container. Positional arguments follow `--`.
    private func filesCommand(_ verb: String, _ paths: [String]) -> [String] {
        switch filesScope {
        case .media: return ["afc", verb, "--"] + paths
        case let .app(bundleID, _): return ["apps", verb] + filesScope.appFlags + ["--", bundleID] + paths
        }
    }

    /// Copies Mac files/folders into the current folder on the iPhone.
    func upload(_ urls: [URL]) async {
        for url in urls {
            let remote = (filesPath as NSString).appendingPathComponent(url.lastPathComponent)
            report("Copying \(url.lastPathComponent) to iPhone…", busy: true)
            let r = await PMD3.run(filesCommand("push", [url.path, remote]), udid: udid, timeout: 1800)
            if !r.ok {
                report("Copy failed: \(r.errorSummary)", error: true)
                return
            }
        }
        report(urls.count == 1 ? "\(urls[0].lastPathComponent) copied to \(filesPath)" : "\(urls.count) items copied to \(filesPath)")
        await refreshFiles()
    }

    /// Downloads a file or folder into ~/Downloads and shows it in Finder.
    func download(_ entry: FileEntry) async {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let dest = uniqueURL(downloads.appendingPathComponent(entry.name))
        report("Downloading \(entry.name)…", busy: true)
        let r = await PMD3.run(filesCommand("pull", [path(for: entry), dest.path]), udid: udid, timeout: 1800)
        if r.ok {
            report("\(entry.name) saved to Downloads")
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } else {
            report("Download failed: \(r.errorSummary)", error: true)
        }
    }

    func delete(_ entry: FileEntry) async {
        report("Deleting \(entry.name)…", busy: true)
        let r = await PMD3.run(filesCommand("rm", [path(for: entry)]), udid: udid, timeout: 300)
        report(r.ok ? "\(entry.name) deleted" : "Delete failed: \(r.errorSummary)", error: !r.ok)
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

    /// Last position simulated on this iPhone (kept across launches), to resume from it.
    var lastSimulated: CLLocationCoordinate2D? {
        get {
            guard let v = UserDefaults.standard.array(forKey: "lastSimulatedLocation.\(udid)") as? [Double], v.count == 2
            else { return nil }
            return CLLocationCoordinate2D(latitude: v[0], longitude: v[1])
        }
        set {
            access(keyPath: \.lastSimulated)
            withMutation(keyPath: \.lastSimulated) {
                if let c = newValue {
                    UserDefaults.standard.set([c.latitude, c.longitude], forKey: "lastSimulatedLocation.\(udid)")
                } else {
                    UserDefaults.standard.removeObject(forKey: "lastSimulatedLocation.\(udid)")
                }
            }
        }
    }

    /// The simulated location lasts as long as the `simulate-location set` process runs.
    func setLocation(_ c: CLLocationCoordinate2D) {
        stopLocationProcess()
        let args = ["developer", "dvt", "simulate-location", "set", "--",
                    String(format: "%.6f", c.latitude), String(format: "%.6f", c.longitude)]
        guard let p = try? PMD3.makeProcess(args, udid: udid) else { return }
        // The "Press Ctrl+C" hint goes to stdout, errors to stderr: read both from one pipe.
        let err = Pipe()
        p.standardOutput = err
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
                PMD3.log("simulate-location set exited (exit \(status))\n\(text)")
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
                    lastSimulated = c
                    report(String(format: "Simulated location: %.5f, %.5f", c.latitude, c.longitude))
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
        report(r.ok ? "Real location restored" : "Restore failed: \(r.errorSummary)", error: !r.ok)
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
        // Timer isn't Sendable: hand it to the termination handler through a box.
        final class TimerBox: @unchecked Sendable { var timer: Timer? }
        let timerBox = TimerBox()
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
        timerBox.timer = timer
        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                timerBox.timer?.invalidate()
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
            report("Export failed: \(error.localizedDescription)", error: true)
        }
    }

    // MARK: Device info and power

    var info: DeviceInfo?
    var infoLoading = false
    var infoError: String?

    func refreshInfo() async {
        infoLoading = true
        defer { infoLoading = false }
        let r = await PMD3.runHelper(["info"], udid: udid, timeout: 60)
        if r.ok, let parsed = DeviceInfo.parse(r.stdout) {
            info = parsed
            infoError = nil
        } else {
            infoError = r.ok ? "Unreadable device info" : r.errorSummary
        }
    }

    enum PowerAction: String {
        case restart = "Restart", shutdown = "Shut Down"
        var command: String { self == .restart ? "restart" : "shutdown" }
        var progress: String { self == .restart ? "Restarting" : "Shutting down" }
    }

    func power(_ action: PowerAction, deviceName: String) async {
        report("\(action.progress) \(deviceName)…", busy: true)
        let r = await PMD3.run(["diagnostics", action.command], udid: udid, timeout: 60)
        if r.ok {
            report("\(action.progress) \(deviceName)")
            notify("\(action.progress) \(deviceName)", "")
        } else {
            report("\(action.rawValue) failed: \(r.errorSummary)", error: true)
            notify("\(action.rawValue) failed", "\(deviceName): \(r.errorSummary)")
        }
    }

    // MARK: Lifecycle

    /// Stops every long-running process (window closed or app quitting).
    func shutdown(clearLocation: Bool) {
        installReview?.decide(.cancel)
        stopLog()
        console.stop()
        capture.stop()
        mounts.unmountAll()
        conditions.shutdown()
        processes.shutdown()
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
