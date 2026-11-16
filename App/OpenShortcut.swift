import AppKit
import Carbon.HIToolbox
import Observation

/// The keyboard shortcut that opens Recopy from anywhere (⌃⌘V to start with), set in Options.
/// A system-wide hot key (Carbon's, which needs no permission).
@MainActor
@Observable
final class OpenShortcut {
    static let shared = OpenShortcut()

    /// Like "⌃⌘V"; nil when there's no shortcut.
    private(set) var display: String?
    @ObservationIgnored var onPress: (() -> Void)?
    @ObservationIgnored private var keyCode: UInt32 = 0
    @ObservationIgnored private var modifiers: UInt32 = 0
    @ObservationIgnored private var hotKey: EventHotKeyRef?
    @ObservationIgnored private var handler: EventHandlerRef?

    private enum Keys {
        static let keyCode = "shortcutKeyCode"
        static let modifiers = "shortcutModifiers"
        static let display = "shortcutDisplay"
        static let cleared = "shortcutCleared"
    }

    func start() {
        let defaults = UserDefaults.standard
        if let display = defaults.string(forKey: Keys.display) {
            keyCode = UInt32(defaults.integer(forKey: Keys.keyCode))
            modifiers = UInt32(defaults.integer(forKey: Keys.modifiers))
            self.display = display
        } else if !defaults.bool(forKey: Keys.cleared) {
            // ⌃⌘V: V for paste, and free in macOS and the usual apps (⇧⌘V is "paste as plain
            // text" in many apps, and ⌥⌘V moves files in Finder).
            keyCode = UInt32(kVK_ANSI_V)
            modifiers = UInt32(controlKey | cmdKey)
            display = "⌃⌘V"
        } else {
            return
        }
        register()
    }

    /// From a key press while recording. Needs a modifier (⌘, ⌥ or ⌃), except for F-keys.
    @discardableResult
    func record(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let isFunctionKey = Self.functionKeys[Int(event.keyCode)] != nil
        guard isFunctionKey || !flags.intersection([.command, .option, .control]).isEmpty else { return false }

        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        keyCode = UInt32(event.keyCode)
        modifiers = carbon

        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        text += isFunctionKey ? Self.functionKeyName(event.keyCode) : (event.charactersIgnoringModifiers?.uppercased() ?? "?")
        display = text

        let defaults = UserDefaults.standard
        defaults.set(Int(keyCode), forKey: Keys.keyCode)
        defaults.set(Int(modifiers), forKey: Keys.modifiers)
        defaults.set(text, forKey: Keys.display)
        defaults.set(false, forKey: Keys.cleared)
        register()
        return true
    }

    func clear() {
        unregister()
        display = nil
        let defaults = UserDefaults.standard
        for key in [Keys.keyCode, Keys.modifiers, Keys.display] { defaults.removeObject(forKey: key) }
        defaults.set(true, forKey: Keys.cleared)
    }

    private func register() {
        unregister()
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { OpenShortcut.shared.onPress?() } }
                return noErr
            }, 1, &type, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x5243_5059) /* 'RCPY' */, id: 1)
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { log.error("Couldn't register the shortcut (\(status, privacy: .public)); another app may use it") }
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19",
    ]

    private static func functionKeyName(_ code: UInt16) -> String { functionKeys[Int(code)] ?? "?" }
}
