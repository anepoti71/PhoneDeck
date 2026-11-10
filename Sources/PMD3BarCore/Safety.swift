import Foundation

/// Checks on values that come from outside the app (an `.ipa`, a provisioning profile, the iPhone,
/// a web page) before they are used as file names, paths, ports or URLs on this Mac.
public enum Safety {
    /// A bundle identifier as Apple allows it: letters, digits, `-` and `.`, at most 255 characters.
    /// Rejects anything that could act as a path (`/`, `..`) or break a plist or a command line.
    public static func isBundleID(_ s: String) -> Bool {
        guard !s.isEmpty, s.utf8.count <= 255, s != ".", s != ".." else { return false }
        return s.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "."
        }
    }

    /// A provisioning profile UUID (`XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX`).
    public static func isProfileUUID(_ s: String) -> Bool {
        s.count == 36 && UUID(uuidString: s) != nil
    }

    /// A single path component that stays where it is put: not empty, not `.` or `..`, no `/`
    /// (or `:`, which Finder shows as `/`) and no NUL.
    public static func isSafeFileName(_ s: String) -> Bool {
        guard !s.isEmpty, s != ".", s != ".." else { return false }
        return !s.contains("/") && !s.contains(":") && !s.contains("\0")
    }

    /// `name` made safe to use as one file name: separators and NULs become `-`, and an empty or
    /// dot-only result falls back to `fallback`.
    public static func fileName(_ name: String, fallback: String) -> String {
        let cleaned = String(name.map { $0 == "/" || $0 == ":" || $0 == "\0" ? "-" : $0 })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned.allSatisfy({ $0 == "." }) ? fallback : cleaned
    }

    // MARK: Ports

    /// Ports a viewer may use: unprivileged, and within TCP's range.
    public static let viewerPorts = 1024...65535

    /// First port from `start` on that no other session uses and `isFree` accepts, or nil when none
    /// is left. A `start` outside `viewerPorts` is clamped into it.
    public static func firstFreePort(from start: Int, used: Set<Int>, isFree: (Int) -> Bool) -> Int? {
        let first = min(max(start, viewerPorts.lowerBound), viewerPorts.upperBound)
        return (first...viewerPorts.upperBound).first { !used.contains($0) && isFree($0) }
    }

    // MARK: Viewer navigation

    /// True if `url` is the viewer served on `port` (exactly `http://127.0.0.1:<port>`).
    public static func isViewerURL(_ url: URL, port: Int) -> Bool {
        url.scheme == "http" && url.host == "127.0.0.1" && url.port == port
    }

    /// Whether a navigation away from the viewer may be handed to the default browser: only a link
    /// the user clicked, and only to a web or mail address. Never `file:`, apps or custom schemes.
    public static func mayOpenExternally(_ url: URL, userClicked: Bool) -> Bool {
        guard userClicked, let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "mailto"].contains(scheme)
    }
}
