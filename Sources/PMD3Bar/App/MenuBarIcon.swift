import AppKit
import PMD3BarCore

/// Menu bar icon: the app logo (a screen with an iPhone in front) as a monochrome template image,
/// so macOS tints it for light/dark menu bars. One variant per state.
enum MenuBarIcon {
    enum State { case idle, mirroring, noDevice }

    private static var cache: [State: NSImage] = [:]

    static func image(_ state: State) -> NSImage {
        if let img = cache[state] { return img }
        let img = draw(state)
        cache[state] = img
        return img
    }

    private static func draw(_ state: State) -> NSImage {
        let size = NSSize(width: 20, height: 18)
        let img = NSImage(size: size, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let ink = NSColor.black
            ctx.setAlpha(state == .noDevice ? 0.45 : 1)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)

            // Screen behind
            let screen = NSBezierPath(roundedRect: NSRect(x: 1.75, y: 2.25, width: 16.5, height: 10.5), xRadius: 2.6, yRadius: 2.6)
            screen.lineWidth = 1.5
            ink.setStroke()
            screen.stroke()

            // iPhone in front: knock a gap out of the screen, then draw the phone
            let phoneRect = NSRect(x: 6.75, y: 5.25, width: 6.5, height: 11.75)
            ctx.setBlendMode(.clear)
            NSBezierPath(roundedRect: phoneRect.insetBy(dx: -1.5, dy: -1.5), xRadius: 3.2, yRadius: 3.2).fill()
            ctx.setBlendMode(.normal)
            let phone = NSBezierPath(roundedRect: phoneRect, xRadius: 2, yRadius: 2)
            phone.lineWidth = 1.5
            phone.stroke()
            ink.setFill()
            NSBezierPath(roundedRect: NSRect(x: 9, y: 7.1, width: 2, height: 1), xRadius: 0.5, yRadius: 0.5).fill()

            if state == .mirroring {
                // "Live" badge in the top-right corner
                let badge = NSRect(x: 14, y: 0.5, width: 5.5, height: 5.5)
                ctx.setBlendMode(.clear)
                NSBezierPath(ovalIn: badge.insetBy(dx: -1.25, dy: -1.25)).fill()
                ctx.setBlendMode(.normal)
                NSBezierPath(ovalIn: badge).fill()
            }
            ctx.endTransparencyLayer()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = switch state {
        case .idle: "PhoneDeck"
        case .mirroring: "PhoneDeck: mirroring active"
        case .noDevice: "PhoneDeck: no iPhone"
        }
        return img
    }
}
