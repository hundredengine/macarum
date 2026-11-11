import Darwin
import Foundation

/// One process across samples. The start time is part of it, so a new process that gets a
/// reused pid starts with no history.
public struct ProcessID: Hashable, Sendable {
    public let pid: pid_t
    public let startedAt: Date?

    public init(pid: pid_t, startedAt: Date?) {
        self.pid = pid
        self.startedAt = startedAt
    }
}

/// How much CPU a process has used since it started: all the tracker needs.
public struct ProcessCPU: Sendable, Equatable {
    public let pid: pid_t
    public let startedAt: Date?
    /// User plus system CPU time, in seconds.
    public let cpuTime: TimeInterval

    public init(pid: pid_t, startedAt: Date?, cpuTime: TimeInterval) {
        self.pid = pid
        self.startedAt = startedAt
        self.cpuTime = cpuTime
    }

    public var id: ProcessID { ProcessID(pid: pid, startedAt: startedAt) }
}

/// Remembers when each process last did real work, so the memory panel can say a row has been
/// idle for hours. It only labels: nothing is ever closed because of it.
///
/// A process counts as active when it uses more than `activityThreshold` of CPU within one
/// window of about five minutes. Below that it is idle. Windows make the rule the same whether
/// the panel samples every 2 s or the background every 5 minutes.
public struct IdleTracker: Sendable {
    /// How long a process must stay idle, and how long Macarum must have watched, before a label.
    public static let minimumIdle: TimeInterval = 3600
    /// CPU a process may use within one window and still count as idle (about 0.7% of one core).
    /// Measured on an Apple silicon Mac (2026-11-07, 30 s samples over 10 minutes): two Expo dev
    /// servers untouched for days used at most 0.61 and 0.81 s per window from their timers, so
    /// 0.5 s would never call them idle; apps in use ran 10 to 35 s per window.
    public static let activityThreshold: TimeInterval = 2
    /// The window CPU use is added up over. A little under the background interval, so each
    /// background sample closes one window even when its timer fires a few seconds early.
    public static let window: TimeInterval = 270
    /// How often the CPU numbers are read while the panel is closed.
    public static let backgroundInterval: TimeInterval = 300

    private struct Entry: Sendable {
        var windowStart: Date
        var windowStartCPU: TimeInterval
        /// The last moment it was seen doing real work, or when it was first seen.
        var lastActive: Date
    }

    /// When Macarum started watching. Nothing is labelled during the first hour.
    public let watchingSince: Date
    private var entries: [ProcessID: Entry] = [:]
    private var lastRecorded = Date.distantPast

    public init(watchingSince: Date) {
        self.watchingSince = watchingSince
    }

    public var trackedCount: Int { entries.count }

    /// Takes a full list of processes read at `now`. Processes missing from it have exited and
    /// are forgotten.
    public mutating func record(_ processes: [ProcessCPU], at now: Date) {
        // Reads finish on other threads; one that arrives after a newer one is dropped.
        guard now >= lastRecorded else { return }
        lastRecorded = now
        var next: [ProcessID: Entry] = [:]
        next.reserveCapacity(processes.count)
        for process in processes where process.startedAt != nil {
            let id = process.id
            guard var entry = entries[id] else {
                // First seen: no history yet, so idle can only be counted from now.
                next[id] = Entry(windowStart: now, windowStartCPU: process.cpuTime, lastActive: now)
                continue
            }
            let used = process.cpuTime - entry.windowStartCPU
            if used > Self.activityThreshold {
                entry.lastActive = now
                entry.windowStart = now
                entry.windowStartCPU = process.cpuTime
            } else if used < 0 || now.timeIntervalSince(entry.windowStart) >= Self.window {
                entry.windowStart = now
                entry.windowStartCPU = process.cpuTime
            }
            next[id] = entry
        }
        entries = next
    }

    /// Since when the process has been idle, only once that is at least an hour and Macarum has
    /// watched at least an hour. Nil means "no label", never "busy" for sure.
    public func idleSince(_ id: ProcessID, now: Date) -> Date? {
        guard now.timeIntervalSince(watchingSince) >= Self.minimumIdle,
              let started = id.startedAt, now.timeIntervalSince(started) >= Self.minimumIdle,
              let entry = entries[id], now.timeIntervalSince(entry.lastActive) >= Self.minimumIdle
        else { return nil }
        return entry.lastActive
    }

    /// An app is idle only when every one of its processes is; it has been idle since the
    /// latest work any of them did.
    public func idleSince(all ids: [ProcessID], now: Date) -> Date? {
        guard !ids.isEmpty else { return nil }
        var latest = Date.distantPast
        for id in ids {
            guard let since = idleSince(id, now: now) else { return nil }
            latest = max(latest, since)
        }
        return latest
    }
}

extension SystemMemory {
    /// CPU time of every process this user may inspect, and nothing else: the cheap read the
    /// background uses while the panel is closed.
    public static func cpuTimes() -> [ProcessCPU] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var result: [ProcessCPU] = []
        result.reserveCapacity(count)
        for pid in pids.prefix(count) where pid > 0 {
            guard let info = rusage(of: pid) else { continue }
            result.append(ProcessCPU(pid: pid, startedAt: startTime(of: pid), cpuTime: cpuSeconds(info)))
        }
        return result
    }

    static func rusage(of pid: pid_t) -> rusage_info_v6? {
        var info = rusage_info_v6()
        let rc = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        return rc == 0 ? info : nil
    }

    /// `ri_user_time` and `ri_system_time` count machine ticks, not nanoseconds: on Apple
    /// silicon one tick is 125/3 ns (checked against `ps` TIME).
    static func cpuSeconds(_ info: rusage_info_v6) -> TimeInterval {
        Double(info.ri_user_time + info.ri_system_time) * nanosecondsPerTick / 1_000_000_000
    }

    private static let nanosecondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return timebase.denom == 0 ? 1 : Double(timebase.numer) / Double(timebase.denom)
    }()
}
