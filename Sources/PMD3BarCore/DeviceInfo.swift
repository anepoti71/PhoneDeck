import Foundation

/// What `pmd3bar_helper.py info` reports: identity, storage and battery of one iPhone.
public struct DeviceInfo: Sendable, Equatable {
    public struct Row: Sendable, Equatable, Identifiable {
        public let label: String
        public let value: String
        public var id: String { label }
        public init(label: String, value: String) { self.label = label; self.value = value }
    }

    public struct Storage: Sendable, Equatable {
        public let total: Int64
        /// Free right now.
        public let available: Int64
        /// Free once iOS deletes purgeable data (caches, offloadable content); nil when no larger.
        public let availableWithPurgeable: Int64?
        public var used: Int64 { max(0, total - available) }
        public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
        public init(total: Int64, available: Int64, availableWithPurgeable: Int64? = nil) {
            self.total = total
            self.available = available
            self.availableWithPurgeable = availableWithPurgeable
        }
    }

    public struct Battery: Sendable, Equatable {
        /// Charge, 0–100.
        public let percent: Int?
        public let charging: Bool
        public let pluggedIn: Bool
        public let cycles: Int?
        /// Current maximum capacity against the design capacity, 0–100+.
        public let health: Int?
        public let temperatureC: Double?
    }

    public let rows: [Row]
    public let storage: Storage?
    public let battery: Battery?
    /// Parts that could not be read ("battery: …").
    public let errors: [String]

    public init(rows: [Row], storage: Storage?, battery: Battery?, errors: [String]) {
        self.rows = rows
        self.storage = storage
        self.battery = battery
        self.errors = errors
    }

    /// Lockdown keys shown, in order, with their label.
    static let shownKeys: [(key: String, label: String)] = [
        ("DeviceName", "Name"),
        ("ProductType", "Model"),
        ("ProductVersion", "iOS"),
        ("BuildVersion", "Build"),
        ("ModelNumber", "Model number"),
        ("SerialNumber", "Serial number"),
        ("UniqueDeviceID", "UDID"),
        ("HardwareModel", "Hardware"),
        ("CPUArchitecture", "CPU"),
        ("WiFiAddress", "Wi-Fi address"),
        ("BluetoothAddress", "Bluetooth address"),
    ]

    public static func parse(_ data: Data) -> DeviceInfo? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let device = obj["device"] as? [String: Any] ?? [:]
        var values = device.compactMapValues { v -> String? in
            if let s = v as? String { return s.isEmpty ? nil : s }
            if let n = v as? NSNumber { return n.stringValue }
            return nil
        }
        // "MN0X3" + "ZD/A" is what Settings ▸ About shows as model number.
        if let model = values["ModelNumber"], let region = values["RegionInfo"] { values["ModelNumber"] = model + region }
        let rows = shownKeys.compactMap { k in values[k.key].map { Row(label: k.label, value: $0) } }

        let disk = obj["disk"] as? [String: Any] ?? [:]
        var storage: Storage?
        if let total = int64(disk["TotalDataCapacity"]) ?? int64(disk["TotalDiskCapacity"]),
           let available = int64(disk["AmountDataAvailable"]) ?? int64(disk["TotalDataAvailable"]), total > 0 {
            let free = min(available, total)
            let withPurgeable = int64(disk["TotalDataAvailable"]).map { min($0, total) }
            storage = Storage(total: total, available: free,
                              availableWithPurgeable: withPurgeable.flatMap { $0 > free ? $0 : nil })
        }

        let b = obj["battery"] as? [String: Any] ?? [:]
        var battery: Battery?
        if !b.isEmpty {
            let design = int(b["DesignCapacity"])
            let maxCapacity = int(b["NominalChargeCapacity"]) ?? int(b["AppleRawMaxCapacity"])
            var health: Int?
            if let design, design > 0, let maxCapacity, maxCapacity > 0 {
                health = Int((Double(maxCapacity) / Double(design) * 100).rounded())
            }
            // IORegistry reports the temperature in hundredths of a degree.
            let temperature = int(b["Temperature"]).map { Double($0) / 100 }
            battery = Battery(
                percent: int(b["CurrentCapacity"]),
                charging: bool(b["IsCharging"]),
                pluggedIn: bool(b["ExternalConnected"]),
                cycles: int(b["CycleCount"]),
                health: health,
                temperatureC: temperature
            )
        }
        return DeviceInfo(rows: rows, storage: storage, battery: battery, errors: obj["errors"] as? [String] ?? [])
    }

    private static func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue ?? (v as? String).flatMap { Int($0) } }
    private static func int64(_ v: Any?) -> Int64? { (v as? NSNumber)?.int64Value }
    private static func bool(_ v: Any?) -> Bool { (v as? NSNumber)?.boolValue ?? false }
}

