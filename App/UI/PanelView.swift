import AppKit
import SwiftUI

/// The panel: a search field, History and Snippets, the paste stack while it's on, and Options.
struct PanelView: View {
    @Bindable private var state = PanelState.shared
    private var history = History.shared
    private var snippets = Snippets.shared
    private var stack = PasteStack.shared
    private var watcher = ClipboardWatcher.shared
    private var settings = Settings.shared
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
            tabs
            if watcher.needsPermission { permissionRow }
            if stack.isOn { StackSection() }
            PanelDivider()
            if state.optionsOpen {
                OptionsView()
            } else {
                list
            }
            PanelDivider()
            HoverRow(action: { state.optionsOpen.toggle() }) {
                IconCircle(symbol: "ellipsis", isOn: false)
                Text("Options").font(.system(size: 13))
                Spacer(minLength: 0)
                Chevron(isOpen: state.optionsOpen)
            }
        }
        .padding(.vertical, 10)
        .onAppear { searchFocused = true }
        .onChange(of: state.openings) { searchFocused = true }
    }

    // MARK: Header

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(state.tab == .history ? "Search Copies" : "Search Snippets", text: $state.query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($searchFocused)
            if !state.query.isEmpty {
                Button { state.query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))
        .padding(.horizontal, 12)
    }

    private var tabs: some View {
        HStack(spacing: 8) {
            PillPicker(options: [(PanelTab.history, "History"), (.snippets, "Snippets")], selection: state.tab) { state.tab = $0 }
            Spacer(minLength: 0)
            if settings.isPaused {
                CapsuleButton(symbol: "pause.fill", title: "Paused", isOn: true) { settings.isPaused = false }
                    .help("Recopy isn't keeping what you copy. Click to resume.")
            }
            if state.tab == .history {
                CapsuleButton(symbol: "square.stack.3d.down.right", title: "Paste Stack", isOn: stack.isOn) { stack.toggle() }
                    .help(stack.isOn ? "Stop the paste stack" : "Copy several things, then paste them back one after another in the same order")
            } else {
                CapsuleButton(symbol: "plus", title: "New Snippet") { Actions.newSnippet() }
                    .help("Save text to copy whenever you need it")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var permissionRow: some View {
        HoverRow(action: {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard") {
                Actions.closePanel?()
                NSWorkspace.shared.open(url)
            }
        }) {
            IconCircle(symbol: "exclamationmark.lock", isOn: true, tint: .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Let Recopy See What You Copy").font(.system(size: 13))
                Text("In Paste from Other Apps, set Recopy to Always Allow.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
    }

    // MARK: List

    private var list: some View {
        let entries = state.entries
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if entries.isEmpty {
                        EmptyListView()
                    }
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        EntryRow(entry: entry, index: index, isSelected: index == state.selection)
                            .id(entry.id)
                    }
                }
            }
            .scrollIndicators(.automatic)
            .frame(height: listHeight)
            .onChange(of: state.scrollTarget) { _, target in
                if let target { proxy.scrollTo(target) }
            }
            .onChange(of: state.openings) {
                if let first = entries.first { proxy.scrollTo(first.id, anchor: .top) }
            }
        }
    }

    /// Room for every row up to the screen's limit; it doesn't shrink while searching, so the
    /// panel keeps still as you type.
    private var listHeight: CGFloat {
        let rows = max(history.items.count, snippets.items.count, 4)
        return min(CGFloat(rows) * EntryRow.height, state.maxListHeight)
    }
}

/// What the list says when there's nothing in it.
private struct EmptyListView: View {
    private var state = PanelState.shared
    private var settings = Settings.shared
    private var shortcut = OpenShortcut.shared

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.secondary)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var symbol: String {
        if !state.query.isEmpty { return "magnifyingglass" }
        return state.tab == .history ? "list.clipboard" : "text.quote"
    }

    private var title: String {
        if !state.query.isEmpty { return state.tab == .history ? "No Copies Match" : "No Snippets Match" }
        if state.tab == .snippets { return "No Snippets Yet" }
        return settings.isPaused ? "Recording Is Paused" : "Nothing Copied Yet"
    }

    private var detail: String {
        if !state.query.isEmpty { return "Nothing has “\(state.query)” in it." }
        if state.tab == .snippets { return "Save text you use often with New Snippet, or right-click a copy and choose Save as Snippet." }
        if settings.isPaused { return "Resume recording from Options, or by right-clicking Recopy in the menu bar." }
        if let key = shortcut.display { return "Copy anything and it shows up here. \(key) opens Recopy from anywhere." }
        return "Copy anything and it shows up here."
    }
}

// MARK: Rows

struct EntryRow: View {
    static let height: CGFloat = 28

