import AppKit
import Quartz

/// Quick Look for the selected row: the files themselves, or the text or image written to a
/// file for the preview (in Caches, removed at the next launch). It follows the selection while
/// it's open.
@MainActor
final class QuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLook()

    private var urls: [URL] = []

    var isVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    func owns(_ window: NSWindow?) -> Bool {
        guard let window, QLPreviewPanel.sharedPreviewPanelExists() else { return false }
        return window === QLPreviewPanel.shared()
    }

    func toggle(_ entry: Entry?) {
        if isVisible { close() } else if let entry { show(entry) }
    }

    func show(_ entry: Entry) {
        urls = Self.urls(for: entry)
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { NSSound.beep(); return }
        if panel.isVisible {
            panel.reloadData()
        } else {
            // Recopy's panel normally takes control (it's the key window), but it may not be found
            // while another app is the active one.
            panel.updateController()
            if panel.dataSource == nil {
                panel.dataSource = self
                panel.delegate = self
            }
            // Over Recopy's panel (which sits at the menus' level).
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
            panel.orderFront(nil)
            panel.reloadData()
        }
    }

    /// The selection moved while Quick Look is open.
    func follow(_ entry: Entry?) {
        guard isVisible else { return }
        guard let entry else { close(); return }
        urls = Self.urls(for: entry)
        if urls.isEmpty { close() } else { QLPreviewPanel.shared().reloadData() }
    }

    func close() {
        guard isVisible else { return }
        QLPreviewPanel.shared().orderOut(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { urls.indices.contains(index) ? urls[index] as NSURL : nil }
    }

    /// Keys pressed in Quick Look go to Recopy's panel's key handling (which sees them first).
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool { false }

    // MARK: Files to preview

    private static func urls(for entry: Entry) -> [URL] {
        let folder = Storage.previewFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        switch entry {
        case .snippet(let snippet):
            return write(Data(snippet.text.utf8), to: folder.appendingPathComponent("\(snippet.id.uuidString).txt"))
        case .clip(let item):
            let history = History.shared
            let reps = item.pasteboardItems.first ?? []
            func data(_ type: NSPasteboard.PasteboardType) -> Data? {
                reps.first { $0.type == type.rawValue }.flatMap { history.data(item, $0) }
            }
            let base = folder.appendingPathComponent(item.id.uuidString)
            switch item.kind {
            case .files:
                return item.paths.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
            case .image:
                if let png = data(.png) { return write(png, to: base.appendingPathExtension("png")) }
                if let tiff = data(.tiff) { return write(tiff, to: base.appendingPathExtension("tiff")) }
                return []
            case .text:
                // With its formatting when it had some.
                if let rtf = data(.rtf) { return write(rtf, to: base.appendingPathExtension("rtf")) }
                return write(Data(history.fullText(item).utf8), to: base.appendingPathExtension("txt"))
            case .other:
                if let html = data(.html) { return write(html, to: base.appendingPathExtension("html")) }
                if let png = data(.png) { return write(png, to: base.appendingPathExtension("png")) }
                if let pdf = data(.pdf) { return write(pdf, to: base.appendingPathExtension("pdf")) }
                return []
            }
        }
    }

    private static func write(_ data: Data, to url: URL) -> [URL] {
        do {
            try data.write(to: url, options: .atomic)
            return [url]
        } catch {
            return []
        }
    }
}
