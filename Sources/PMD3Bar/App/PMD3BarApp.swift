import SwiftUI
import PMD3BarCore

@main
struct PMD3BarApp: App {
    @State private var model: AppModel

    init() {
        Self.migrateLegacyDefaults()
        let model = AppModel()
        _model = State(initialValue: model)
        MirrorWindows.shared.model = model
        // `open PMD3Bar.app --args --open <UDID>` starts mirroring that iPhone in its window at launch.
        let args = CommandLine.arguments
        if args.contains("--grid") {
            // Give the first device listing time to arrive.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { MirrorWindows.shared.showGrid() }
        }
        if args.contains("--test-notification") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.testNotification() }
        }
        if let i = args.firstIndex(of: "--open"), i + 1 < args.count {
            let udid = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MirrorWindows.shared.show(udid) }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            Image(nsImage: MenuBarIcon.image(menuIconState))
        }
        .menuBarExtraStyle(.window)
    }

    /// Until 0.1 the bundle id was `local.experiments.PMD3Bar`. It changed because Notification Center
    /// had cached the generic icon for it for good. Copy the old settings over once.
    private static func migrateLegacyDefaults() {
        let legacy = "local.experiments.PMD3Bar"
        let defaults = UserDefaults.standard
        guard Bundle.main.bundleIdentifier != legacy, !defaults.bool(forKey: "migratedFromLegacyBundleID"),
              let old = defaults.persistentDomain(forName: legacy) else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: "migratedFromLegacyBundleID")
        PMD3.log("Impostazioni migrate da \(legacy) (\(old.count) chiavi)")
    }

    private var menuIconState: MenuBarIcon.State {
        if !model.activeSessions.isEmpty { return .mirroring }
        return model.devices.contains(where: \.reachable) ? .idle : .noDevice
    }
}
