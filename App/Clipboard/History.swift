import AppKit
import Observation

/// Everything copied, newest first. Copying the same thing again moves it back to the top
/// instead of adding it twice. Pinned items sit above the rest and are never trimmed or cleared.
@MainActor
@Observable
final class History {
    static let shared = History()

    private(set) var items: [ClipItem] = []
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var thumbnails: [UUID: NSImage] = [:]

    var pinned: [ClipItem] {
        items.filter(\.isPinned).sorted { ($0.pinnedAt ?? .distantPast) < ($1.pinnedAt ?? .distantPast) }
    }

    var recent: [ClipItem] { items.filter { !$0.isPinned } }

    func item(_ id: UUID) -> ClipItem? { items.first { $0.id == id } }

    // MARK: Adding

    /// Something was copied. Returns its item (an existing one, moved to the top, if it's been
    /// copied before).
    @discardableResult
    func add(_ capture: Capture) -> UUID {
        let now = Date()
        var item: ClipItem
        if let index = items.firstIndex(where: { $0.key == capture.key }) {
            item = items.remove(at: index)
            item.lastCopied = now
            item.copyCount += 1
            if capture.sourceBundleID != nil || capture.sourceName != nil {
                item.sourceBundleID = capture.sourceBundleID
                item.sourceName = capture.sourceName
            }
        } else {
            item = ClipItem(kind: capture.kind, text: capture.text, firstCopied: now, lastCopied: now, key: capture.key)
            item.sourceBundleID = capture.sourceBundleID
            item.sourceName = capture.sourceName
        }
        // What's on the clipboard now replaces what was kept (the same text can come back with
        // formatting, say).
        item.kind = capture.kind
        item.text = capture.text
        item.paths = capture.paths
        item.imageWidth = capture.imageSize.map { Int($0.width) }
        item.imageHeight = capture.imageSize.map { Int($0.height) }
        var files: [(name: String, data: Data)] = []
        item.pasteboardItems = capture.items.enumerated().map { itemIndex, reps in
            reps.enumerated().map { repIndex, rep in
                let name = "\(itemIndex)-\(repIndex)"
                files.append((name, rep.data))
                return ClipItem.Representation(type: rep.type, file: name)
            }
        }
        if let thumbnail = capture.thumbnail {
            files.append(("thumbnail.png", thumbnail))
            thumbnails[item.id] = NSImage(data: thumbnail)
        } else {
            thumbnails[item.id] = nil
        }
        item.hasThumbnail = capture.thumbnail != nil
        Storage.replace(item.id, files: files)
        items.insert(item, at: 0)
        trim()
        scheduleSave()
        return item.id
    }

    /// Plain text as a new copy (or an old one moved up).
    @discardableResult
    func addText(_ text: String, sourceName: String? = nil) -> UUID {
        add(Capture.text(text, sourceName: sourceName))
    }

    /// Copied again from Recopy: back to the top.
    func moveToTop(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: index)
        item.lastCopied = Date()
        item.copyCount += 1
        items.insert(item, at: 0)
        scheduleSave()
    }

    // MARK: Changing

    func togglePin(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].pinnedAt = items[index].isPinned ? nil : Date()
        trim()
        scheduleSave()
    }

    /// An edit: the item becomes the new text (plain, its formatting gone). If that text is
    /// already another item, the two become one.
    func replaceText(_ id: UUID, with text: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let capture = Capture.text(text)
        var item = items[index]
        if let other = items.firstIndex(where: { $0.key == capture.key && $0.id != id }) {
            if items[other].isPinned && !item.isPinned { item.pinnedAt = items[other].pinnedAt }
            delete(items[other].id)
        }
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        item.kind = .text
        item.text = capture.text
        item.paths = []
        item.key = capture.key
        item.imageWidth = nil
        item.imageHeight = nil
        item.hasThumbnail = false
        thumbnails[id] = nil
        item.pasteboardItems = [[ClipItem.Representation(type: NSPasteboard.PasteboardType.string.rawValue, file: "0-0")]]
        Storage.replace(id, files: [("0-0", Data(text.utf8))])
        items[index] = item
        scheduleSave()
    }

    func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
        thumbnails[id] = nil
        Storage.remove([id])
        scheduleSave()
    }

    /// Everything but the pinned items.
    func clear() {
        let gone = items.filter { !$0.isPinned }.map(\.id)
        items.removeAll { !$0.isPinned }
        for id in gone { thumbnails[id] = nil }
        Storage.remove(gone)
        scheduleSave()
    }

    /// Keeps the newest (unpinned) items, up to the limit in Options.
    func trim() {
        let limit = Settings.shared.historyLimit
        var kept = 0
        var gone: [UUID] = []
        items.removeAll { item in
            if item.isPinned { return false }
            kept += 1
            if kept > limit { gone.append(item.id); return true }
            return false
        }
        for id in gone { thumbnails[id] = nil }
        Storage.remove(gone)
        if !gone.isEmpty { scheduleSave() }
    }

    // MARK: Reading back

    /// The item's whole text (the list only keeps the start of long ones).
    func fullText(_ item: ClipItem) -> String {
        if let rep = item.pasteboardItems.first?.first(where: { $0.type == NSPasteboard.PasteboardType.string.rawValue }),
           let data = Storage.read(item.id, rep.file), let string = String(data: data, encoding: .utf8) {
            return string
        }
        return item.text
    }

    func data(_ item: ClipItem, _ rep: ClipItem.Representation) -> Data? {
        Storage.read(item.id, rep.file)
    }

    func thumbnail(_ item: ClipItem) -> NSImage? {
        guard item.hasThumbnail else { return nil }
        if let image = thumbnails[item.id] { return image }
        let image = Storage.read(item.id, "thumbnail.png").flatMap(NSImage.init(data:))
        thumbnails[item.id] = image
        return image
    }

    // MARK: Saving

    func load() {
        if let data = Storage.load(Storage.historyFile) {
            do {
                items = try JSONDecoder().decode([ClipItem].self, from: data)
            } catch {
                log.error("Couldn't read the history: \(error.localizedDescription, privacy: .public)")
            }
        }
        Storage.removeStrays(keeping: Set(items.map(\.id)))
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        guard let data = try? JSONEncoder().encode(items) else { return }
        Storage.save(data, to: Storage.historyFile)
    }
}