    let entry: Entry
    let index: Int
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 9) {
            EntryIcon(entry: entry)
                .opacity(isMissing ? 0.45 : 1)
            title
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if case .clip(let item) = entry, item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(secondary)
            }
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isSelected ? Color.accentColor : .clear))
        .contentShape(Rectangle())
        .padding(.horizontal, 8)
        .onHover { if $0 { PanelState.shared.hover(index) } }
        .onTapGesture { Actions.pick(entry) }
        .contextMenu { EntryMenu(entry: entry) }
        .help(tooltip)
    }

    private var primary: Color { isSelected ? .white : .primary }
    private var secondary: Color { isSelected ? .white.opacity(0.75) : .secondary }

    @ViewBuilder private var title: some View {
        switch entry {
        case .clip(let item):
            Text(item.title)
                .font(.system(size: 13))
                .foregroundStyle(isMissing ? secondary : primary)
        case .snippet(let snippet):
            let preview = snippet.preview
            let name = Text(snippet.displayTitle).foregroundStyle(primary)
            let rest = Text(preview.isEmpty ? "" : "  " + preview).foregroundStyle(secondary)
            Text("\(name)\(rest)")
                .font(.system(size: 13))
        }
    }

    /// Files that aren't where they were copied from any more.
    private var isMissing: Bool {
        guard case .clip(let item) = entry, item.kind == .files else { return false }
        return !item.paths.contains(where: FileIcons.exists)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private var tooltip: String {
        switch entry {
        case .clip(let item):
            var lines: [String] = []
            if item.kind == .files {
                lines.append(item.paths.prefix(10).joined(separator: "\n") + (item.paths.count > 10 ? "\n…" : ""))
                if isMissing { lines.append("Not there any more") }
            }
            let when = Self.relative.localizedString(for: item.lastCopied, relativeTo: Date())
            var copied = item.sourceName.map { "Copied from \($0) \(when)" } ?? "Copied \(when)"
            if item.copyCount > 1 { copied += ", \(item.copyCount) times" }
            lines.append(copied)
            return lines.joined(separator: "\n")
        case .snippet(let snippet):
            return String(snippet.text.prefix(600))
        }
    }
}

/// The picture at the start of a row: the image itself, the file's icon, or the app it was
/// copied from.
struct EntryIcon: View {
    let entry: Entry
    var size: CGFloat = 20

    var body: some View {
        switch entry {
        case .clip(let item):
            switch item.kind {
            case .image:
                if let thumbnail = History.shared.thumbnail(item) {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else {
                    glyph("photo")
                }
            case .files:
                Image(nsImage: FileIcons.icon(item.paths.first ?? "/"))
                    .resizable()
                    .frame(width: size, height: size)
            case .text, .other:
                if let id = item.sourceBundleID, let icon = AppLookup.icon(id) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: size, height: size)
                } else {
                    glyph(item.kind == .text ? "text.alignleft" : "doc")
                }
            }
        case .snippet:
            glyph("text.quote")
        }
    }

    private func glyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.6, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
    }
}

/// The right-click menu on a row.
struct EntryMenu: View {
    let entry: Entry
    private var stack = PasteStack.shared

    init(entry: Entry) { self.entry = entry }

    var body: some View {
        switch entry {
        case .clip(let item):
            Button(stack.isOn ? "Add to Paste Stack" : "Copy") { Actions.copy(item.id) }
            if !stack.isOn {
                Button("Add to Paste Stack") { PasteStack.shared.add(item.id) }
            }
            Divider()
            Button(item.isPinned ? "Unpin" : "Pin") { Actions.togglePin(item.id) }
                .keyboardShortcut("p")
            if item.isText {
                Button("Edit…") { Actions.edit(entry) }
                    .keyboardShortcut("e")
                Button("Save as Snippet…") { Actions.saveAsSnippet(item) }
            }
            Button("Quick Look") { QuickLook.shared.show(entry) }
                .keyboardShortcut("y")
            if item.kind == .files {
                Divider()
                Button(item.paths.count == 1 ? "Copy Path" : "Copy Paths") { Actions.copyPaths(item) }
                Button("Show in Finder") { Actions.showInFinder(item) }
            }
            Divider()
            Button("Delete") { Actions.delete(entry) }
                .keyboardShortcut(.delete)
        case .snippet(let snippet):
            Button(stack.isOn ? "Add to Paste Stack" : "Copy") { Actions.pick(entry) }
            Divider()
            Button("Edit…") { Actions.edit(entry) }
                .keyboardShortcut("e")
            Button("Quick Look") { QuickLook.shared.show(entry) }
                .keyboardShortcut("y")
            Button("Move Up") { Snippets.shared.move(snippet.id, by: -1) }
            Button("Move Down") { Snippets.shared.move(snippet.id, by: 1) }
            Divider()
            Button("Delete") { Actions.delete(entry) }
                .keyboardShortcut(.delete)
        }
    }
}

// MARK: Paste stack

/// The stack while it's on: what's left to paste, the next one first.
struct StackSection: View {
    private var stack = PasteStack.shared
    private static let shown = 5

    var body: some View {
        let items = stack.items
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                SectionLabel(items.isEmpty ? "Paste Stack" : "Paste Stack · \(items.count) to Paste")
                Spacer(minLength: 0)
                Button("Stop") { stack.stop() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 16)
            if items.isEmpty {
                Text("Copy things in the order you'll paste them. Each paste moves on to the next.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.top, 2)
            }
            ForEach(Array(items.prefix(Self.shown).enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 9) {
                    Text("\(index + 1)")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(index == 0 ? Color.white : Color.secondary)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(index == 0 ? Color.accentColor : Color.primary.opacity(0.1)))
                    EntryIcon(entry: .clip(item), size: 18)
                    Text(item.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button { stack.remove(at: index) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Take this out of the stack")
                }
                .frame(height: 24)
                .padding(.horizontal, 16)
                .help(index == 0 ? "Pastes next" : "")
            }
            if items.count > Self.shown {
                Text("and \(items.count - Self.shown) more")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 43)
            }
        }
        .padding(.top, 10)
    }
}
