import AppKit
import SwiftUI

/// A small window for changing a copy's text before copying it again, and for writing snippets.
@MainActor
final class EditorWindow: NSObject, NSWindowDelegate {
    static let shared = EditorWindow()

    enum Mode {
        case item(UUID)
        case newSnippet
        case snippet(UUID)
    }

    private var window: NSWindow?

    func editItem(_ item: ClipItem) {
        open(.item(item.id), title: "Edit Copy", name: "", text: History.shared.fullText(item))
    }

    func newSnippet(text: String = "") {
        open(.newSnippet, title: "New Snippet", name: "", text: text)
    }

    func editSnippet(_ snippet: Snippet) {
        open(.snippet(snippet.id), title: "Edit Snippet", name: snippet.title, text: snippet.text)
    }

    private func open(_ mode: Mode, title: String, name: String, text: String) {
        window?.close()
        let view = EditorView(mode: mode, name: name, text: text, original: text) { [weak self] in self?.window?.close() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.contentView = NSHostingView(rootView: view)
        window.minSize = NSSize(width: 360, height: 220)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.level = .floating
        // On the screen you're working on.
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: visible.midX - 240, y: visible.midY - 100))
        }
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        // Back to the app you were in, ready to paste.
        DispatchQueue.main.async {
            if !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) { NSApp.hide(nil) }
        }
    }
}

private struct EditorView: View {
    let mode: EditorWindow.Mode
    @State var name: String
    @State var text: String
    let original: String
    let close: () -> Void
    @FocusState private var textFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isSnippet {
                TextField("Name (optional)", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            TextEditor(text: $text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.12)))
                .focused($textFocused)
            HStack {
                if case .snippet(let id) = mode {
                    Button("Delete Snippet", role: .destructive) {
                        Snippets.shared.delete(id)
                        close()
                    }
                }
                Spacer()
                Button("Cancel", action: close)
                    .keyboardShortcut(.cancelAction)
                Button(isSnippet ? "Save" : "Copy", action: save)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .help(isSnippet ? "Save the snippet (⌘↩)" : "Copy the text as it is now (⌘↩)")
            }
        }
        .padding(16)
        .frame(minWidth: 360, minHeight: 220)
        .onAppear { textFocused = true }
    }

    private var isSnippet: Bool {
        if case .item = mode { return false }
        return true
    }

    private func save() {
        switch mode {
        case .item(let id):
            // Unchanged text keeps its formatting.
            if text != original { History.shared.replaceText(id, with: text) }
            Actions.copy(id)
        case .newSnippet:
            Snippets.shared.add(title: name, text: text)
        case .snippet(let id):
            Snippets.shared.update(id, title: name, text: text)
        }
        close()
    }
}
