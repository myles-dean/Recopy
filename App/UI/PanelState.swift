import AppKit
import Observation

enum PanelTab: Hashable { case history, snippets }

/// A row in the panel's list: a copy, or a snippet.
enum Entry: Identifiable, Equatable {
    case clip(ClipItem)
    case snippet(Snippet)

    var id: UUID {
        switch self {
        case .clip(let item): item.id
        case .snippet(let snippet): snippet.id
        }
    }

    var clip: ClipItem? { if case .clip(let item) = self { item } else { nil } }
}

/// What the panel shows: the search, the tab, the selected row. It starts fresh each time the
/// panel opens, like a menu.
@MainActor
@Observable
final class PanelState {
    static let shared = PanelState()

    var query = "" {
        didSet {
            if query != oldValue { select(0) }
            if !query.isEmpty { optionsOpen = false }
        }
    }
    var tab: PanelTab = .history {
        didSet { if tab != oldValue { select(0) } }
    }
    private(set) var selection = 0
    /// The row to bring into view (after a keyboard move).
    private(set) var scrollTarget: UUID?
    var optionsOpen = false
    /// Just copied: the panel is collapsing into the "Copied" pill, and the word is showing.
    var copied = false
    var copiedLabel = false
    var ignoredOpen = false
    var confirmingClear = false
    /// Counts openings, so the search field takes the cursor each time.
    private(set) var openings = 0
    /// The list's height, set for the screen when the panel opens.
    var maxListHeight: CGFloat = 400
    /// While the shortcut field is recording, keys are left to it.
    @ObservationIgnored var recordingShortcut = false
    /// Where the pointer was at the last key press (or when the panel opened). Rows that slide
    /// under a pointer that hasn't moved since (when the keyboard scrolls the list) don't take
    /// the selection.
    @ObservationIgnored private var stillPointer: NSPoint?

    func opened(options: Bool) {
        query = ""
        tab = .history
        selection = 0
        scrollTarget = nil
        ignoredOpen = false
        confirmingClear = false
        optionsOpen = options
        copied = false
        copiedLabel = false
        stillPointer = NSEvent.mouseLocation
        openings += 1
    }

    /// The rows, filtered by the search: every word has to be in the text.
    var entries: [Entry] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        switch tab {
        case .history:
            let history = History.shared
            let all = history.pinned + history.recent
            guard !words.isEmpty else { return all.map(Entry.clip) }
            return all.filter { item in
                words.allSatisfy { item.text.localizedStandardContains($0) || item.title.localizedStandardContains($0) }
            }.map(Entry.clip)
        case .snippets:
            let all = Snippets.shared.items
            guard !words.isEmpty else { return all.map(Entry.snippet) }
            return all.filter { snippet in
                words.allSatisfy { snippet.title.localizedStandardContains($0) || snippet.text.localizedStandardContains($0) }
            }.map(Entry.snippet)
        }
    }

    var selectedEntry: Entry? {
        let entries = entries
        return entries.indices.contains(selection) ? entries[selection] : nil
    }

    /// From the pointer.
    func hover(_ index: Int) {
        if let stillPointer {
            guard NSEvent.mouseLocation != stillPointer else { return }
            self.stillPointer = nil
        }
        selection = index
    }

    /// From the keyboard: moves and brings the row into view.
    func move(_ offset: Int) {
        let count = entries.count
        guard count > 0 else { return }
        stillPointer = NSEvent.mouseLocation
        select(min(max(selection + offset, 0), count - 1))
        scrollTarget = selectedEntry?.id
    }

    func select(_ index: Int) {
        selection = max(index, 0)
    }

    /// After a row goes away, the selection stays in range.
    func clampSelection() {
        let count = entries.count
        if selection >= count { selection = max(count - 1, 0) }
    }
}

/// What the rows, the keyboard and the menus do.
@MainActor
enum Actions {
    /// Closes the panel (set by the app delegate).
    static var closePanel: (() -> Void)?
    /// Turns the panel into the "Copied" pill, which then goes away (set by the app delegate).
    static var showCopied: (() -> Void)?

    static func pick(_ entry: Entry) {
        switch entry {
        case .clip(let item): copy(item.id)
        case .snippet(let snippet): copyText(snippet.text)
        }
    }

    /// Back on the clipboard and to the top of the list, then the panel collapses into "Copied"
    /// and goes away. While the paste stack is on, it joins the stack instead (and the panel
    /// stays open to add more).
    static func copy(_ id: UUID) {
        if PasteStack.shared.isOn {
            PasteStack.shared.add(id)
            return
        }
        guard let item = History.shared.item(id) else { return }
        ClipboardWriter.write(item)
        History.shared.moveToTop(id)
        showCopied?()
    }

    /// A snippet or a path. Snippets don't add to the history, except to join the paste stack.
    static func copyText(_ text: String) {
        if PasteStack.shared.isOn {
            PasteStack.shared.add(History.shared.addText(text, sourceName: "Recopy"))
            return
        }
        ClipboardWriter.writeText(text)
        showCopied?()
    }

    static func copyPaths(_ item: ClipItem) {
        copyText(item.paths.joined(separator: "\n"))
    }

    static func showInFinder(_ item: ClipItem) {
        let urls = item.paths.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { NSSound.beep(); return }
        closePanel?()
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    static func togglePin(_ id: UUID) {
        History.shared.togglePin(id)
    }

    static func delete(_ entry: Entry) {
        switch entry {
        case .clip(let item):
            History.shared.delete(item.id)
            PasteStack.shared.prune()
        case .snippet(let snippet):
            Snippets.shared.delete(snippet.id)
        }
        PanelState.shared.clampSelection()
    }

    static func edit(_ entry: Entry) {
        switch entry {
        case .clip(let item):
            guard item.isText else { NSSound.beep(); return }
            closePanel?()
            EditorWindow.shared.editItem(item)
        case .snippet(let snippet):
            closePanel?()
            EditorWindow.shared.editSnippet(snippet)
        }
    }

    static func saveAsSnippet(_ item: ClipItem) {
        closePanel?()
        EditorWindow.shared.newSnippet(text: History.shared.fullText(item))
    }

    static func newSnippet() {
        closePanel?()
        EditorWindow.shared.newSnippet()
    }

    static func clearHistory() {
        History.shared.clear()
        PasteStack.shared.prune()
        PanelState.shared.clampSelection()
    }
}
