import Foundation

/// Result of a finished pymobiledevice3 command.
struct RunResult {
    let status: Int32
    let stdout: Data
    let stderr: String

    var ok: Bool { status == 0 }

    /// Short, human-readable error taken from the end of stderr (strips rich's box drawing).
    var errorSummary: String {
        let boxChars = CharacterSet(charactersIn: "│╭╰╮╯─ ")
        let lines = stderr
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: boxChars) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Error") && !$0.hasPrefix("Usage") }
        let tail = lines.suffix(2).joined(separator: " ")
        return tail.isEmpty ? "Comando fallito (exit \(status))" : tail
    }
}

/// Locates the Python runtime and runs `python -m pymobiledevice3 ...`.
enum PMD3 {
    enum Source: String {
        case embedded = "Python incorporato"
        case environment = "PMD3_PYTHON"
        case conda = "conda env pymobiledevice"
    }

    /// Python with pymobiledevice3: bundled one first, then $PMD3_PYTHON, then the conda env (dev).
    static let python: (url: URL, source: Source)? = {
        let fm = FileManager.default
        if let res = Bundle.main.resourceURL?.appendingPathComponent("python/bin/python3"),
           fm.isExecutableFile(atPath: res.path) {
            return (res, .embedded)
        }
        if let env = ProcessInfo.processInfo.environment["PMD3_PYTHON"], fm.isExecutableFile(atPath: env) {
            return (URL(fileURLWithPath: env), .environment)
        }
        let conda = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("miniforge3/envs/pymobiledevice/bin/python")
        if fm.isExecutableFile(atPath: conda.path) {
            return (conda, .conda)
        }
        return nil
    }()

    static let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/PMD3Bar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pmd3bar.log")
    }()

    private static let logQueue = DispatchQueue(label: "pmd3bar.log")

    static func log(_ text: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "\(stamp) \($0)" }.joined(separator: "\n") + "\n"
        logQueue.async {
            guard let h = logHandle() else { return }
            h.write(Data(line.utf8))
            try? h.close()
        }
    }

    /// Opens the log in O_APPEND mode, so the app and its child processes never overwrite each other.
    static func logHandle() -> FileHandle? {
        let fd = open(logURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        return fd >= 0 ? FileHandle(fileDescriptor: fd, closeOnDealloc: true) : nil
    }

    /// Helper script shipped next to the Python runtime (or in the source tree when run with `swift run`).
    static let helperURL: URL? = {
        let fm = FileManager.default
        if let res = Bundle.main.resourceURL?.appendingPathComponent("pmd3bar_helper.py"),
           fm.fileExists(atPath: res.path) {
            return res
        }
        let src = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/pmd3bar_helper.py")
        return fm.fileExists(atPath: src.path) ? src : nil
    }()

    static func makeProcess(_ args: [String], udid: String?) throws -> Process {
        try makePythonProcess(["-m", "pymobiledevice3"] + args, udid: udid)
    }

    static func makePythonProcess(_ pythonArgs: [String], udid: String?) throws -> Process {
        guard let python else {
            throw NSError(domain: "PMD3Bar", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Python con pymobiledevice3 non trovato"
            ])
        }
        let p = Process()
        p.executableURL = python.url
        p.arguments = pythonArgs
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        env["COLUMNS"] = "200"
        if python.source == .embedded {
            env["PYTHONNOUSERSITE"] = "1"
            env["PYTHONDONTWRITEBYTECODE"] = "1"  // keep the signed bundle untouched
        }
        if let udid { env["PYMOBILEDEVICE3_UDID"] = udid } else { env.removeValue(forKey: "PYMOBILEDEVICE3_UDID") }
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        return p
    }

    /// Runs a command to completion, capturing stdout and stderr. Kills it after `timeout` seconds.
    static func run(_ args: [String], udid: String? = nil, timeout: TimeInterval = 60) async -> RunResult {
        await runPython(["-m", "pymobiledevice3"] + args, label: "pymobiledevice3 " + args.joined(separator: " "),
                        udid: udid, timeout: timeout)
    }

    /// Runs the bundled helper script (`pmd3bar_helper.py <args>`).
    static func runHelper(_ args: [String], udid: String? = nil, timeout: TimeInterval = 30) async -> RunResult {
        guard let helperURL else {
            return RunResult(status: -1, stdout: Data(), stderr: "pmd3bar_helper.py non trovato")
        }
        return await runPython(["-I", helperURL.path] + args, label: "helper " + args.joined(separator: " "),
                               udid: udid, timeout: timeout)
    }

    static func runPython(_ pythonArgs: [String], label: String, udid: String?, timeout: TimeInterval) async -> RunResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p: Process
                do { p = try makePythonProcess(pythonArgs, udid: udid) } catch {
                    cont.resume(returning: RunResult(status: -1, stdout: Data(), stderr: error.localizedDescription))
                    return
                }
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do { try p.run() } catch {
                    cont.resume(returning: RunResult(status: -1, stdout: Data(), stderr: error.localizedDescription))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if p.isRunning { p.terminate() }
                }
                final class Box: @unchecked Sendable { var data = Data() }
                let errBox = Box()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errBox.data = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                p.waitUntilExit()
                let errText = String(decoding: errBox.data, as: UTF8.self)
                log("$ \(label) -> exit \(p.terminationStatus)" + (errText.isEmpty ? "" : "\n" + errText))
                cont.resume(returning: RunResult(status: p.terminationStatus, stdout: outData, stderr: errText))
            }
        }
    }
}
