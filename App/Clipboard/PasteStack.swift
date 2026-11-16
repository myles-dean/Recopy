import AppKit
import Observation

/// Copy several things, then paste them back one after another, in the order they were copied.
///
/// While it's on, every copy (from any app, or picked in Recopy) joins the end of the stack, and
/// the clipboard always holds the stack's next item. Recopy puts that item on the clipboard as a
/// promise: macOS asks Recopy for the data only when an app pastes it, which is how Recopy knows
/// it was pasted (no keyboard watching, no extra permission). A moment later the next item takes
/// its place. When the last one has been pasted the stack turns itself off.
@MainActor
@Observable
final class PasteStack: NSObject, NSPasteboardItemDataProvider {
    static let shared = PasteStack()

    private(set) var isOn = false
    /// Items still to paste, the next one first.
    private(set) var queue: [UUID] = []

    /// The pasteboard items standing in for the next item, and their data, by type.
    @ObservationIgnored private var promised: [(item: NSPasteboardItem, data: [NSPasteboard.PasteboardType: Data])] = []
    @ObservationIgnored private var promisedID: UUID?
    @ObservationIgnored private var advanceWork: DispatchWorkItem?

    /// Kept out of other clipboard histories (and Spotlight's), which would otherwise read the
    /// promise straight away and look like a paste.
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    var items: [ClipItem] { queue.compactMap { History.shared.item($0) } }

    func start() {
        guard !isOn else { return }
        isOn = true
        queue = []
    }

    /// Turns it off, leaving the next item (if any) on the clipboard as an ordinary copy.
    func stop() {
        guard isOn else { return }
        let next = queue.first.flatMap { History.shared.item($0) }
        isOn = false
        queue = []
        advanceWork?.cancel()
        advanceWork = nil
        if promisedID != nil, let next { ClipboardWriter.write(next) }
        promised = []
        promisedID = nil
    }

    func toggle() { if isOn { stop() } else { start() } }

    /// Added from Recopy (which turns the stack on if it's off).
    func add(_ id: UUID) {
        start()
        queue.append(id)
        putNext()
    }

    /// Copied in an app while the stack is on.
    func copied(_ id: UUID) {
        guard isOn else { return }
        queue.append(id)
        putNext()
    }

    func remove(at index: Int) {
        guard queue.indices.contains(index) else { return }
        queue.remove(at: index)
        if index == 0 { putNext() }
    }

    /// History lost an item (deleted or cleared): it leaves the stack too.
    func prune() {
        let before = queue.first
        queue.removeAll { History.shared.item($0) == nil }
        if queue.first != before { putNext() }
    }

    // MARK: The clipboard

    private func putNext() {
        advanceWork?.cancel()
        advanceWork = nil
        guard let id = queue.first, let item = History.shared.item(id) else {
            promised = []
            promisedID = nil
            return
        }
        let pasteboard = Clipboard.pasteboard
        // Not sent to your other devices with Universal Clipboard, which would read it at once.
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        promised = ClipboardWriter.contents(of: item).enumerated().map { index, reps in
            let pbItem = NSPasteboardItem()
            var data: [NSPasteboard.PasteboardType: Data] = [:]
            for rep in reps { data[rep.type] = rep.data }
            pbItem.setDataProvider(self, forTypes: Array(data.keys))
            if index == 0 { pbItem.setData(Data(), forType: Self.transient) }
            return (pbItem, data)
        }
        promisedID = id
        pasteboard.writeObjects(promised.map(\.item))
        ClipboardWatcher.shared.noteOwnWrite()
    }

    /// An app pasted the next item (it may ask for several kinds of data, all within a moment).
    private func pasted() {
        guard isOn, advanceWork == nil, promisedID != nil, promisedID == queue.first else { return }
        let work = DispatchWorkItem { [weak self] in self?.advance() }
        advanceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func advance() {
        advanceWork = nil
        guard isOn, !queue.isEmpty else { return }
        let done = queue.removeFirst()
        if queue.isEmpty {
            // Finished: the last item stays on the clipboard as an ordinary copy.
            isOn = false
            promised = []
            promisedID = nil
            if let item = History.shared.item(done) { ClipboardWriter.write(item) }
        } else {
            putNext()
        }
    }

    nonisolated func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        let provide = {
            MainActor.assumeIsolated {
                let stack = PasteStack.shared
                guard let entry = stack.promised.first(where: { $0.item === item }), let data = entry.data[type] else { return }
                item.setData(data, forType: type)
                stack.pasted()
            }
        }
        if Thread.isMainThread { provide() } else { DispatchQueue.main.sync(execute: provide) }
    }

    nonisolated func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {}
}
