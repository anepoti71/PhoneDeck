import CoreGraphics

/// Geometry of the viewer page in "device only" mode, shared by the injected script and the
/// window sizing. The page keeps a transparent `margin` on every side of the device frame (room
/// for the bezel's hardware buttons, which stick out of it), and the frame fills the rest of the
/// viewport height.
public enum ViewerLayout {
    /// Transparent space around the device frame, on every side (stage padding in layoutJS).
    public static let margin: CGFloat = 14
    /// Horizontal room the page keeps next to the device: one margin per side.
    public static var reservedWidth: CGFloat { 2 * margin }
    /// Vertical room the page keeps above and below the device: one margin per side.
    public static var ownReservedHeight: CGFloat { 2 * margin }
    /// fitCanvasToViewport(): `reservedW = trays + 48 + 40` (trays are hidden in this mode).
    public static let viewerReservedWidth: CGFloat = 88
    /// fitCanvasToViewport(): `availH = innerHeight - 150`.
    public static let viewerReservedHeight: CGFloat = 150

    /// Viewport width that lets the device (width / height = `ratio`) fill the viewport height.
    /// The bezel is proportional to the screen, so the frame has the screen's proportions.
    public static func viewportWidth(forHeight height: CGFloat, ratio: Double) -> CGFloat {
        reservedWidth + max(100, height - ownReservedHeight) * CGFloat(ratio)
    }
}
