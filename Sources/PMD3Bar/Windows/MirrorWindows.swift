import AppKit
import SwiftUI
import WebKit
import PMD3BarCore

/// One native window per mirrored iPhone. Closing the window stops that iPhone's stream.
@MainActor
final class MirrorWindows: NSObject, NSWindowDelegate {
    static let shared = MirrorWindows()
    private var windows: [String: NSWindow] = [:]
    weak var model: AppModel?

    /// What the window size follows: in "device only" mode with the tools closed, the window is
    /// as wide as the iPhone screen needs for its height (and keeps that shape when resized).
    private struct Fit {
        var ratio: Double?
        var deviceOnly = true
        var tools = false
        var active: Bool { deviceOnly && !tools && ratio != nil }
    }
    private var fits: [String: Fit] = [:]
    /// Windows showing only the mirrored iPhone: transparent around the device, like the Simulator.
    private var bare: Set<String> = []

    /// Makes the window transparent around the iPhone (only the iPhone showing, mirroring running),
    /// or back to a regular black window (controls, tools, placeholders).
    func setBare(_ udid: String, _ on: Bool) {
        if on { bare.insert(udid) } else { bare.remove(udid) }
        if let w = windows[udid] { applyBare(w, on) }
    }

    private func applyBare(_ w: NSWindow, _ on: Bool) {
        w.isOpaque = !on
        // Not black: the inspector (tools panel) shows the window background behind its top, and its
        // light-mode pickers were unreadable on black. The view paints black behind the iPhone itself.
        w.backgroundColor = on ? .clear : .windowBackgroundColor
        w.titlebarAppearsTransparent = on
        // Transparent window: the toolbar buttons sit on the desktop with no bar behind them, and
        // light-mode glyphs (dark grey) vanished on dark wallpapers. Dark ones match the iPhone frame.
        w.appearance = on ? NSAppearance(named: .darkAqua) : nil
        w.titleVisibility = on ? .hidden : .visible
        w.invalidateShadow()
    }

    /// The window shadow follows the device's shape: recompute it once the device is redrawn.
    func deviceLaidOut(_ udid: String) {
        guard bare.contains(udid), let w = windows[udid] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { w.invalidateShadow() }
    }
    /// Width the tools panel takes (inspectorColumnWidth ideal).
    static let toolsWidth: CGFloat = 340
    private static let minWidth: CGFloat = 300

    /// Reports a change of screen proportions, layout mode or tools panel for a window.
    func updateFit(_ udid: String, ratio: Double? = nil, deviceOnly: Bool? = nil, tools: Bool? = nil) {
        var fit = fits[udid] ?? Fit()
        let wasTools = fit.tools
        if let ratio { fit.ratio = ratio }
        if let deviceOnly { fit.deviceOnly = deviceOnly }
        if let tools { fit.tools = tools }
        let firstReport = fits[udid] == nil
        fits[udid] = fit
        guard let w = windows[udid] else { return }
        if !firstReport, let tools, tools != wasTools, tools {
            // Make room for the panel instead of squeezing the iPhone.
            resize(w, widthBy: Self.toolsWidth)
            return
        }
        if fit.active { fitToScreen(w, fit) }
    }

    private func fitToScreen(_ w: NSWindow, _ fit: Fit) {
        guard let web = webView(in: w), let ratio = fit.ratio else { return }
        let target = ViewerLayout.viewportWidth(forHeight: web.bounds.height, ratio: ratio)
        resize(w, widthBy: target - web.bounds.width)
    }

    private func resize(_ w: NSWindow, widthBy delta: CGFloat) {
        guard abs(delta) > 1 else { return }
        var frame = w.frame
        let newWidth = max(Self.minWidth, frame.width + delta)
        frame.origin.x += (frame.width - newWidth) / 2  // keep the window centred where it is
        frame.size.width = newWidth
        w.setFrame(frame, display: true, animate: true)
    }

