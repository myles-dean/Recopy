import AppKit
import Observation

/// Recopy's options, kept in UserDefaults.
@MainActor
@Observable
final class Settings {
    static let shared = Settings()

    static let historyLimits = [100, 500, 1000, 5000]

    /// How many copies to keep (pinned ones don't count).
    var historyLimit: Int {
        didSet {
            defaults.set(historyLimit, forKey: Keys.historyLimit)
            History.shared.trim()
        }
    }

    /// Apps whose copies aren't kept, by bundle ID.
    var ignoredApps: [String] {
        didSet { defaults.set(ignoredApps, forKey: Keys.ignoredApps) }
    }

    /// Nothing copied is kept while paused.
    var isPaused: Bool {
        didSet { defaults.set(isPaused, forKey: Keys.paused) }
    }

    /// The next copy isn't kept (then this turns itself off).
    var ignoreNext = false

    @ObservationIgnored private let defaults = UserDefaults.standard

    private enum Keys {
        static let historyLimit = "historyLimit"
        static let ignoredApps = "ignoredApps"
        static let paused = "paused"
    }

    /// Password apps, to start with. Most mark what they copy as secret anyway (Recopy skips
    /// those), but not every one, and not from every place (some browser extensions don't).
    private static let defaultIgnoredApps = [
        "com.apple.Passwords",
        "com.apple.keychainaccess",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
    ]

    private init() {
        let limit = defaults.integer(forKey: Keys.historyLimit)
        historyLimit = Self.historyLimits.contains(limit) ? limit : 500
        ignoredApps = defaults.stringArray(forKey: Keys.ignoredApps) ?? Self.defaultIgnoredApps
        isPaused = defaults.bool(forKey: Keys.paused)
    }

    func toggleIgnored(_ id: String) {
        if let index = ignoredApps.firstIndex(of: id) { ignoredApps.remove(at: index) } else { ignoredApps.append(id) }
    }
}

/// Names and icons of apps by bundle ID, running or not.
@MainActor
enum AppLookup {
    private static var icons: [String: NSImage] = [:]
    private static var names: [String: String] = [:]

    static func name(_ id: String) -> String {
        if let name = names[id] { return name }
        var name = id
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first, let running = app.localizedName {
            name = running
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        names[id] = name
        return name
    }

    static func icon(_ id: String) -> NSImage? {
        if let icon = icons[id] { return icon }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[id] = icon
        return icon
    }

    static func isInstalled(_ id: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
    }

    /// Finder's open panel, in Applications, for picking apps; calls back with their bundle IDs.
    static func choose(title: String, prompt: String, _ picked: @escaping @MainActor ([String]) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        NSApp.activate()
        panel.begin { response in
            guard response == .OK else { return }
            let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
            MainActor.assumeIsolated { picked(ids) }
        }
    }
}
