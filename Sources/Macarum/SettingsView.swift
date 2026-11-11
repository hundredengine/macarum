import AppKit
import Carbon.HIToolbox
import MacarumCore
import ServiceManagement
import SwiftUI

enum SystemSettingsLink {
    static let accessibility = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    static let privacy = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!
}

/// Live state the settings screen shows but does not own.
@MainActor @Observable
final class AppStatus {
    var accessibilityGranted = Paster.canPasteDirectly
    var clipboardAccess: NSPasteboard.AccessBehavior = NSPasteboard.general.accessBehavior
    var stats = StoreStats(itemCount: 0, byteSize: 0)
    /// Built from macOS defaults, known app shortcuts and the user's own system shortcuts.
    let shortcutChecker = ShortcutChecker(extraReserved: AppStatus.userSystemShortcuts())

    func refreshPermissions() {
        accessibilityGranted = Paster.canPasteDirectly
        clipboardAccess = NSPasteboard.general.accessBehavior
    }

    /// Enabled shortcuts from System Settings > Keyboard > Keyboard Shortcuts.
    static func userSystemShortcuts() -> [KeyCombo: String] {
        guard let all = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
            .dictionary(forKey: "AppleSymbolicHotKeys") as? [String: [String: Any]] else { return [:] }
        var result: [KeyCombo: String] = [:]
        for entry in all.values {
            guard entry["enabled"] as? Bool == true,
                  let value = entry["value"] as? [String: Any],
                  let parameters = value["parameters"] as? [Int],
                  let combo = ShortcutChecker.comboFromSymbolicHotKey(parameters: parameters) else { continue }
            result[combo] = "a macOS shortcut (System Settings > Keyboard)"
        }
        return result
    }
}

struct SettingsView: View {
    @Bindable var preferences: Preferences
    let status: AppStatus
    let clearHistory: () -> Void

    @State private var confirmClear = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Picker("Open history with", selection: $preferences.openMethod) {
                    Text("⌘ three times").tag(OpenMethod.tripleCommand)
                    Text("Keyboard shortcut").tag(OpenMethod.shortcut)
                }
                if preferences.openMethod == .shortcut {
                    LabeledContent("Shortcut") {
                        ShortcutRecorder(shortcut: $preferences.shortcut, checker: status.shortcutChecker)
                    }
                }
                Toggle("Paste straight into the app in front", isOn: $preferences.pasteDirectly)
                if (preferences.pasteDirectly || preferences.usesTripleCommand) && !status.accessibilityGranted {
                    PermissionRow(
                        text: "Pressing ⌘ three times and pasting for you need Accessibility access. Until then, open the history from the menu bar and paste with ⌘V yourself.",
                        button: "Allow…"
                    ) {
                        Paster.requestAccessibility()
                        NSWorkspace.shared.open(SystemSettingsLink.accessibility)
                    }
                }
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            Section("History") {
                Picker("Keep items for", selection: $preferences.retentionDays) {
                    ForEach(Preferences.retentionChoices, id: \.self) { days in
                        Text(days == 1 ? "1 day" : days == 7 ? "1 week" : days == 14 ? "2 weeks" : "30 days").tag(days)
                    }
                }
                Toggle("Pause history", isOn: $preferences.isPaused)
                LabeledContent("Saved") {
                    Text("\(status.stats.itemCount.formatted()) items\(status.stats.pinnedCount > 0 ? " (\(status.stats.pinnedCount) pinned)" : "") · \(ByteCountFormatter.string(fromByteCount: Int64(status.stats.byteSize), countStyle: .file))")
                        .monospacedDigit()
                }
                HStack {
                    Spacer()
                    Button("Clear History…", role: .destructive) { confirmClear = true }
                        .disabled(status.stats.itemCount == status.stats.pinnedCount)
                }
            }

