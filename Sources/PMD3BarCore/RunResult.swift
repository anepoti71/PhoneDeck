import Foundation

/// Result of a finished pymobiledevice3 command.
public struct RunResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: String

    public init(status: Int32, stdout: Data, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var ok: Bool { status == 0 }

    /// Short, human-readable error taken from the end of stderr (strips rich's box drawing).
    /// pymobiledevice3's log lines ("2026-… host __main__[pid] ERROR message") give just their message,
    /// without the hints it appends ("Please report it at…", "Run again with -v…").
    public var errorSummary: String {
        let boxChars = CharacterSet(charactersIn: "│╭╰╮╯─ ")
        let lines = stderr
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: boxChars) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Error") && !$0.hasPrefix("Usage") }
            .filter { !$0.hasPrefix("Please report it at") && !$0.contains("Run again with -v") }
        if let logged = lines.last(where: { $0.contains(" ERROR ") }),
           let r = logged.range(of: " ERROR ") {
            return String(logged[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        let tail = lines.suffix(2).joined(separator: " ")
        return tail.isEmpty ? "Command failed (exit \(status))" : tail
    }
}
