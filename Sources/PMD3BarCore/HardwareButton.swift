import Foundation

/// The iPhone's physical buttons, as the viewer presses them (`POST /button {name, state: "press"}`).
/// The server holds each one as long as the real button needs: Lock sleeps the iPhone, Siri
/// starts Siri.
public enum HardwareButton: String, CaseIterable, Sendable {
    case home
    case lock
    case volumeUp = "volume-up"
    case volumeDown = "volume-down"
    case mute
    case siri

    /// The Buttons menu in the mirror window. Home has its own toolbar button.
    public static let menu: [HardwareButton] = allCases.filter { $0 != .home }

    public var title: String {
        switch self {
        case .home: return "Home"
        case .lock: return "Lock"
        case .volumeUp: return "Volume Up"
        case .volumeDown: return "Volume Down"
        case .mute: return "Mute"
        case .siri: return "Siri"
        }
    }

    /// SF Symbol name.
    public var symbol: String {
        switch self {
        case .home: return "house"
        case .lock: return "lock"
        case .volumeUp: return "speaker.plus"
        case .volumeDown: return "speaker.minus"
        case .mute: return "speaker.slash"
        case .siri: return "mic"
        }
    }
}
