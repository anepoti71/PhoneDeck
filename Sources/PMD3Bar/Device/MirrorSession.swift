import AppKit
import Darwin
import Foundation
import Observation
import PMD3BarCore
import Security

/// One `serve-web` process mirroring one iPhone on its own local port.
/// Each process opens its own userspace tunnel, so several iPhones can be mirrored at once.
@MainActor
@Observable
final class MirrorSession: Identifiable {
    nonisolated let udid: String
    let port: Int
    private(set) var state: MirrorState = .stopped
    /// Bumped on every (re)start, so the window reloads the viewer.
    private(set) var generation = 0

    nonisolated var id: String { udid }
    var viewerURL: URL { URL(string: "http://127.0.0.1:\(port)/")! }
    var isActive: Bool { process != nil }

    /// Password serve-web requires from every request, new for each start. Without it anyone who can
    /// reach the port (another account on this Mac, any local process) could watch and control the
    /// iPhone. It is handed to serve-web on stdin, never on the command line, which `ps` shows to
    /// every user.
    private(set) var password = MirrorSession.newPassword()
    /// Credential the viewer window answers serve-web's challenge with, once the listener on the port
    /// has been verified to be this session's own process.
    var credential: URLCredential? {
        state == .running ? URLCredential(user: "phonedeck", password: password, persistence: .forSession) : nil
    }
    private static func newPassword() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Runs pymobiledevice3 with `--password` read from stdin, so the password never shows in `ps`.
    /// The arguments after `-c` keep `pymobiledevice3 developer core-device display serve-web` together,
    /// so `pkill -f` patterns in the RUNBOOK still match.
    private static let passwordFromStdin = """
        import runpy, sys
        password = sys.stdin.readline().rstrip("\\n")
        sys.argv = sys.argv[1:] + ["--password", password]
        runpy.run_module("pymobiledevice3", run_name="__main__", alter_sys=True)
        """

    /// Asked before an automatic restart: is the device still there?
    var isDeviceReachable: () -> Bool = { true }
    /// Called when the session ends in an error (for notifications).
    var onFailure: (String) -> Void = { _ in }

    private func fail(_ message: String) {
        state = .failed(message)
        onFailure(message)
    }

    private var process: Process?
    private var restartPending = false
    private var autoRestartsLeft = 1

    init(udid: String, port: Int) {
        self.udid = udid
        self.port = port
    }

    func start(userInitiated: Bool = true) {
        guard process == nil else { return }
        if userInitiated { autoRestartsLeft = 1 }
        guard Safety.viewerPorts.contains(port) else {
            fail("No free port for the viewer between \(Safety.viewerPorts.lowerBound) and \(Safety.viewerPorts.upperBound)")
            return
        }
        password = Self.newPassword()
        let p: Process
        do {
            p = try PMD3.makePythonProcess(
                ["-c", Self.passwordFromStdin, "pymobiledevice3", "developer", "core-device", "display", "serve-web",
                 "--http-port", String(port), "--bind", "127.0.0.1"], udid: udid)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        let log = PMD3.logHandle()
        p.standardOutput = log
        p.standardError = log
        let stdin = Pipe()
        p.standardInput = stdin
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor in self?.exited(proc, status: status) }
        }
        PMD3.log("$ serve-web --http-port \(port) --bind 127.0.0.1 --password <hidden> (udid \(udid))")
        do { try p.run() } catch {
            state = .failed(error.localizedDescription)
            return
        }
        stdin.fileHandleForWriting.write(Data((password + "\n").utf8))
        try? stdin.fileHandleForWriting.close()
        process = p
        state = .starting
        Task { await waitForViewer(p) }
    }

    private func waitForViewer(_ p: Process) async {
        let auth = "Basic " + Data("phonedeck:\(password)".utf8).base64EncodedString()
        for _ in 0..<90 {
            guard process === p, state == .starting else { return }
            // Only talk to the port once our own serve-web holds it: a process that grabbed the port
            // first must never get the password nor have its page shown as the viewer.
            guard processListens(pid: p.processIdentifier, port: port) else {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            var request = URLRequest(url: viewerURL)
            request.timeoutInterval = 1
            request.setValue(auth, forHTTPHeaderField: "Authorization")
            if let (_, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                generation += 1
                state = .running
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
        if process === p, state == .starting {
            fail("The viewer is not responding: see the log")
            p.interrupt()
        }
    }

    private func exited(_ p: Process, status: Int32) {
        guard process === p else { return }
        PMD3.log("serve-web :\(port) exited (exit \(status))")
        process = nil
        if restartPending {
            restartPending = false
            start(userInitiated: false)
            return
        }
        switch state {
        case .stopping, .stopped: state = .stopped
        case .failed: break
        case .running where autoRestartsLeft > 0 && isDeviceReachable():
            // Unexpected exit (e.g. the link changed under it): try once more on whatever link is up now.
            autoRestartsLeft -= 1
            PMD3.log("serve-web :\(port) exited unexpectedly: restarting automatically")
            state = .starting
            Task {
                try? await Task.sleep(for: .seconds(2))
                if process == nil, state == .starting { state = .stopped; start(userInitiated: false) }
            }
        default: fail("Mirroring ended (exit \(status)): see the log")
        }
    }

    func stop() {
        guard let p = process, p.isRunning else {
            process = nil
            state = .stopped
            return
        }
        state = .stopping
        p.interrupt()  // SIGINT = Ctrl+C: lets serve-web shut the stream down cleanly
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { if p.isRunning { p.terminate() } }
    }

    /// Stops serve-web and starts it again as soon as it has exited (e.g. after the USB cable is pulled).
    func restart() {
        guard let p = process, p.isRunning else { start(userInitiated: false); return }
        restartPending = true
        state = .starting
        p.interrupt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { if p.isRunning { p.terminate() } }
    }

    /// Used at quit: there is no run loop left to wait on, so block briefly.
    func stopSync() {
        guard let p = process, p.isRunning else { return }
        p.interrupt()
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate() }
    }
}

/// True if process `pid` itself has a TCP socket listening on `port`.
func processListens(pid: pid_t, port: Int) -> Bool {
    let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard bytes > 0 else { return false }
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride + 8)
    let filled = fds.withUnsafeMutableBytes {
        proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
    }
    guard filled > 0 else { return false }
    for fd in fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
              info.psi.soi_kind == SOCKINFO_TCP else { continue }
        let tcp = info.psi.soi_proto.pri_tcp
        let localPort = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
        if localPort == port && tcp.tcpsi_state == TSI_S_LISTEN { return true }
    }
    return false
}

/// True if nothing listens on 127.0.0.1:`port` (we can bind it).
func isLocalPortFree(_ port: Int) -> Bool {
    guard let port16 = UInt16(exactly: port), port16 > 0 else { return false }
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { Darwin.close(fd) }
    // Same as serve-web's server socket: a port left in TIME_WAIT by a stopped viewer counts as free.
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(port16.bigEndian)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    return withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
        }
    }
}
