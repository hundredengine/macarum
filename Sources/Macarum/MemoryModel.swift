import AppKit
import MacarumCore
import Observation

/// One row of the "holding memory it is not using" list.
struct MemoryRow: Identifiable {
    let usage: AppUsage
    /// Set for apps that can be quit or relaunched (regular apps the person opened).
    let app: NSRunningApplication?
    /// Since when it has used no real CPU, once that is an hour or more.
    var idleSince: Date?
    var id: String { usage.id }
}

/// Memory facts for the menu bar popover. Sampled every two seconds while the popover is
/// open. While it is closed only CPU times are read, every five minutes, so rows can say how
/// long they have been idle.
@MainActor @Observable
final class MemoryModel {
    static let rowCount = 6
    /// `-MacarumPreviewIdle YES` (with `-MacarumPreviewMemory YES`) puts made-up idle labels
    /// on two rows so the label can be looked at without waiting an hour.
    private static let previewsIdleLabels = UserDefaults.standard.bool(forKey: "MacarumPreviewIdle")

    private(set) var pressure: MemoryPressure = SystemMemory.pressure()
    private(set) var swap = SystemMemory.swap()
    private(set) var rows: [MemoryRow] = []
    private(set) var isFreeingCache = false
    /// Apps that were asked to quit and should open again once they are gone.
    private(set) var relaunching: Set<pid_t> = []

    private var timer: Timer?
    private var idleTimer: Timer?
    /// When each process last did real work. Only labels rows; never closes anything.
    private var idle = IdleTracker(watchingSince: Date())
    private var pressureSource: DispatchSourceMemoryPressure?
    /// Called when the pressure level changes, to update the menu bar icon.
    var onPressureChange: (MemoryPressure) -> Void = { _ in }

    init() {
        // macOS pushes level changes, so the menu bar dot costs nothing while idle.
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.refreshPressure() }
        }
        source.resume()
        pressureSource = source

        recordCPU()
        idleTimer = Timer.scheduledTimer(withTimeInterval: IdleTracker.backgroundInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordCPU() }
        }
        idleTimer?.tolerance = 10
    }

    /// The cheap background read: CPU times only, no paths, arguments or memory.
    private func recordCPU() {
        Task.detached(priority: .background) {
            let times = SystemMemory.cpuTimes()
            let now = Date()
            await MainActor.run { [weak self] in self?.idle.record(times, at: now) }
        }
    }

    func startSampling() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = 0.5
    }

    func stopSampling() {
        timer?.invalidate()
        timer = nil
        rows = []
    }

    func refreshPressure() {
        let level = SystemMemory.pressure()
        if level != pressure { pressure = level }
        onPressureChange(level)
    }

    func refresh() {
        swap = SystemMemory.swap()
        refreshPressure()
        Task.detached(priority: .utility) {
            let samples = SystemMemory.processes()
            let now = Date()
            await MainActor.run { [weak self] in
                guard let self else { return }
                idle.record(samples.map(\.cpu), at: now)
                show(SystemMemory.group(samples, idle: idle, now: now))
            }
        }
    }

    private func show(_ groups: [AppUsage]) {
        let me = Bundle.main.bundleURL.standardizedFileURL.path
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let myPID = ProcessInfo.processInfo.processIdentifier
        rows = groups
            .filter { $0.key != me && $0.pid != myPID }
            .prefix(Self.rowCount)
            .map { usage in
                let app = usage.isAppBundle
                    ? apps.first { $0.bundleURL?.standardizedFileURL.path == usage.key }
                    : nil
                return MemoryRow(usage: usage, app: app, idleSince: usage.idleSince)
            }
        if Self.previewsIdleLabels {
            // Screenshots only: no real label can show before Macarum has watched for an hour.
            for (index, hours) in [(0, 3.0), (2, 100.0)] where index < rows.count {
                rows[index].idleSince = Date().addingTimeInterval(-hours * 3600)
            }
        }
    }

    // MARK: Actions

    func quit(_ app: NSRunningApplication) {
        // A normal quit: the app may still ask to save documents first.
        app.terminate()
        Task { try? await Task.sleep(for: .seconds(1)); refresh() }
    }

    /// Stops a program (a dev server, a script) the way Ctrl-C would ask it to.
    func stop(_ pid: pid_t) {
        kill(pid, SIGTERM)
        Task { try? await Task.sleep(for: .seconds(1)); refresh() }
    }

    /// Quits the app and opens it again once it has gone, which hands back the memory and
    /// swap it built up.
    func relaunch(_ app: NSRunningApplication) {
        guard let url = app.bundleURL else { return }
        let pid = app.processIdentifier
        relaunching.insert(pid)
        app.terminate()
        Task {
            // Wait up to 30 s: apps with unsaved work may ask first, and the person may cancel.
            for _ in 0..<60 where !app.isTerminated {
                try? await Task.sleep(for: .milliseconds(500))
            }
            relaunching.remove(pid)
            guard app.isTerminated else { return }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
            refresh()
        }
    }

    /// Runs macOS's `purge`, which drops cached files from memory. It asks for the Mac's
    /// password because macOS only lets administrators run it.
    func freeCachedMemory() {
        guard !isFreeingCache else { return }
        isFreeingCache = true
        // osascript in its own process shows the standard password prompt without blocking
        // Macarum while it is open.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"/usr/sbin/purge\" with administrator privileges"]
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.isFreeingCache = false
                self?.refresh()
            }
        }
        do { try process.run() } catch { isFreeingCache = false }
    }
}
