import AppKit
import Darwin
import Foundation
import Observation
import PMD3BarCore

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
        let p: Process
        do {
            p = try PMD3.makeProcess(
                ["developer", "core-device", "display", "serve-web", "--http-port", String(port)], udid: udid)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        let log = PMD3.logHandle()
        p.standardOutput = log
        p.standardError = log
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor in self?.exited(proc, status: status) }
        }
        PMD3.log("$ serve-web --http-port \(port) (udid \(udid))")
        do { try p.run() } catch {
            state = .failed(error.localizedDescription)
            return
        }
        process = p
        state = .starting
        Task { await waitForViewer(p) }
    }

    private func waitForViewer(_ p: Process) async {
        for _ in 0..<90 {
            guard process === p, state == .starting else { return }
            var request = URLRequest(url: viewerURL)
            request.timeoutInterval = 1
            if let (_, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                generation += 1
                state = .running
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
        if process === p, state == .starting {
            fail("Il viewer non risponde: vedi il log")
            p.interrupt()
        }
    }

    private func exited(_ p: Process, status: Int32) {
        guard process === p else { return }
        PMD3.log("serve-web :\(port) terminato (exit \(status))")
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
            PMD3.log("serve-web :\(port) uscito inaspettatamente: riavvio automatico")
            state = .starting
            Task {
                try? await Task.sleep(for: .seconds(2))
                if process == nil, state == .starting { state = .stopped; start(userInitiated: false) }
            }
        default: fail("Mirroring terminato (exit \(status)): vedi il log")
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

/// True if nothing listens on 127.0.0.1:`port` (we can bind it).
func isLocalPortFree(_ port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { Darwin.close(fd) }
    // Same as serve-web's server socket: a port left in TIME_WAIT by a stopped viewer counts as free.
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port).bigEndian)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    return withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
        }
    }
}
