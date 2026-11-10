import Foundation

/// Lines of a stream that arrives in arbitrary chunks (an app's console), keeping the last `limit`.
public struct ConsoleBuffer: Sendable {
    public struct Line: Identifiable, Sendable, Equatable {
        public let id: Int
        public let text: String
    }

    public private(set) var lines: [Line] = []
    /// Bytes after the last newline: a line (or a UTF-8 character) still being written.
    private var partial = Data()
    private var nextID = 0
    public let limit: Int

    public init(limit: Int = 5000) { self.limit = limit }

    public mutating func append(_ data: Data) {
        partial.append(data)
        while let nl = partial.firstIndex(of: 0x0A) {
            var line = partial[partial.startIndex..<nl]
            if line.last == 0x0D { line = line.dropLast() }
            add(String(decoding: line, as: UTF8.self))
            partial.removeSubrange(partial.startIndex...nl)
        }
        // A line with no newline yet but already long: show it rather than hold it forever.
        if partial.count > 16_384 {
            add(String(decoding: partial, as: UTF8.self))
            partial.removeAll()
        }
    }

    /// The stream ended: the unterminated tail becomes a line.
    public mutating func finish() {
        if !partial.isEmpty { add(String(decoding: partial, as: UTF8.self)) }
        partial.removeAll()
    }

    public mutating func removeAll() {
        lines.removeAll()
        partial.removeAll()
    }

    public var text: String { lines.map(\.text).joined(separator: "\n") }

    private mutating func add(_ text: String) {
        lines.append(Line(id: nextID, text: text))
        nextID += 1
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
    }
}

/// A summary line printed by `pmd3bar_helper.py pcap` while it captures.
public struct CaptureStats: Decodable, Sendable, Equatable {
    public struct Entry: Decodable, Sendable, Equatable, Identifiable {
        public let name: String
        public let packets: Int
        public let bytes: Int
        public var id: String { name }
    }

    public let seconds: Double
    public let packets: Int
    public let bytes: Int
    public let processes: [Entry]
    public let interfaces: [Entry]

    public static let empty = CaptureStats(seconds: 0, packets: 0, bytes: 0, processes: [], interfaces: [])

    public init(seconds: Double, packets: Int, bytes: Int, processes: [Entry], interfaces: [Entry]) {
        self.seconds = seconds
        self.packets = packets
        self.bytes = bytes
        self.processes = processes
        self.interfaces = interfaces
    }

    /// The last complete summary in `output` (one JSON object per line).
    public static func last(in output: String) -> CaptureStats? {
        for line in output.split(separator: "\n").reversed() {
            if let s = try? JSONDecoder().decode(CaptureStats.self, from: Data(line.utf8)) { return s }
        }
        return nil
    }
}

/// Interfaces offered for a capture, as pcapd names them (a name without its unit matches every unit).
public enum CaptureInterface: String, CaseIterable, Identifiable, Sendable {
    case all = "", wifi = "en0", cellular = "pdp_ip", vpn = "utun"
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .all: return "All interfaces"
        case .wifi: return "Wi-Fi"
        case .cellular: return "Cellular"
        case .vpn: return "VPN"
        }
    }
}

/// What `pymobiledevice3 apps webdav --mount` printed so far.
public enum WebDAVOutput {
    /// The local folder the container is mounted on ("Mounted; revealed /var/folders/…").
    public static func mountPath(in output: String) -> String? {
        for line in output.split(separator: "\n") {
            if let r = line.range(of: "Mounted; revealed ") {
                let path = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
                if !path.isEmpty { return path }
            }
        }
        return nil
    }

    /// The server runs but macOS could not mount it.
    public static func mountUnavailable(in output: String) -> Bool {
        output.contains("Automatic mount is unavailable")
    }
}