            Section("Converter") {
                Picker("Save converted files", selection: $preferences.converterSaveLocation) {
                    Text("Next to the original").tag(ConverterSaveLocation.nextToOriginal)
                    Text("In a folder").tag(ConverterSaveLocation.folder)
                }
                if preferences.converterSaveLocation == .folder {
                    LabeledContent("Folder") {
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: preferences.converterFolder.path))
                                .resizable()
                                .frame(width: 16, height: 16)
                            Text(FileManager.default.displayName(atPath: preferences.converterFolder.path))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(preferences.converterFolder.path)
                            Button("Choose…", action: chooseConverterFolder)
                        }
                    }
                }
                Toggle("Copy the result to the clipboard", isOn: $preferences.copyConversionResult)
            }

            Section {
                if status.clipboardAccess != .alwaysAllow {
                    PermissionRow(
                        text: status.clipboardAccess == .alwaysDeny
                            ? "macOS is blocking Macarum from reading the clipboard. Set Macarum to “Always Allow” under Privacy & Security > Paste from Other Apps."
                            : "To stop macOS asking each time, set Macarum to “Always Allow” under Privacy & Security > Paste from Other Apps.",
                        button: "Open Privacy…"
                    ) { NSWorkspace.shared.open(SystemSettingsLink.privacy) }
                }
                Text("Copies from password managers and copies marked private are never saved. History stays on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                IgnoredAppsList(apps: $preferences.ignoredApps)
            } header: {
                Text("Privacy")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Clear all clipboard history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive, action: clearHistory)
        } message: {
            Text("This deletes every saved item except pinned ones. It cannot be undone.")
        }
    }
}

extension SettingsView {
    fileprivate func chooseConverterFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = preferences.converterFolder
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preferences.converterFolder = url
    }
}

private struct PermissionRow: View {
    let text: String
    let button: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(button, action: action)
        }
    }
}

private struct IgnoredAppsList: View {
    @Binding var apps: [IgnoredApp]
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Never save copies from")
            List(selection: $selection) {
                ForEach(apps) { app in
                    HStack(spacing: 8) {
                        if let icon = IconCache.app(app.bundleID) {
                            Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                        }
                        Text(app.name)
                    }
                    .tag(app.bundleID)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(height: 64)
            .overlay {
                if apps.isEmpty {
                    Text("Password managers are always skipped.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 0) {
                Button { addApp() } label: { Image(systemName: "plus").frame(width: 22, height: 18) }
                Button {
                    apps.removeAll { $0.bundleID == selection }
                    selection = nil
                } label: { Image(systemName: "minus").frame(width: 22, height: 18) }
                    .disabled(selection == nil)
            }
            .buttonStyle(.borderless)
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                  !apps.contains(where: { $0.bundleID == id }) else { continue }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            apps.append(IgnoredApp(bundleID: id, name: name))
        }
    }
}

/// Click, then press the new key combination. Esc cancels. Combinations that belong to
/// macOS or another app are refused; risky ones are kept with a note.
private struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    let checker: ShortcutChecker
    @State private var recording = false
    @State private var monitor: Any?
    @State private var message: (text: String, blocked: Bool)?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 4) {
                Button {
                    recording ? stop() : start()
                } label: {
                    Text(recording ? "Type shortcut…" : (shortcut?.display ?? "Click to record"))
                        .monospaced(shortcut != nil && !recording)
                        .frame(minWidth: 96)
                }
            }
            if let message {
                Text(message.text)
                    .font(.caption)
                    .foregroundStyle(message.blocked ? Color.red : Color.orange)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            if let shortcut, case .warning(let text) = checker.check(shortcut.combo) { message = (text, false) }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        message = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let name = Self.keyName(keyCode: keyCode, characters: event.charactersIgnoringModifiers)
            MainActor.assumeIsolated { record(keyCode: keyCode, flags: flags, name: name) }
            return nil
        }
    }

    private func record(keyCode: UInt16, flags: NSEvent.ModifierFlags, name: String) {
        if keyCode == UInt16(kVK_Escape) {
            stop()
            return
        }
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        let candidate = Shortcut(keyCode: UInt32(keyCode), modifiers: carbon, key: name)
        switch checker.check(candidate.combo) {
        case .blocked(let reason):
            message = ("\(candidate.display): \(reason) Try another.", true)
            return // keep listening
        case .warning(let note):
            message = (note, false)
        case .ok:
            message = nil
        }
        shortcut = candidate
        stop()
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }

    nonisolated private static func keyName(keyCode: UInt16, characters: String?) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        default: return (characters ?? "?").uppercased()
        }
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let makeView: () -> AnyView

    init(makeView: @escaping () -> AnyView) {
        self.makeView = makeView
    }

    func show() {
        if window == nil {
            let controller = NSHostingController(rootView: makeView())
            controller.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: controller)
            window.title = "Macarum Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(controller.view.fittingSize)
            self.window = window
        }
        // A menu bar app is not allowed to come to the front on its own; as a regular app
        // for as long as Settings is open, it gets activated and shows up in ⌘Tab.
        NSApp.setActivationPolicy(.regular)
        window?.center()
        // The cooperative NSApp.activate() is refused while another app is in front (checked
        // on macOS 27); the older call still brings Settings forward.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
