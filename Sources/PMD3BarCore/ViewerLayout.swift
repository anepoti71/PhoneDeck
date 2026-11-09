import CoreGraphics

/// Geometry of the viewer page in "device only" mode, shared by the injected script and the
/// window sizing: the screen gets the window height minus `ownReservedHeight` and needs
/// `reservedWidth` of horizontal room next to it.
public enum ViewerLayout {
    /// fitCanvasToViewport(): `reservedW = trays + 48 + 40` (trays are hidden in this mode).
    public static let reservedWidth: CGFloat = 88
    /// Height kept for the stage padding once the top bar and button row are hidden.
    public static let ownReservedHeight: CGFloat = 24
    /// fitCanvasToViewport(): `availH = innerHeight - 150`.
    public static let viewerReservedHeight: CGFloat = 150

    /// Viewport width that lets the screen (width / height = `ratio`) fill the viewport height.
    public static func viewportWidth(forHeight height: CGFloat, ratio: Double) -> CGFloat {
        reservedWidth + max(100, height - ownReservedHeight) * CGFloat(ratio)
    }
}
