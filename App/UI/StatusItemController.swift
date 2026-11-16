import AppKit
import Observation

/// The menu bar icon: a solid clipboard (an outline was too thin to notice), dimmed while
/// recording is paused, with bullets and the number left to paste beside it while the paste
/// stack is on. Click for the panel; right-click (or Control-click) for a short menu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private static let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var onClick: (() -> Void)?
    var onOptions: (() -> Void)?

    override init() {
        super.init()
        item.autosaveName = "Recopy"
        item.behavior = []
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.setAccessibilityLabel("Recopy")
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
        update()
    }

    /// The icon's frame on screen.
    var frameOnScreen: NSRect? {
        guard let button = item.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    func setHighlighted(_ on: Bool) { item.button?.highlight(on) }

    private func update() {
        let settings = Settings.shared
        let stack = PasteStack.shared
        withObservationTracking {
            let image = NSImage(systemSymbolName: stack.isOn ? "list.bullet.clipboard.fill" : "list.clipboard.fill",
                                accessibilityDescription: "Recopy")?.withSymbolConfiguration(Self.symbolConfiguration)
            image?.isTemplate = true
            item.button?.image = image
            item.button?.appearsDisabled = settings.isPaused
            item.button?.title = stack.isOn && !stack.queue.isEmpty ? " \(stack.queue.count)" : ""
            item.button?.toolTip = settings.isPaused ? "Recopy (paused)" : "Recopy"
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.update() }
        }
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseDown || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            onClick?()
        }
    }

    private func showMenu() {
        let settings = Settings.shared
        let menu = NSMenu()
        menu.delegate = self
        let pause = menu.addItem(withTitle: "Pause Recording", action: #selector(togglePause), keyEquivalent: "")
        pause.state = settings.isPaused ? .on : .off
        let ignore = menu.addItem(withTitle: "Ignore Next Copy", action: #selector(toggleIgnoreNext), keyEquivalent: "")
        ignore.state = settings.ignoreNext ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: PasteStack.shared.isOn ? "Stop Paste Stack" : "Start Paste Stack",
                     action: #selector(toggleStack), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Options…", action: #selector(openOptions), keyEquivalent: "")
        menu.addItem(withTitle: "Quit Recopy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        for menuItem in menu.items where menuItem.action != #selector(NSApplication.terminate(_:)) { menuItem.target = self }
        item.menu = menu
        item.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        item.menu = nil
    }

    @objc private func togglePause() { Settings.shared.isPaused.toggle() }
    @objc private func toggleIgnoreNext() { Settings.shared.ignoreNext.toggle() }
    @objc private func toggleStack() { PasteStack.shared.toggle() }
    @objc private func openOptions() { onOptions?() }
}
