import AppKit

// Checks Recopy's clipboard handling on a private pasteboard (never the real clipboard), with its
// data in a temporary folder: `RecopyTest`. `RecopyTest --read <pasteboard>` is the stand-in for
// another app pasting (a separate process reading a named pasteboard).

if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--read" {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name(CommandLine.arguments[2]))
    print(pasteboard.string(forType: .string) ?? "<nothing>", terminator: "")
    exit(0)
}

let dataFolder = FileManager.default.temporaryDirectory.appendingPathComponent("RecopyTest-\(UUID().uuidString)")
setenv("RECOPY_DATA", dataFolder.path, 1)

MainActor.assumeIsolated { Tests.run() }

@MainActor
enum Tests {
    static var failures = 0
    static let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.mylesdean.Recopy.Test.\(UUID().uuidString)"))
    static let history = History.shared

    static func expect(_ condition: Bool, _ what: String) {
        print(condition ? "  ✓" : "  ✗", what)
        if !condition { failures += 1 }
    }

    static func wait(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    static func copy(_ write: (NSPasteboard) -> Void) {
        pasteboard.clearContents()
        write(pasteboard)
    }

    static func capture() -> Capture? { Capture.read(from: pasteboard, source: nil) }

    /// Another process pastes (reads the clipboard's text), while this one answers its requests.
    static func pasteElsewhere() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--read", pasteboard.name.rawValue]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { wait(0.02) }
        if process.isRunning { process.terminate(); return "<timed out>" }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    static func run() {
        Clipboard.pasteboard = pasteboard
        Settings.shared.historyLimit = 500
        Settings.shared.isPaused = false
        defer {
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: dataFolder)
        }

        print("Text")
        copy { $0.setString("hello", forType: .string) }
        let hello = history.add(capture()!)
        expect(history.items.count == 1 && history.items[0].kind == .text, "plain text is kept")
        copy { $0.setString("world", forType: .string) }
        history.add(capture()!)
        copy { $0.setString("hello", forType: .string) }
        let again = history.add(capture()!)
        expect(again == hello && history.items.count == 2, "copying it again doesn't add another")
        expect(history.items[0].id == hello && history.items[0].copyCount == 2, "…it moves to the top")

        print("Formatting")
        let rtf = NSAttributedString(string: "hello", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)])
            .rtf(from: NSRange(location: 0, length: 5), documentAttributes: [:])!
        copy {
            $0.setString("hello", forType: .string)
            $0.setData(rtf, forType: .rtf)
        }
        expect(history.add(capture()!) == hello, "the same text with formatting is the same item")
        let types = history.items[0].pasteboardItems.first?.map(\.type) ?? []
        expect(types.contains(NSPasteboard.PasteboardType.rtf.rawValue), "…and now keeps its formatting")
        wait(0.2)
        let written = ClipboardWriter.contents(of: history.items[0]).first ?? []
        expect(written.contains { $0.type == .rtf && $0.data == rtf }, "recopying puts the formatting back")

        print("Secrets")
        copy {
            $0.setString("p4ssw0rd", forType: .string)
            $0.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        }
        expect(capture() == nil, "passwords marked concealed are skipped")
        copy {
            $0.setString("one-time", forType: .string)
            $0.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        }
        expect(capture() == nil, "transient copies are skipped")

        print("Files")
        let file = dataFolder.appendingPathComponent("Report.txt")
        try? FileManager.default.createDirectory(at: dataFolder, withIntermediateDirectories: true)
        try? Data("report".utf8).write(to: file)
        let reference = (file as NSURL).fileReferenceURL()! as URL
        copy {
            let item = NSPasteboardItem()
            item.setString(reference.absoluteString, forType: .fileURL)
            item.setString("Report.txt", forType: .string)
            $0.writeObjects([item])
        }
        let fileCapture = capture()!
        expect(fileCapture.kind == .files && fileCapture.paths == [file.standardizedFileURL.path],
               "a copied file is kept as its path (Finder's file reference resolved)")
        expect(fileCapture.items.isEmpty, "…without its contents")
        let fileID = history.add(fileCapture)
        let fileContents = ClipboardWriter.contents(of: history.item(fileID)!)
        expect(fileContents.first?.contains { $0.type == .fileURL } == true, "recopying puts the file back for Finder")
        expect(fileContents.first?.first { $0.type == .string }.map { String(data: $0.data, encoding: .utf8) } == file.standardizedFileURL.path,
               "…and its path as text")
        history.add(fileCapture)
        expect(history.items.filter { $0.kind == .files }.count == 1, "the same file copied again isn't added twice")

        print("Images")
        let image = NSImage(size: NSSize(width: 40, height: 30), flipped: false) { rect in
            NSColor.systemGreen.setFill()
            rect.fill()
            return true
        }
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        copy { $0.setData(png, forType: .png) }
        let imageCapture = capture()!
        expect(imageCapture.kind == .image && imageCapture.thumbnail != nil, "an image is kept, with a thumbnail")
        expect(imageCapture.imageSize.map { $0.width > 0 && $0.height > 0 } == true, "…and its size")

        print("Pins and clearing")
        history.togglePin(hello)
        expect(history.pinned.map(\.id) == [hello], "pinned")
        history.clear()
        expect(history.items.map(\.id) == [hello], "Clear History keeps pinned items")
        for number in 0..<520 { history.addText("copy \(number)") }
        expect(history.recent.count == 500 && history.pinned.count == 1, "only the newest 500 are kept, plus pins")
        Settings.shared.historyLimit = 100
        expect(history.recent.count == 100, "a smaller limit trims at once")

        print("Editing")
        let edited = history.addText("draft")
        history.replaceText(edited, with: "final text")
        wait(0.2)
        let editedItem = history.item(edited)!
        expect(editedItem.text == "final text" && history.fullText(editedItem) == "final text", "an edit replaces the text")
        history.addText("final text")
        expect(history.items.filter { $0.text == "final text" }.count == 1, "…and copying that text later finds the same item")

        print("Saving")
        history.saveNow()
        Storage.flush()
        let saved = (try? JSONDecoder().decode([ClipItem].self, from: Data(contentsOf: Storage.historyFile))) ?? []
        expect(saved.count == history.items.count, "the history is saved")

        print("Watching")
        history.clear()
        let watcher = ClipboardWatcher.shared
        watcher.start()
        copy { $0.setString("seen", forType: .string) }
        wait(0.6)
        expect(history.recent.first?.text == "seen", "a copy is noticed")
        Settings.shared.ignoreNext = true
        copy { $0.setString("skipped once", forType: .string) }
        wait(0.6)
        expect(history.recent.first?.text == "seen" && !Settings.shared.ignoreNext, "Ignore Next Copy skips one copy")
        Settings.shared.isPaused = true
        copy { $0.setString("while paused", forType: .string) }
        wait(0.6)
        expect(history.recent.first?.text == "seen", "nothing is kept while paused")
        Settings.shared.isPaused = false
        ClipboardWriter.write(history.recent.first!)
        wait(0.6)
        expect(history.recent.first?.copyCount == 1, "Recopy's own writes aren't new copies")

        print("Paste stack")
        let stack = PasteStack.shared
        stack.start()
        for word in ["first", "second", "third"] {
            copy { $0.setString(word, forType: .string) }
            wait(0.6)
        }
        expect(stack.items.map(\.text) == ["first", "second", "third"], "copies while it's on join the stack in order")
        expect(pasteElsewhere() == "first", "pasting gives the first")
        wait(0.8)
        expect(pasteElsewhere() == "second", "the next paste gives the second")
        wait(0.8)
        expect(pasteElsewhere() == "third", "then the third")
        wait(0.8)
        expect(!stack.isOn, "the stack turns itself off when it's empty")
        expect(pasteElsewhere() == "third", "and the last one stays on the clipboard")
        expect(history.recent.first(where: { $0.text == "first" }) != nil, "stacked copies are in the history too")

        stack.add(history.recent.first { $0.text == "seen" }!.id)
        stack.add(history.recent.first { $0.text == "first" }!.id)
        stack.stop()
        expect(pasteElsewhere() == "seen", "stopping leaves the next item on the clipboard")

        print(failures == 0 ? "\nAll passed" : "\n\(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
