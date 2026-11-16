import Foundation
import Observation

/// Text saved to copy whenever it's needed (an address, a sign-off, a bit of code). Snippets
/// live in their own list and never expire.
struct Snippet: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var text: String

    /// The name, or the start of the text when it has none.
    var displayTitle: String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        let line = text.prefix(400).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.isEmpty ? "Blank Snippet" : line
    }

    /// The text on one line, shown after the name.
    var preview: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "" : text.prefix(400).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

@MainActor
@Observable
final class Snippets {
    static let shared = Snippets()

    private(set) var items: [Snippet] = []

    func snippet(_ id: UUID) -> Snippet? { items.first { $0.id == id } }

    func add(title: String, text: String) {
        items.append(Snippet(title: title, text: text))
        save()
    }

    func update(_ id: UUID, title: String, text: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].title = title
        items[index].text = text
        save()
    }

    func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    func move(_ id: UUID, by offset: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard items.indices.contains(target) else { return }
        items.swapAt(index, target)
        save()
    }

    func load() {
        guard let data = Storage.load(Storage.snippetsFile) else { return }
        do {
            items = try JSONDecoder().decode([Snippet].self, from: data)
        } catch {
            log.error("Couldn't read the snippets: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        Storage.save(data, to: Storage.snippetsFile)
    }
}