/// Arguments and environment for `developer core-device launch-application`, remembered per app.
public struct LaunchOptions: Codable, Sendable, Equatable {
    /// Shell-like: spaces separate arguments, quotes group them, backslash escapes.
    public var arguments: String
    /// One `KEY=value` per line.
    public var environment: String
    public var killExisting: Bool
    /// Stream the app's stdout and stderr to the Console tab until it exits.
    public var console: Bool

    public init(arguments: String = "", environment: String = "", killExisting: Bool = true, console: Bool = false) {
        self.arguments = arguments
        self.environment = environment
        self.killExisting = killExisting
        self.console = console
    }

    /// Options saved before a field existed decode with its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        arguments = try c.decodeIfPresent(String.self, forKey: .arguments) ?? ""
        environment = try c.decodeIfPresent(String.self, forKey: .environment) ?? ""
        killExisting = try c.decodeIfPresent(Bool.self, forKey: .killExisting) ?? true
        console = try c.decodeIfPresent(Bool.self, forKey: .console) ?? false
    }

    public enum ParseError: Error, Equatable, LocalizedError {
        case unclosedQuote
        case badVariable(line: Int, text: String)

        public var errorDescription: String? {
            switch self {
            case .unclosedQuote: return "Arguments: a quote is not closed."
            case let .badVariable(line, text): return "Environment line \(line) is not KEY=value: \(text)"
            }
        }
    }

    public func parsedArguments() throws -> [String] {
        var out: [String] = []
        var current = ""
        var inToken = false
        var quote: Character?
        var escaped = false
        for c in arguments {
            if escaped {
                current.append(c); escaped = false; inToken = true
            } else if c == "\\" && quote != "'" {
                escaped = true; inToken = true
            } else if let q = quote {
                if c == q { quote = nil } else { current.append(c) }
            } else if c == "\"" || c == "'" {
                quote = c; inToken = true
            } else if c.isWhitespace {
                if inToken { out.append(current); current = ""; inToken = false }
            } else {
                current.append(c); inToken = true
            }
        }
        if quote != nil { throw ParseError.unclosedQuote }
        if escaped { current.append("\\") }
        if inToken { out.append(current) }
        return out
    }

    /// `KEY=value` pairs; blank lines and `#` comments are skipped.
    public func parsedEnvironment() throws -> [String] {
        var out: [String] = []
        for (i, raw) in environment.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "="), eq != line.startIndex,
                  line[..<eq].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
                  !(line.first?.isNumber ?? false)
            else { throw ParseError.badVariable(line: i + 1, text: line) }
            out.append(line)
        }
        return out
    }

    /// Full argument list for `python -m pymobiledevice3`. Options come first and `--` ends them,
    /// so app arguments that start with `-` are never read as pymobiledevice3 options.
    public func command(bundleID: String) throws -> [String] {
        var args = ["developer", "core-device", "launch-application"]
        var env = try parsedEnvironment()
        if console {
            // As Xcode does: stdout unbuffered (it is a socket, not a terminal) and os_log/Logger
            // messages mirrored to stderr. Variables the user set win.
            let names = Set(env.map { String($0.prefix { $0 != "=" }) })
            for (name, value) in Self.consoleEnvironment where !names.contains(name) { env.append("\(name)=\(value)") }
        }
        for e in env { args += ["--env", e] }
        args.append(killExisting ? "--kill-existing" : "--no-kill-existing")
        if console { args.append("--console") }
        args.append("--")
        args.append(bundleID)
        args += try parsedArguments()
        return args
    }

    public static let consoleEnvironment = [("NSUnbufferedIO", "YES"), ("OS_ACTIVITY_DT_MODE", "YES")]

    public var isEmpty: Bool {
        arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && environment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && killExisting && !console
    }
}

/// Where the Files tab is browsing: the Media folder or an app's container.
public enum FilesScope: Hashable, Sendable {
    case media
    /// `documentsOnly`: the device vends only the app's Documents folder (not development-signed).
    case app(bundleID: String, documentsOnly: Bool)

    public var bundleID: String? {
        if case let .app(id, _) = self { return id }
        return nil
    }

    /// Topmost folder that can be listed.
    public var root: String {
        if case .app(_, true) = self { return "/Documents" }
        return "/"
    }

    public func canGoUp(from path: String) -> Bool {
        let p = Self.normalized(path)
        return p != root && p.hasPrefix(root == "/" ? "/" : root + "/")
    }

    /// Parent folder of `path`, never above `root`.
    public func parent(of path: String) -> String {
        guard canGoUp(from: path) else { return root }
        let parent = (Self.normalized(path) as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    static func normalized(_ path: String) -> String {
        var p = path.isEmpty ? "/" : path
        if !p.hasPrefix("/") { p = "/" + p }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Extra flags for `pymobiledevice3 apps pull|push|rm`.
    public var appFlags: [String] {
        if case .app(_, true) = self { return ["--documents"] }
        return []
    }
}