    private func webView(in w: NSWindow) -> WKWebView? {
        func find(_ v: NSView) -> WKWebView? {
            if let web = v as? WKWebView { return web }
            for sub in v.subviews { if let web = find(sub) { return web } }
            return nil
        }
        return w.contentView.flatMap(find)
    }

    /// While fitting, resizing keeps the window around the iPhone: the width follows the height.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard let udid = sender.identifier?.rawValue, let fit = fits[udid], fit.active,
              let ratio = fit.ratio, let web = webView(in: sender) else { return frameSize }
        let chromeW = sender.frame.width - web.bounds.width
        let chromeH = sender.frame.height - web.bounds.height
        let width = chromeW + ViewerLayout.viewportWidth(forHeight: frameSize.height - chromeH, ratio: ratio)
        return NSSize(width: max(Self.minWidth, width), height: frameSize.height)
    }

    func show(_ udid: String) {
        guard let model else { return }
        // Session and tools exist before the view renders (no state changes during a view update).
        _ = model.tools(for: udid)
        let session = model.session(for: udid)
        // Below iOS 27 there is no screen streaming: the window still offers the tools.
        if !session.isActive, model.device(udid)?.supportsMirroring != false { model.startMirroring(udid) }
        if let w = windows[udid] {
            activate(w)
            return
        }
        let name = model.device(udid)?.name ?? "iPhone"
        let content = MirrorWindowView(model: model, udid: udid)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.title = name
        w.contentViewController = NSHostingController(rootView: content)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setFrameAutosaveName("PMD3Bar.mirror.\(udid)")
        if !w.setFrameUsingName("PMD3Bar.mirror.\(udid)") { w.center() }
        w.identifier = NSUserInterfaceItemIdentifier(udid)
        windows[udid] = w
        applyBare(w, bare.contains(udid))
        // Windows open: behave like a regular app (Dock, Cmd-Tab); back to menu-bar only when all close.
        NSApp.setActivationPolicy(.regular)
        activate(w)
    }

    /// ⌥⌘M: closes the window if it is the one in front, otherwise shows it.
    func toggle(_ udid: String) {
        if let w = windows[udid], w.isKeyWindow, NSApp.isActive {
            w.performClose(nil)
        } else {
            show(udid)
        }
    }

    private func activate(_ w: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    // MARK: Grid

    private var gridWindow: NSWindow?
    /// Sessions the grid started itself: closing the grid stops them unless they have their own window.
    private var gridStarted: Set<String> = []

    /// One window with every iPhone that can be mirrored, side by side, showing only the iPhones.
    func showGrid() {
        guard let model else { return }
        for d in model.devices where d.reachable && d.supportsMirroring {
            let s = model.session(for: d.id)
            if !s.isActive {
                model.startMirroring(d.id)
                gridStarted.insert(d.id)
            }
        }
        if let w = gridWindow { activate(w); return }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.title = "All iPhones"
        w.contentViewController = NSHostingController(rootView: GridView(model: model))
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setFrameAutosaveName("PMD3Bar.grid")
        if !w.setFrameUsingName("PMD3Bar.grid") { w.center() }
        w.identifier = NSUserInterfaceItemIdentifier(Self.gridID)
        gridWindow = w
        NSApp.setActivationPolicy(.regular)
        activate(w)
    }

    private static let gridID = "PMD3Bar.grid"

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, let id = w.identifier?.rawValue else { return }
        if id == Self.gridID {
            gridWindow = nil
            for udid in gridStarted where windows[udid] == nil { model?.stopMirroring(udid) }
            gridStarted.removeAll()
            if windows.isEmpty { NSApp.setActivationPolicy(.accessory) }
            return
        }
        let udid = id
        gridStarted.remove(udid)
        windows[udid] = nil
        fits[udid] = nil
        bare.remove(udid)
        // The grid may still be showing this iPhone: keep its stream then.
        model?.closeWindow(udid, keepMirroring: gridWindow != nil)
        if windows.isEmpty && gridWindow == nil { NSApp.setActivationPolicy(.accessory) }
    }
}
