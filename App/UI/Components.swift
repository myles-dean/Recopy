import AppKit
import SwiftUI

/// Building blocks laid out like Control Center's menus (the same ones as Soundcheck's).

struct PanelDivider: View {
    var body: some View {
        Divider().padding(.horizontal, 16).padding(.vertical, 6)
    }
}

struct SectionLabel: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

/// A glyph in a circle: blue when it's on.
struct IconCircle: View {
    let symbol: String
    let isOn: Bool
    var size: CGFloat = 28
    var tint: Color = .accentColor

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .frame(width: size, height: size)
            .background(Circle().fill(isOn ? tint : Color.primary.opacity(0.1)))
    }
}

/// A full-width row that highlights under the pointer, like a menu item.
struct HoverRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) { content }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: 9).fill(hovering ? Color.primary.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, 8)
    }
}

/// A setting that's on or off: its glyph's circle turns blue when it's on.
struct OptionRow: View {
    let symbol: String
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        HoverRow(action: action) {
            IconCircle(symbol: symbol, isOn: isOn)
            Text(title).font(.system(size: 13))
            Spacer(minLength: 0)
        }
        .animation(.easeOut(duration: 0.12), value: isOn)
    }
}

/// A row of choices in one pill (round outer ends, flat joins).
struct PillPicker<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    let selection: Value
    let onSelect: (Value) -> Void

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let isOn = option.value == selection
                let outer: CGFloat = 11
                let shape = UnevenRoundedRectangle(topLeadingRadius: index == 0 ? outer : 0,
                                                   bottomLeadingRadius: index == 0 ? outer : 0,
                                                   bottomTrailingRadius: index == options.count - 1 ? outer : 0,
                                                   topTrailingRadius: index == options.count - 1 ? outer : 0,
                                                   style: .continuous)
                Button { onSelect(option.value) } label: {
                    Text(option.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isOn ? Color.white : Color.primary)
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(shape.fill(isOn ? Color.accentColor : Color.primary.opacity(0.1)))
                        .contentShape(shape)
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.easeOut(duration: 0.12), value: selection)
    }
}

/// A small capsule button, blue while it's on.
struct CapsuleButton: View {
    let symbol: String
    let title: String
    var isOn = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(isOn ? Color.accentColor : Color.primary.opacity(0.1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: isOn)
    }
}

/// A dropdown's chevron, turned up while it's open.
struct Chevron: View {
    let isOpen: Bool

    var body: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isOpen ? 180 : 0))
    }
}

/// The open-Recopy shortcut: click, then type it (Delete clears it, Escape cancels).
struct ShortcutField: View {
    private var shortcut = OpenShortcut.shared
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: toggle) {
            Text(recording ? "Type Shortcut…" : (shortcut.display ?? "Set Shortcut"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(recording ? Color.white : Color.primary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(recording ? Color.accentColor : Color.primary.opacity(0.1)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("The keyboard shortcut that opens Recopy from anywhere")
        .onDisappear(perform: stop)
    }

    private func toggle() {
        if recording { stop(); return }
        recording = true
        PanelState.shared.recordingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case 53: stop() // Escape
            case 51, 117: // Delete
                shortcut.clear()
                stop()
            default:
                if shortcut.record(event) { stop() }
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        PanelState.shared.recordingShortcut = false
    }
}

/// Icons of copied files (and whether they're still there), looked up once per opening.
@MainActor
enum FileIcons {
    private static var icons: [String: NSImage] = [:]
    private static var existing: [String: Bool] = [:]

    static func icon(_ path: String) -> NSImage {
        if let icon = icons[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[path] = icon
        return icon
    }

    static func exists(_ path: String) -> Bool {
        if let known = existing[path] { return known }
        let exists = FileManager.default.fileExists(atPath: path)
        existing[path] = exists
        return exists
    }

    /// Files may have moved since the panel was last open.
    static func reset() {
        existing = [:]
        if icons.count > 500 { icons = [:] }
    }
}
