import ServiceManagement
import SwiftUI

/// Options, opened in place of the list.
struct OptionsView: View {
    @Bindable private var state = PanelState.shared
    @Bindable private var settings = Settings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    private var history = History.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            OptionRow(symbol: settings.isPaused ? "pause.fill" : "pause", title: "Pause Recording", isOn: settings.isPaused) {
                settings.isPaused.toggle()
            }
            .help("Stop keeping what you copy until you turn this off")
            OptionRow(symbol: "forward", title: "Ignore Next Copy", isOn: settings.ignoreNext) {
                settings.ignoreNext.toggle()
            }
            .help("Don't keep the next thing you copy (then this turns itself off)")
            OptionRow(symbol: "power", title: "Open at Login", isOn: launchAtLogin) { setLaunchAtLogin(!launchAtLogin) }
            HoverRow(action: {}) {
                IconCircle(symbol: "keyboard", isOn: OpenShortcut.shared.display != nil)
                Text("Open Recopy").font(.system(size: 13))
                Spacer(minLength: 0)
                ShortcutField()
            }
            HoverRow(action: {}) {
                IconCircle(symbol: "clock.arrow.circlepath", isOn: false)
                Text("Keep").font(.system(size: 13))
                Spacer(minLength: 0)
                PillPicker(options: Settings.historyLimits.map { ($0, $0.formatted()) }, selection: settings.historyLimit) {
                    settings.historyLimit = $0
                }
            }
            .help("How many copies to keep. Pinned ones don't count and are always kept.")
            HoverRow(action: { state.ignoredOpen.toggle() }) {
                IconCircle(symbol: "hand.raised", isOn: !settings.ignoredApps.isEmpty)
                Text("Ignored Apps").font(.system(size: 13))
                Spacer(minLength: 0)
                Chevron(isOpen: state.ignoredOpen)
            }
            .help("Apps whose copies Recopy doesn't keep. Passwords marked secret are never kept, from any app.")
            if state.ignoredOpen { IgnoredAppsList() }
            HoverRow(action: clear) {
                IconCircle(symbol: "trash", isOn: state.confirmingClear, tint: .red)
                Text(state.confirmingClear ? "Click Again to Clear" : "Clear History")
                    .font(.system(size: 13))
                    .foregroundStyle(state.confirmingClear ? Color.red : Color.primary)
                Spacer(minLength: 0)
                Text(countText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .help("Removes every copy except the pinned ones")
            HoverRow(action: { NSApp.terminate(nil) }) {
                IconCircle(symbol: "xmark", isOn: false)
                Text("Quit Recopy").font(.system(size: 13))
                Spacer(minLength: 0)
            }
        }
    }

    private var countText: String {
        let count = history.recent.count
        return count == 1 ? "1 copy" : "\(count.formatted()) copies"
    }

    private func clear() {
        if state.confirmingClear {
            state.confirmingClear = false
            Actions.clearHistory()
        } else {
            state.confirmingClear = true
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log.error("Couldn't change the login item: \(error.localizedDescription, privacy: .public)")
        }
        if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// The ignored apps (click one to stop ignoring it), plus Choose App… for more.
struct IgnoredAppsList: View {
    private var settings = Settings.shared

    var body: some View {
        VStack(spacing: 2) {
            ForEach(settings.ignoredApps.filter(AppLookup.isInstalled), id: \.self) { id in
                HoverRow(action: { settings.toggleIgnored(id) }) {
                    if let icon = AppLookup.icon(id) {
                        Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                    }
                    Text(AppLookup.name(id)).font(.system(size: 12)).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "minus.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .help("Keep copies from \(AppLookup.name(id)) again")
            }
            HoverRow(action: {
                AppLookup.choose(title: "Ignore Copies from an App", prompt: "Ignore") { ids in
                    for id in ids where !settings.ignoredApps.contains(id) { settings.toggleIgnored(id) }
                }
            }) {
                IconCircle(symbol: "plus", isOn: false, size: 22)
                Text("Choose App…").font(.system(size: 12))
                Spacer(minLength: 0)
            }
        }
        .padding(.leading, 12)
    }
}
