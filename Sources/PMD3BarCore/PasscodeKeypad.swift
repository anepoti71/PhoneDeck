import Foundation

/// The iPhone lock screen's passcode keypad, drawn over the mirrored screen. iOS hides secure
/// input from screen capture, so the keys are missing from the stream while touches on them
/// still work: the overlay shows where they are and lets clicks through to the screen below.
///
/// iOS lays the keypad out in points, the same on every iPhone: round keys in a 3 × 4 grid
/// centred horizontally. Only its height on the screen varies by model, so `centerY` (the
/// keypad's middle, as a fraction of the screen height) can be adjusted and is remembered.
public enum PasscodeKeypad {
    public struct Key: Equatable, Codable, Sendable {
        public let digit: String
        public let letters: String
        /// Centre and radius as fractions of the screen: x and r of its width, y of its height.
        public let x: Double
        public let y: Double
        public let r: Double
    }

    /// Key diameter, column pitch and row pitch, in points.
    public static let keyDiameter = 76.0
    public static let columnPitch = 104.0
    public static let rowPitch = 90.0
    /// Middle of the keypad (between the 2nd and 3rd row) as a fraction of the screen height.
    public static let defaultCenterY = 0.565
    public static let centerYRange = 0.35...0.8

    static let layout: [(String, String)] = [
        ("1", ""), ("2", "ABC"), ("3", "DEF"),
        ("4", "GHI"), ("5", "JKL"), ("6", "MNO"),
        ("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ"),
        ("0", ""),
    ]

    /// Screen width in points for a stream `pixelWidth` wide: iPhones 1000 px wide or more are
    /// @3x, narrower ones @2x. Out-of-range results (a scaled stream) fall back to 390 pt.
    public static func pointWidth(pixelWidth: Double) -> Double {
        let points = pixelWidth / (pixelWidth >= 1000 ? 3 : 2)
        return (320...440).contains(points) ? points : 390
    }

    /// The ten keys for a portrait screen `width` × `height` pixels; none in landscape (the lock
    /// screen keypad is portrait only) or before the size is known.
    public static func keys(width: Double, height: Double, centerY: Double = defaultCenterY) -> [Key] {
        guard width > 0, height > width else { return [] }
        let pt = width / pointWidth(pixelWidth: width)   // pixels per point
        let cy = min(max(centerY, centerYRange.lowerBound), centerYRange.upperBound) * height
        let r = keyDiameter / 2 * pt / width
        return layout.enumerated().map { i, key in
            let row = Double(i / 3), col = i == 9 ? 1.0 : Double(i % 3)
            let x = width / 2 + (col - 1) * columnPitch * pt
            let y = cy + (row - 1.5) * rowPitch * pt
            return Key(digit: key.0, letters: key.1, x: x / width, y: y / height, r: r)
        }
    }

    /// The keys as JSON for the injected script.
    public static func json(_ keys: [Key]) -> String {
        (try? JSONEncoder().encode(keys)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}
