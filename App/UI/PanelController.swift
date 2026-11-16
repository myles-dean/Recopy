import AppKit
import Carbon.HIToolbox
import Quartz
import SwiftUI

/// The panel that drops from the menu bar icon, in Control Center's Liquid Glass (like
/// Soundcheck's). It doesn't take focus from the app you're in, so ⌘V there works the moment it
/// closes. It closes when you click anywhere else or press Escape.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    static let width: CGFloat = 340
    static let cornerRadius: CGFloat = 24
    static let animationDuration: TimeInterval = 0.22
    /// Rows the list shows before it scrolls.
    static let visibleRows = 10
    /// The "Copied" pill a copy collapses the panel into, and its timing: the collapse (on the
    /// vault's Osmo curve), the word springing in partway through (Bouncy), the hold, and the
    /// pill lifting away into the menu bar (Osmo again).
    static let copiedSize = NSSize(width: 104, height: 36)
    static let collapseDuration: TimeInterval = 0.55
    static let labelDelay: TimeInterval = 0.12
    static let labelDuration: TimeInterval = 0.6
    static let copiedHold: TimeInterval = 0.55
    static let leaveDuration: TimeInterval = 0.4

    private let panel: KeyPanel
    private var hosting: NSHostingView<PanelRoot>!
    private var top: CGFloat = 0
    private var left: CGFloat = 0
    /// The menu bar icon's centre and the screen's usable area, for placing the pill.
    private var anchorMidX: CGFloat?
    private var visibleFrame: NSRect = .zero
    private var collapsing = false
    private var collapseNumber = 0
    private let motion = FrameMotion()
    private var shadowTimer: Timer?
    private var outsideClicks: Any?
    private var keyMonitor: Any?
    private var hiddenAt = Date.distantPast
    var onVisibilityChange: ((Bool) -> Void)?

    override init() {
        panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.hide() }
        hosting = NSHostingView(rootView: PanelRoot(onHeight: { [weak self] in self?.contentHeightChanged($0) }))
        hosting.sizingOptions = []
        panel.contentView = makeGlassContainer(around: hosting, cornerRadius: Self.cornerRadius)
    }

    var isVisible: Bool { panel.isVisible }

    /// From the menu bar icon or the shortcut: opens, or closes if it's open (including when the
    /// click on the icon is what just closed it).
    func toggle(under anchor: NSRect?) {
        // While it says "Copied", the icon or the shortcut brings the panel straight back.
        if collapsing { show(under: anchor); return }
        if panel.isVisible || Date().timeIntervalSince(hiddenAt) < 0.3 { hide() } else { show(under: anchor) }
    }

    /// Centred under `anchor` (the menu bar icon's frame on screen), or at the top right of the
    /// screen the pointer is on if there's no icon to hang from.
    func show(under anchor: NSRect?, options: Bool = false) {
        finishCollapse()
        let state = PanelState.shared
        FileIcons.reset()
        ClipboardWatcher.shared.updatePermission()
        let screen = anchor.flatMap { rect in NSScreen.screens.first { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) } }
            ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        visibleFrame = visible
        anchorMidX = anchor?.midX
        top = visible.maxY - 6
        left = visible.maxX - Self.width - 8
        if let anchor { left = min(max(anchor.midX - Self.width / 2, visible.minX + 8), visible.maxX - Self.width - 8) }
        // Ten rows, then it scrolls (fewer on a very short screen, to leave room for the rest).
        state.maxListHeight = max(min(CGFloat(Self.visibleRows) * EntryRow.height, visible.height - 300), 4 * EntryRow.height)
        state.opened(options: options)

        panel.setGlassFrame(frame(height: Self.measureHeight()))
        if !panel.isVisible {
            panel.alphaValue = 0
            onVisibilityChange?(true)
        }
        panel.makeKeyAndOrderFront(nil)
        startMonitors()
        refreshShadow(for: 0.2)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
    }

    func hide() {
        stopMonitors()
        QuickLook.shared.close()
        if collapsing { finishCollapse(); return }
        guard panel.isVisible else { return }
        hiddenAt = Date()
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; panel.animator().alphaValue = 0 }) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.panel.orderOut(nil)
                self.onVisibilityChange?(false)
            }
        }
    }

    /// After a copy: the panel collapses into a small "Copied" pill under the menu bar icon. The
    /// list melts away (fading, shrinking toward the top, blurring) as the glass closes in on
    /// the Osmo curve, the word springs in where the pill will be, it holds a moment, then the
    /// pill lifts away into the menu bar.
    func showCopied() {
        // Copies from the editor window have no panel to collapse.
        guard panel.isVisible, !collapsing, let content = panel.contentView else { return }
        collapsing = true
        collapseNumber += 1
        let number = collapseNumber
        stopMonitors()
        QuickLook.shared.close()
        let state = PanelState.shared
        withAnimation(.eased(.osmo, duration: Self.collapseDuration)) { state.copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.labelDelay) { [weak self] in
            guard let self, self.collapsing, self.collapseNumber == number else { return }
            withAnimation(.eased(.bouncy, duration: Self.labelDuration)) { state.copiedLabel = true }
        }

        let size = Self.copiedSize
        let from = panel.frame
        var x = (anchorMidX ?? from.midX) - size.width / 2
        if !visibleFrame.isEmpty { x = min(max(x, visibleFrame.minX + 8), visibleFrame.maxX - size.width - 8) }
        let pill = NSRect(x: x.rounded(), y: from.maxY - size.height, width: size.width, height: size.height)
        motion.run(in: content, duration: Self.collapseDuration, easing: .osmo, step: { [weak self] progress in
            let radius = Self.cornerRadius + (size.height / 2 - Self.cornerRadius) * progress
            self?.place(from.interpolated(to: pill, progress), cornerRadius: radius)
        }, completion: { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.copiedHold) { [weak self] in
                guard let self, self.collapsing, self.collapseNumber == number else { return }
                self.leave(number)
            }
        })
    }

    /// The pill shrinks a little and rises into the menu bar as it fades.
    private func leave(_ number: Int) {
        guard let content = panel.contentView else { finishCollapse(); return }
        let from = panel.frame
        let scale: CGFloat = 0.82
        let to = NSRect(x: from.midX - from.width * scale / 2, y: from.maxY + 4 - from.height * scale,
                        width: from.width * scale, height: from.height * scale)
        motion.run(in: content, duration: Self.leaveDuration, easing: .osmo, step: { [weak self] progress in
            guard let self else { return }
            let frame = from.interpolated(to: to, progress)
            self.place(frame, cornerRadius: frame.height / 2)
            self.panel.alphaValue = 1 - progress
        }, completion: { [weak self] in
            guard let self, self.collapseNumber == number else { return }
            self.finishCollapse()
        })
    }

    /// One frame of the collapse: the window, its glass and its shadow together, on whole pixels.
    private func place(_ frame: NSRect, cornerRadius: CGFloat) {
        panel.setGlassFrame(panel.backingAlignedRect(frame, options: .alignAllEdgesNearest))
        panel.setGlassCornerRadius(cornerRadius)
        panel.invalidateShadow()
    }

    /// The pill is gone (or cut short): the panel is put away, ready to open as usual.
    private func finishCollapse() {
        guard collapsing else { return }
        collapsing = false
        motion.cancel()
        hiddenAt = Date()
        panel.orderOut(nil)
        panel.alphaValue = 1
        panel.setGlassCornerRadius(Self.cornerRadius)
        // Straight back, without animating, while it's out of sight.
        let state = PanelState.shared
        state.copied = false
        state.copiedLabel = false
        onVisibilityChange?(false)
    }

    // Clicking another app, the desktop or the menu bar takes key status away; a window of
    // Recopy's own (Quick Look, the app picker) doesn't count. The "Copied" pill goes away by
    // itself.
    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible, !self.collapsing else { return }
            if let key = NSApp.keyWindow, key !== self.panel { return }
            self.hide()
        }
    }

    // MARK: Keys

    private func startMonitors() {
        if outsideClicks == nil {
            outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            }
        }
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
                return handled ? nil : event
            }
        }
    }

    private func stopMonitors() {
        for monitor in [outsideClicks, keyMonitor] { if let monitor { NSEvent.removeMonitor(monitor) } }
        outsideClicks = nil
        keyMonitor = nil
    }

    /// The panel's keys: arrows move, Return copies, ⌘1–⌘9 copy the first nine, Space or ⌘Y is
    /// Quick Look, Tab switches between History and Snippets, ⌘P pins, ⌘E edits, ⌘⌫ deletes.
    /// Everything else goes to the search field.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard panel.isVisible, event.window === panel || QuickLook.shared.owns(event.window) else { return false }
        let state = PanelState.shared
        guard !state.recordingShortcut else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""

        switch Int(event.keyCode) {
        case kVK_UpArrow:
            move(flags.contains(.command) ? -10_000 : -1)
            return true
        case kVK_DownArrow:
            move(flags.contains(.command) ? 10_000 : 1)
            return true
        case kVK_PageUp:
            move(-10)
            return true
        case kVK_PageDown:
            move(10)
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard !state.optionsOpen else { return false }
            if let entry = state.selectedEntry { Actions.pick(entry) }
            return true
        case kVK_Escape:
            if QuickLook.shared.isVisible {
                QuickLook.shared.close()
                panel.makeKey()
            } else if !state.query.isEmpty {
                state.query = ""
            } else if state.optionsOpen {
                state.optionsOpen = false
            } else {
                hide()
            }
            return true
        case kVK_Tab:
            state.optionsOpen = false
            state.tab = state.tab == .history ? .snippets : .history
            return true
        case kVK_Space where state.query.isEmpty && flags.isEmpty && !state.optionsOpen:
            toggleQuickLook()
            return true
        case kVK_Delete where flags == .command:
            if let entry = state.selectedEntry { Actions.delete(entry); QuickLook.shared.follow(state.selectedEntry) }
            return true
        default:
            break
        }

        guard flags == .command else { return false }
        if let digit = Int(characters), (1...9).contains(digit) {
            let entries = state.entries
            if entries.indices.contains(digit - 1) { Actions.pick(entries[digit - 1]) }
            return true
        }
        switch characters {
        case "y":
            toggleQuickLook()
            return true
        case "p":
            if let item = state.selectedEntry?.clip { Actions.togglePin(item.id) }
            return true
        case "e":
            if let entry = state.selectedEntry { Actions.edit(entry) }
            return true
        case "c":
            // Copying text selected in the search field is left alone.
            if let editor = panel.firstResponder as? NSTextView, editor.selectedRange().length > 0 { return false }
            if let entry = state.selectedEntry { Actions.pick(entry) }
            return true
        case "n":
            Actions.newSnippet()
            return true
        case ",":
            state.optionsOpen.toggle()
            return true
        case "w":
            hide()
            return true
        default:
            return false
        }
    }

    private func move(_ offset: Int) {
        PanelState.shared.move(offset)
        QuickLook.shared.follow(PanelState.shared.selectedEntry)
    }

    private func toggleQuickLook() {
        QuickLook.shared.toggle(PanelState.shared.selectedEntry)
        if !QuickLook.shared.isVisible { panel.makeKey() }
    }

    // MARK: Size

    /// The card's natural height, measured by laying out a copy of it.
    private static func measureHeight() -> CGFloat {
        let sizing = NSHostingView(rootView: PanelView().frame(width: width).fixedSize(horizontal: false, vertical: true))
        return ceil(sizing.fittingSize.height)
    }

    private func frame(height: CGFloat) -> NSRect {
        NSRect(x: left, y: top - height, width: Self.width, height: height)
    }

    /// Options or the paste stack opened or closed: the window follows the card, keeping its
    /// top edge where it is.
    private func contentHeightChanged(_ height: CGFloat) {
        let height = ceil(height)
        guard panel.isVisible, !collapsing, abs(height - panel.frame.height) > 0.5 else { return }
        panel.setGlassFrame(frame(height: height), animated: true, duration: Self.animationDuration)
        refreshShadow(for: Self.animationDuration + 0.1)
    }

    /// The window shadow follows the rounded shape only when recomputed, so keep recomputing it
    /// while the window changes size.
    private func refreshShadow(for duration: TimeInterval) {
        shadowTimer?.invalidate()
        let end = Date().addingTimeInterval(duration)
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                self?.panel.invalidateShadow()
                if Date() > end { timer.invalidate() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        shadowTimer = timer
    }
}

