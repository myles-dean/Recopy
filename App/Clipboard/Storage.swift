import AppKit
import OSLog

let log = Logger(subsystem: "com.mylesdean.Recopy", category: "Recopy")

/// The clipboard Recopy watches and writes to: the general one (the test tool swaps in a
/// private one, so testing never touches yours).
@MainActor
enum Clipboard {
    static var pasteboard = NSPasteboard.general
}

/// Where everything is kept: ~/Library/Application Support/Recopy, with history.json (the list),
/// snippets.json, and a folder per item under Items holding what was on the clipboard for it.
/// Files are written on a queue of their own, in order, so reading back always sees the latest.
enum Storage {
    static let root: URL = {
        // The test tool keeps its data elsewhere.
        if let path = ProcessInfo.processInfo.environment["RECOPY_DATA"] { return URL(fileURLWithPath: path, isDirectory: true) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Recopy", isDirectory: true)
    }()

    static let itemsFolder = root.appendingPathComponent("Items", isDirectory: true)
    static let historyFile = root.appendingPathComponent("history.json")
    static let snippetsFile = root.appendingPathComponent("snippets.json")
    /// Files written for Quick Look (text and images that aren't files of their own).
    static let previewFolder: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("com.mylesdean.Recopy/Preview", isDirectory: true)
    }()

    private static let queue = DispatchQueue(label: "com.mylesdean.Recopy.storage", qos: .utility)

    static func folder(_ id: UUID) -> URL {
        itemsFolder.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Writes an item's data, replacing what it had.
    static func replace(_ id: UUID, files: [(name: String, data: Data)]) {
        let folder = folder(id)
        queue.async {
            let manager = FileManager.default
            try? manager.removeItem(at: folder)
            guard !files.isEmpty else { return }
            do {
                try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                for file in files { try file.data.write(to: folder.appendingPathComponent(file.name)) }
            } catch {
                log.error("Couldn't save a copy: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static func read(_ id: UUID, _ name: String) -> Data? {
        let url = folder(id).appendingPathComponent(name)
        return queue.sync { try? Data(contentsOf: url) }
    }

    static func remove(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        queue.async { for id in ids { try? FileManager.default.removeItem(at: folder(id)) } }
    }

    /// Saves a list (history or snippets), atomically.
    static func save(_ data: Data, to url: URL) {
        queue.async {
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                log.error("Couldn't save \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static func load(_ url: URL) -> Data? { queue.sync { try? Data(contentsOf: url) } }

    /// Waits for every write so far (before quitting).
    static func flush() { queue.sync {} }

    /// Item folders the list no longer knows about (left by a crash), removed at launch.
    static func removeStrays(keeping ids: Set<UUID>) {
        queue.async {
            let manager = FileManager.default
            guard let names = try? manager.contentsOfDirectory(atPath: itemsFolder.path) else { return }
            for name in names where UUID(uuidString: name).map({ !ids.contains($0) }) ?? false {
                try? manager.removeItem(at: itemsFolder.appendingPathComponent(name))
            }
            try? manager.removeItem(at: previewFolder)
        }
    }
}
