import AppKit
import Carbon.HIToolbox
import Foundation
import ServiceManagement
import UserNotifications

/// True when running as a real .app bundle (not `swift run`): notifications and login items need one.
let runningAsAppBundle: Bool = Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")

// MARK: - Notifications

@MainActor
enum Notifier {
    private static var authorized = false
    private static var requested = false

    static func requestAuthorization() {
        guard runningAsAppBundle, !requested else { return }
        requested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in authorized = granted }
        }
    }

    /// Posts a notification if the user enabled them (menu ▸ Impostazioni ▸ Notifiche).
    static func post(_ title: String, _ body: String = "", enabled: Bool) {
        PMD3.log("Notifica: \(title) \(body)")
        guard enabled, runningAsAppBundle else { return }
        requestAuthorization()
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - Global keyboard shortcut (⌥⌘M)

/// System-wide hot key through Carbon's RegisterEventHotKey: needs no Accessibility permission.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    /// ⌥⌘M by default.
    init?(keyCode: Int = kVK_ANSI_M, modifiers: Int = cmdKey | optionKey, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { hotKey.action() }
            return noErr
        }, 1, &spec, me, &handlerRef)
        guard status == noErr else { return nil }
        let id = EventHotKeyID(signature: OSType(0x504D_4433), id: 1)  // 'PMD3'
        let reg = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard reg == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

// MARK: - Launch at login

enum LoginItem {
    static var available: Bool { runningAsAppBundle }

    static var enabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns an error message, or nil on success.
    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