final class KeyPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }

    // Quick Look takes its items from whoever controls it: this panel, while it's key.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = QuickLook.shared
        panel.delegate = QuickLook.shared
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

/// The card at its natural height, pinned to the top of the window. While the window resizes the
/// card is briefly taller or shorter than it; a GeometryReader keeps the card at the top-left
/// even then.
struct PanelRoot: View {
    let onHeight: (CGFloat) -> Void
    private var state = PanelState.shared

    init(onHeight: @escaping (CGFloat) -> Void) { self.onHeight = onHeight }

    var body: some View {
        ZStack(alignment: .top) {
            GeometryReader { _ in
                PanelView()
                    .frame(width: PanelController.width)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
                    // A copy melts the list away toward the pill.
                    .opacity(state.copied ? 0 : 1)
                    .scaleEffect(state.copied ? 0.94 : 1, anchor: .top)
                    .blur(radius: state.copied ? 10 : 0)
            }
            .allowsHitTesting(!state.copied)
            CopiedLabel()
                .scaleEffect(state.copiedLabel ? 1 : 0.4)
                .opacity(state.copiedLabel ? 1 : 0)
        }
    }
}

/// The word in the "Copied" pill, in solid ink like macOS's own pills. It sits where the pill
/// ends up (the top of the panel), so the glass closes in around it.
private struct CopiedLabel: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text("Copied")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
            .fixedSize()
            .frame(maxWidth: .infinity)
            .frame(height: PanelController.copiedSize.height)
            .allowsHitTesting(false)
    }
}
