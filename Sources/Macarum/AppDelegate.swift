import AppKit
import MacarumCore
import Observation
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = Preferences.shared
    private let status = AppStatus()
    private var store: ClipStore!
    private var model: HistoryModel!
    private var panel: HistoryPanelController!
    private var settings: SettingsWindowController!
    private var welcome: WelcomeWindowController!
    private let monitor = ClipboardMonitor()
    private var hotKey: HotKey!
    private var commandTaps: CommandTapMonitor!
    private var statusItem: NSStatusItem!
    private let memory = MemoryModel()
    private lazy var converter = ConverterModel(preferences: preferences)
    private var statusDrop: StatusItemDropTarget?
    private var memoryPanel: MemoryPanelController!
    private var maintenanceTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if UserDefaults.standard.bool(forKey: "MacarumPreviewWelcome") { return startWelcomePreview() }
        if UserDefaults.standard.bool(forKey: "MacarumPreviewConverter") { return startConverterPreview() }
        do {
            store = try ClipStore(directory: Self.storeDirectory)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Macarum could not open its history"
            alert.informativeText = String(describing: error)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        model = HistoryModel(store: store)
        model.onChoose = { [weak self] item, mode in self?.choose(item, mode) }

        panel = HistoryPanelController(model: model, preferences: preferences) { [weak self] in
            self?.status.clipboardAccess == .alwaysDeny
        }
        settings = SettingsWindowController { [unowned self] in
            AnyView(SettingsView(preferences: preferences, status: status,
                                 clearHistory: { [weak self] in self?.clearHistory() },
                                 showWelcome: { [weak self] in self?.welcome.show() }))
        }
        welcome = WelcomeWindowController(
            icon: NSApp.applicationIconImage,
            isGranted: { Paster.canPasteDirectly },
            requestAccess: {
                Paster.requestAccessibility()
                NSWorkspace.shared.open(SystemSettingsLink.accessibility)
            },
            openSystemSettings: { NSWorkspace.shared.open(SystemSettingsLink.accessibility) },
            permissionChanged: { [weak self] in self?.status.refreshPermissions() })
        panel.openSettings = { [weak self] in self?.showSettings() }

        hotKey = HotKey { [weak self] in self?.panel.toggle() }
        commandTaps = CommandTapMonitor { [weak self] in self?.panel.toggle() }
        applyOpenTriggers()

        monitor.rules = { [preferences] in CaptureRules(ignoredBundleIDs: Set(preferences.ignoredApps.map(\.bundleID))) }
        monitor.isPaused = { [preferences] in preferences.isPaused }
        monitor.onCapture = { [weak self] snapshot, source in self?.save(snapshot, source) }
        monitor.start()

        NSApp.mainMenu = MainMenu.make(settingsTarget: self, settingsAction: #selector(showSettings))
        setUpStatusItem()
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        observePreferences()
        runMaintenance(launch: true)
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runMaintenance(launch: false) }
        }
        maintenanceTimer?.tolerance = 600
        if UserDefaults.standard.bool(forKey: "MacarumPreviewMemory") { previewMemoryWindow() } else { welcomeOnFirstLaunch() }
    }

    /// The first launch explains Macarum before macOS asks for anything: the Accessibility
    /// prompt only comes up from the button in the welcome window.
    private func welcomeOnFirstLaunch() {
        guard WelcomeGate.shouldShow(welcomed: preferences.welcomed,
                                     askedAccessibility: preferences.askedAccessibility) else { return }
        preferences.welcomed = true
        welcome.show()
    }

    /// For screenshots while the real Macarum keeps running: `-MacarumPreviewWelcome YES` shows
    /// only the welcome window (no status item, no clipboard monitor, no history store, no
    /// shortcuts) and never asks macOS for anything; its buttons only change what it shows.
    /// `-MacarumPreviewWelcomeWaiting YES` starts after the button was pressed,
    /// `-MacarumPreviewWelcomeGranted YES` with the permission there,
    /// `-MacarumPreviewWelcomeGrantAfter 3` lets it arrive after that many seconds, and
    /// `-MacarumPreviewIcon <path>` gives the app icon, which a bare binary does not have.
    private func startWelcomePreview() {
        let defaults = UserDefaults.standard
        let granted = defaults.bool(forKey: "MacarumPreviewWelcomeGranted")
        let grantAfter = defaults.double(forKey: "MacarumPreviewWelcomeGrantAfter")
        let grantAt = Date().addingTimeInterval(grantAfter)
        let icon = defaults.string(forKey: "MacarumPreviewIcon").flatMap(NSImage.init(contentsOfFile:))
        welcome = WelcomeWindowController(
            icon: icon ?? NSApp.applicationIconImage,
            isGranted: { granted || (grantAfter > 0 && Date() >= grantAt) },
            requestAccess: { print("preview: would ask macOS for Accessibility") },
            openSystemSettings: { print("preview: would open System Settings") })
        welcome.show(waiting: defaults.bool(forKey: "MacarumPreviewWelcomeWaiting"))
        print("preview: window \(welcome.windowNumber ?? 0)")
        fflush(stdout)
    }

    /// For screenshots: `-MacarumPreviewMemory YES` shows the menu bar popover's content in a
    /// plain window, since the status item may sit behind the notch or a menu bar hider.
    private var previewWindow: NSWindow?
    private func previewMemoryWindow() {
        let window = NSWindow(contentViewController: NSHostingController(rootView: MemoryView(
            model: memory, converter: converter, preferences: preferences, showHistory: {}, showSettings: {})))
        window.title = "Macarum Memory"
        window.styleMask = [.titled]
        memory.startSampling()
        window.center()
        window.orderFrontRegardless()
        previewWindow = window
    }

    static var storeDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Macarum", isDirectory: true)
    }

    // MARK: Capture and paste

    private func save(_ snapshot: ClipSnapshot, _ source: SourceApp?) {
        let store = store!
        Task {
            _ = try? await store.insert(snapshot, source: source)
            if panel.isVisible { await model.reload() }
        }
    }

    private func choose(_ item: ClipItem, _ mode: PasteMode) {
        let store = store!
        Task {
            guard let snapshot = try? await store.snapshot(for: item.id), !snapshot.items.isEmpty else { return }
            Paster.write(snapshot, plainTextOnly: mode == .pastePlainText)
            monitor.skipCurrent()
            try? await store.markUsed(item.id)
            panel.hide()
            guard mode != .copy, preferences.pasteDirectly else { return }
            if Paster.canPasteDirectly {
                // Give the app underneath a moment to take the keyboard back from the panel.
                try? await Task.sleep(for: .milliseconds(60))
                Paster.sendPasteKeystroke()
            } else {
                Paster.requestAccessibility()
            }
        }
    }

    private func clearHistory() {
        let store = store!
        Task {
            try? await store.deleteAll()
            await refreshStats()
        }
    }

    private func runMaintenance(launch: Bool) {
        let store = store!
        let days = preferences.retentionDays
        Task {
            let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
            _ = try? await store.purge(lastCopiedBefore: cutoff)
            _ = try? await store.enforceSizeLimit(Preferences.maxStoreBytes)
            if launch { _ = try? await store.removeOrphanBlobs() }
            await refreshStats()
        }
    }

    private func refreshStats() async {
        if let stats = try? await store.stats() { status.stats = stats }
    }

    // MARK: Preferences

    private func applyOpenTriggers() {
        if let shortcut = preferences.activeShortcut { hotKey.register(shortcut) } else { hotKey.unregister() }
        if preferences.usesTripleCommand { commandTaps.start() } else { commandTaps.stop() }
    }

    /// Re-registers the shortcut and re-runs retention whenever those settings change.
    private func observePreferences() {
        withObservationTracking {
            _ = preferences.shortcut
            _ = preferences.openMethod
            _ = preferences.retentionDays
            _ = preferences.isPaused
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applyOpenTriggers()
                self.runMaintenance(launch: false)
                self.updatePausedLook()
                self.observePreferences()
            }
        }
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = MenuBarIcon.image
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggleMemoryPopover)

        memory.onPressureChange = { [weak self] level in self?.updateIcon(pressure: level) }
        memoryPanel = MemoryPanelController(content: AnyView(MemoryView(
            model: memory, converter: converter, preferences: preferences,
            showHistory: { [weak self] in
                self?.memoryPanel.close()
                self?.showPanel()
            },
            showSettings: { [weak self] in
                self?.memoryPanel.close()
                self?.showSettings()
            })))
        memoryPanel.onClose = { [weak self] in self?.memory.stopSampling() }
        wireConverter(to: memoryPanel)
        converter.copyResults = { [weak self] urls in self?.copyConverted(urls) }
        if let window = statusItem.button?.window {
            statusDrop = StatusItemDropTarget(window: window,
                                              onEnter: { [weak self] in self?.openMemoryPanel() },
                                              onDrop: { [weak self] urls in
                                                  self?.converter.noteDrop()
                                                  self?.openMemoryPanel()
                                                  self?.converter.pick(urls)
                                              })
        }
        updateIcon(pressure: memory.pressure)
        updatePausedLook()
    }

    /// The parts of the converter that need the panel: choosing files keeps it open, and a
    /// drag that reaches it keeps it open after the button comes up.
    private func wireConverter(to panel: MemoryPanelController) {
        let converter = converter
        panel.dragsReached = { converter.dragsEntered }
        converter.presentOpenPanel = { [weak panel] completion in
            guard let panel else { return }
            let urls: [URL] = panel.keepOpen {
                let open = NSOpenPanel()
                open.allowsMultipleSelection = true
                open.canChooseDirectories = false
                open.prompt = "Choose"
                open.message = "Choose files to convert"
                // The menu panel floats at menu level; the open panel has to sit above it.
                open.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
                NSApp.activate(ignoringOtherApps: true)
                return open.runModal() == .OK ? open.urls : []
            }
            if !urls.isEmpty { completion(urls) }
        }
    }

    /// Puts converted files on the clipboard and adds them to the history once, as coming from
    /// Macarum; the monitor skips this change so it is not saved a second time.
    private func copyConverted(_ urls: [URL]) {
        let snapshot = CaptureRules().trim(ConversionClipboard.snapshot(for: urls))
        guard !snapshot.items.isEmpty else { return }
        Paster.write(snapshot, plainTextOnly: false, marked: false)
        monitor.skipCurrent()
        guard !preferences.isPaused else { return }
        let store = store!
        let source = SourceApp(bundleID: Bundle.main.bundleIdentifier ?? "id.hundredengine.macarum", name: "Macarum")
        Task {
            _ = try? await store.insert(snapshot, source: source)
            if panel.isVisible { await model.reload() }
        }
    }

    /// Finder's right-click "Convert with Macarum" (`NSServices` in the Info.plist): the files
    /// land in the converter and the panel opens, ready to pick an output.
    @objc func convertFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        converter.pick(urls)
        openMemoryPanel()
    }

    @objc private func toggleMemoryPopover() {
        if memoryPanel.isShown {
            memoryPanel.close()
            return
        }
        openMemoryPanel()
    }

    private func openMemoryPanel() {
        guard !memoryPanel.isShown else { return }
        status.refreshPermissions()
        memory.startSampling()
        let anchor = statusItem.button.flatMap { button in
            button.window.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) }
        }
        memoryPanel.show(below: anchor)
    }

    // MARK: Converter preview

    /// For screenshots and drag tests while the real Macarum keeps running:
    /// `-MacarumPreviewConverter YES` opens only the menu bar panel (no status item, no
    /// clipboard monitor, no history store, no shortcuts), under the top right of the screen.
    /// `-MacarumPreviewFiles a,b` picks files, `-MacarumPreviewChoose JPG` picks that offer (`-MacarumPreviewRun YES` also runs it),
    /// `-MacarumPreviewSettings YES` opens Settings as well. Copy changes nothing here.
    private func startConverterPreview() {
        let defaults = UserDefaults.standard
        let panel = MemoryPanelController(content: AnyView(MemoryView(
            model: memory, converter: converter, preferences: preferences, showHistory: {}, showSettings: {})))
        memoryPanel = panel
        wireConverter(to: panel)
        panel.onClose = {
            print("preview: panel closed")
            fflush(stdout)
        }
        memory.startSampling()
        if let screen = NSScreen.main {
            let anchor = NSRect(x: screen.visibleFrame.maxX - 300, y: screen.frame.maxY - 24, width: 24, height: 24)
            panel.show(below: anchor)
        }
        if let files = defaults.string(forKey: "MacarumPreviewFiles") {
            converter.pick(files.split(separator: ",").map { URL(fileURLWithPath: String($0)) })
            if let title = defaults.string(forKey: "MacarumPreviewChoose"),
               let offer = converter.offers.first(where: { $0.title == title }) {
                converter.choose(offer)
                if defaults.bool(forKey: "MacarumPreviewRun") { converter.runChosen() }
            }
        }
        if defaults.bool(forKey: "MacarumPreviewSettings") {
            settings = SettingsWindowController { [unowned self] in
                AnyView(SettingsView(preferences: preferences, status: status, clearHistory: {}, showWelcome: {}))
            }
            settings.show()
        }
    }

    private func updateIcon(pressure: MemoryPressure) {
        let image = pressure > .normal ? MenuBarIcon.imageWithDot : MenuBarIcon.image
        if statusItem?.button?.image !== image { statusItem?.button?.image = image }
    }

    private func updatePausedLook() {
        statusItem?.button?.appearsDisabled = preferences.isPaused
    }

    @objc private func showPanel() {
        // Let the memory panel finish closing first, or the panel loses key status straight away.
        DispatchQueue.main.async { [weak self] in self?.panel.show() }
    }

    @objc private func togglePause() {
        preferences.isPaused.toggle()
    }

    @objc private func showSettings() {
        status.refreshPermissions()
        Task { await refreshStats() }
        settings.show()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        status.refreshPermissions()
    }
}
