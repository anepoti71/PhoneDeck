import Foundation

/// "Paste from Mac": puts the Mac clipboard on the iPhone's pasteboard through the viewer
/// (`POST /clipboard` or `/clipboard/image`), then types ⌘V on the iPhone (`POST /key`).
///
/// The viewer has its own clipboard sync, but it reads the clipboard with
/// `navigator.clipboard.read()`, which WKWebView only allows after a paste prompt. The app
/// reads `NSPasteboard` natively instead and hands the content over.
public enum MacPaste {
    /// The viewer server's body limit for clipboard POSTs (`_CLIPBOARD_MAX_BODY`).
    public static let maxBytes = 32 * 1024 * 1024

    public enum Payload: Equatable, Sendable {
        case text(String)
        case png(Data)
    }

    public enum Problem: Error, Equatable, Sendable {
        case empty
        case tooLarge(bytes: Int)

        public var message: String {
            switch self {
            case .empty:
                return "The Mac clipboard has no text or image to paste."
            case .tooLarge(let bytes):
                let mb = { (n: Int) in ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .binary) }
                return "The Mac clipboard is too large to paste (\(mb(bytes)), the limit is \(mb(maxBytes)))."
            }
        }
    }

    private static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    /// Text if there is any (copied text often carries an image too, e.g. from a web page),
    /// otherwise a PNG. Text is pasted as is: whitespace can matter.
    public static func payload(text: String?, png: Data?) -> Result<Payload, Problem> {
        if let text, !text.isEmpty {
            let bytes = text.utf8.count
            return bytes > maxBytes ? .failure(.tooLarge(bytes: bytes)) : .success(.text(text))
        }
        if let png, png.starts(with: pngSignature) {
            return png.count > maxBytes ? .failure(.tooLarge(bytes: png.count)) : .success(.png(png))
        }
        return .failure(.empty)
    }

    /// HID usages for Left ⌘ and V.
    public static let leftCommand = 0xE3
    public static let keyV = 0x19

    /// Successive `/key` reports (each the full set of keys held): ⌘ down, V down, V up, ⌘ up,
    /// so iOS sees the modifier before the key, as from a real keyboard.
    public static let commandVReports: [[Int]] = [[leftCommand], [leftCommand, keyV], [leftCommand], []]
}
