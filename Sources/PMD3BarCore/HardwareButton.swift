import Foundation

/// The iPhone's physical buttons, as the viewer presses them (`POST /button {name, state}`).
/// The app sends `down`, waits `hold`, then sends `up` itself: the server's own `press` holds
/// Lock 0.5 s, which iOS reads as a side-button hold and starts Siri, and its Siri usage (0xCF)
/// does nothing on iOS. So Lock is a short tap of the side button and Siri is a long hold of it.
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

    /// The `name` the server's `/button` takes (`_NAMED_BUTTONS` in screen_stream.py).
    public var serverName: String {
        switch self {
        case .siri: return HardwareButton.lock.rawValue
        default: return rawValue
        }
    }

    /// Seconds between `down` and `up`.
    public var hold: Double {
        switch self {
        case .lock: return 0.1
        case .siri: return 1.5
        default: return 0.05
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
