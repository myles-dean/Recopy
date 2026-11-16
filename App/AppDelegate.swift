import AppKit
import ServiceManagement

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    private var statusItem: StatusItemController!
    private var panel: PanelController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        History.shared.load()
        Snippets.shared.load()
        ClipboardWatcher.shared.start()

        statusItem = StatusItemController()
        panel = PanelController()
        Actions.closePanel = { [weak self] in self?.panel.hide() }
        Actions.showCopied = { [weak self] in self?.panel.showCopied() }
        statusItem.onClick = { [weak self] in self?.togglePanel() }
        statusItem.onOptions = { [weak self] in self?.showPanel(options: true) }
        panel.onVisibilityChange = { [weak self] visible in self?.statusItem.setHighlighted(visible) }
        OpenShortcut.shared.onPress = { [weak self] in self?.togglePanel() }
        OpenShortcut.shared.start()

        // The first time, start at login and show the panel. After that, opening the app
        // yourself shows the panel; starting at login doesn't.
        let defaults = UserDefaults.standard
        let firstLaunch = !defaults.bool(forKey: "launchedBefore")
        defaults.set(true, forKey: "launchedBefore")
        if firstLaunch { try? SMAppService.mainApp.register() }
        let event = NSAppleEventManager.shared().currentAppleEvent
        let isLoginItem = event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        let isOpenApp = event?.eventClass == kCoreEventClass && event?.eventID == kAEOpenApplication
        if isOpenApp && !isLoginItem && !CommandLine.arguments.contains("--background") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.showPanel() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The paste stack's next item stays on the clipboard as an ordinary copy.
        PasteStack.shared.stop()
        History.shared.saveNow()
        Storage.flush()
    }

    private func togglePanel() {
        panel.toggle(under: statusItem.frameOnScreen)
    }

    private func showPanel(options: Bool = false) {
        panel.show(under: statusItem.frameOnScreen, options: options)
    }

    /// Edit commands for the search field and the editor (an app without a menu bar still needs
    /// them for ⌘C, ⌘V, ⌘A and ⌘Z to work in text fields).
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit Recopy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        return main
    }
}
