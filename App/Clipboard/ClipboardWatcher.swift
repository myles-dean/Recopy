import AppKit
import Observation

/// Notices each copy. macOS has no notification for that, so (like every clipboard history) this
/// checks the clipboard's change count a few times a second, which costs next to nothing, and
/// reads the clipboard only when it has changed.
@MainActor
@Observable
final class ClipboardWatcher {
    static let shared = ClipboardWatcher()

    /// macOS asks before Recopy reads the clipboard (or won't let it): Privacy & Security ›
    /// Paste from Other Apps, where Recopy needs "Always Allow".
    private(set) var needsPermission = false

    private var pasteboard: NSPasteboard { Clipboard.pasteboard }
    @ObservationIgnored private var lastChangeCount = 0
    @ObservationIgnored private var timer: Timer?

    func start() {
        lastChangeCount = pasteboard.changeCount
        updatePermission()
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { ClipboardWatcher.shared.check() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Recopy itself just wrote to the clipboard: that isn't a new copy.
    func noteOwnWrite() {
        lastChangeCount = pasteboard.changeCount
    }

    func updatePermission() {
        let behavior = pasteboard.accessBehavior
        needsPermission = behavior == .alwaysDeny || behavior == .ask
    }

    private func check() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count

        let settings = Settings.shared
        if settings.ignoreNext {
            settings.ignoreNext = false
            return
        }
        guard !settings.isPaused else { return }
        let front = NSWorkspace.shared.frontmostApplication
        if let id = front?.bundleIdentifier, settings.ignoredApps.contains(id) { return }
        updatePermission()
        guard pasteboard.accessBehavior != .alwaysDeny else { return }
        guard let capture = Capture.read(from: pasteboard, source: front) else { return }
        let id = History.shared.add(capture)
        PasteStack.shared.copied(id)
    }
}

/// Puts things back on the clipboard.
@MainActor
enum ClipboardWriter {
    /// An item as it was copied: all its kinds of data, or for files, the files themselves (for
    /// Finder and apps that take files) along with their paths as text (for everywhere else).
    static func write(_ item: ClipItem) {
        let pasteboard = Clipboard.pasteboard
        pasteboard.clearContents()
        pasteboard.writeObjects(contents(of: item).map(makeItem))
        ClipboardWatcher.shared.noteOwnWrite()
    }

    static func writeText(_ text: String) {
        let pasteboard = Clipboard.pasteboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        ClipboardWatcher.shared.noteOwnWrite()
    }

    /// What goes on the clipboard for an item: each pasteboard item's data, by type.
    static func contents(of item: ClipItem) -> [[(type: NSPasteboard.PasteboardType, data: Data)]] {
        switch item.kind {
        case .files:
            return item.paths.enumerated().map { index, path in
                var reps: [(type: NSPasteboard.PasteboardType, data: Data)] = [
                    (.fileURL, Data(URL(fileURLWithPath: path).absoluteString.utf8)),
                ]
                if index == 0 { reps.append((.string, Data(item.paths.joined(separator: "\n").utf8))) }
                return reps
            }
        default:
            let history = History.shared
            return item.pasteboardItems.map { reps in
                reps.compactMap { rep in
                    history.data(item, rep).map { (NSPasteboard.PasteboardType(rep.type), $0) }
                }
            }
        }
    }

    private static func makeItem(_ reps: [(type: NSPasteboard.PasteboardType, data: Data)]) -> NSPasteboardItem {
        let pbItem = NSPasteboardItem()
        for rep in reps { pbItem.setData(rep.data, forType: rep.type) }
        return pbItem
    }
}
