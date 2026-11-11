import Foundation
import Testing
@testable import MacarumCore

@Suite struct IdleTrackerTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 3600
    private let started = Date(timeIntervalSince1970: 1_700_000_000)

    private func cpu(_ pid: pid_t, _ seconds: TimeInterval, started: Date? = nil) -> ProcessCPU {
        ProcessCPU(pid: pid, startedAt: started ?? self.started, cpuTime: seconds)
    }

    /// Records the same processes every five minutes from `from` to `to`, letting `cpuAt` say
    /// each one's CPU time at that moment.
    private func run(_ tracker: inout IdleTracker, from: TimeInterval, to: TimeInterval,
                     _ cpuAt: (TimeInterval) -> [ProcessCPU]) {
        var t = from
        while t <= to {
            tracker.record(cpuAt(t), at: t0 + t)
            t += IdleTracker.backgroundInterval
        }
    }

    @Test func noLabelBeforeWatchingOneHour() {
        var tracker = IdleTracker(watchingSince: t0)
        run(&tracker, from: 0, to: 55 * 60) { _ in [cpu(10, 5)] }
        #expect(tracker.idleSince(ProcessID(pid: 10, startedAt: started), now: t0 + 55 * 60) == nil)
        run(&tracker, from: 60 * 60, to: 60 * 60) { _ in [cpu(10, 5)] }
        // Seen idle for the whole hour Macarum watched: idle at least since it was first seen.
        #expect(tracker.idleSince(ProcessID(pid: 10, startedAt: started), now: t0 + hour) == t0)
    }

    @Test func processStartedLessThanAnHourAgoGetsNoLabel() {
        let young = t0 + 2 * hour
        var tracker = IdleTracker(watchingSince: t0)
        run(&tracker, from: 2 * hour, to: 2.5 * hour) { _ in [cpu(20, 1, started: young)] }
        #expect(tracker.idleSince(ProcessID(pid: 20, startedAt: young), now: t0 + 2.5 * hour) == nil)
    }

    @Test func timerTicksBelowTheThresholdStayIdle() {
        // 0.8 s of CPU every five minutes, what an untouched Expo dev server used when measured.
        var tracker = IdleTracker(watchingSince: t0)
        run(&tracker, from: 0, to: 3 * hour) { t in [cpu(10, 100 + t / 300 * 0.8)] }
        #expect(tracker.idleSince(ProcessID(pid: 10, startedAt: started), now: t0 + 3 * hour) == t0)
    }

    @Test func workAboveTheThresholdResetsIdle() {
        var tracker = IdleTracker(watchingSince: t0)
        // Idle, then one burst of 10 s of CPU at 1 h, then idle again.
        run(&tracker, from: 0, to: 3 * hour) { t in [cpu(10, t >= hour ? 110 : 100)] }
        let id = ProcessID(pid: 10, startedAt: started)
        #expect(tracker.idleSince(id, now: t0 + 1.5 * hour) == nil)
        #expect(tracker.idleSince(id, now: t0 + 2 * hour) == t0 + hour)
    }

    @Test func smallStepsSampledOftenStillAddUpWithinAWindow() {
        // The panel samples every 2 s: 0.1 s per sample is little each time but 3 s a minute,
        // over the threshold within the window.
        var tracker = IdleTracker(watchingSince: t0)
        var t: TimeInterval = 0
        var used: TimeInterval = 0
        while t <= 60 {
            tracker.record([cpu(10, used)], at: t0 + t)
            t += 2
            used += 0.1
        }
        tracker.record([cpu(10, used)], at: t0 + 2 * hour)
        #expect(tracker.idleSince(ProcessID(pid: 10, startedAt: started), now: t0 + 2 * hour)! > t0)
    }

    @Test func reusedPidDoesNotInheritHistory() {
        var tracker = IdleTracker(watchingSince: t0)
        run(&tracker, from: 0, to: 2 * hour) { _ in [cpu(10, 5)] }
        // pid 10 exits and a new process gets the same number.
        let reborn = t0 + 2 * hour + 10
        tracker.record([cpu(10, 0, started: reborn)], at: t0 + 2 * hour + 60)
        #expect(tracker.idleSince(ProcessID(pid: 10, startedAt: started), now: t0 + 2 * hour + 60) == nil)
        #expect(tracker.idleSince(ProcessID(pid: 10, startedAt: reborn), now: t0 + 2 * hour + 60) == nil)
    }

    @Test func goneProcessesAreForgotten() {
        var tracker = IdleTracker(watchingSince: t0)
        tracker.record([cpu(10, 5), cpu(11, 5)], at: t0)
        tracker.record([cpu(11, 5)], at: t0 + 300)
        #expect(tracker.trackedCount == 1)
    }

    @Test func olderReadArrivingLateIsDropped() {
        var tracker = IdleTracker(watchingSince: t0)
        tracker.record([cpu(10, 5)], at: t0)
        tracker.record([cpu(10, 5)], at: t0 + 2 * hour)
        tracker.record([cpu(10, 9)], at: t0 + hour)
        #expect(tracker.idleSince(ProcessID(pid: 10, startedAt: started), now: t0 + 2 * hour) == t0)
    }

    @Test func processWithoutStartTimeIsNeverIdle() {
        var tracker = IdleTracker(watchingSince: t0)
        run(&tracker, from: 0, to: 2 * hour) { _ in [ProcessCPU(pid: 10, startedAt: nil, cpuTime: 5)] }
        #expect(tracker.idleSince(ProcessID(pid: 10, startedAt: nil), now: t0 + 2 * hour) == nil)
    }

    // MARK: Apps

    private func sample(_ path: String, pid: pid_t, cpu: TimeInterval) -> ProcessSample {
        ProcessSample(pid: pid, path: path, footprint: 1, resident: 0, startedAt: started, cpuTime: cpu)
    }

    @Test func appWithOneBusyHelperIsNotIdle() {
        let main = "/Applications/Code.app/Contents/MacOS/Code"
        let helper = "/Applications/Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper"
        var tracker = IdleTracker(watchingSince: t0)
        run(&tracker, from: 0, to: 2 * hour) { t in
            [sample(main, pid: 1, cpu: 10), sample(helper, pid: 2, cpu: 10 + t / 60)].map(\.cpu)
        }
        let now = t0 + 2 * hour
        let groups = SystemMemory.group([sample(main, pid: 1, cpu: 10), sample(helper, pid: 2, cpu: 130)],
                                        idle: tracker, now: now)
        #expect(groups.count == 1)
        #expect(groups[0].idleSince == nil)
    }

    @Test func appIsIdleSinceItsLatestActivity() {
        let main = "/Applications/Code.app/Contents/MacOS/Code"
        let helper = "/Applications/Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper"
        var tracker = IdleTracker(watchingSince: t0)
        // The helper last worked at 1 h; the main process never did while watched.
        run(&tracker, from: 0, to: 3 * hour) { t in
            [sample(main, pid: 1, cpu: 10), sample(helper, pid: 2, cpu: t >= hour ? 20 : 10)].map(\.cpu)
        }
        let now = t0 + 3 * hour
        let groups = SystemMemory.group([sample(main, pid: 1, cpu: 10), sample(helper, pid: 2, cpu: 20)],
                                        idle: tracker, now: now)
        #expect(groups[0].idleSince == t0 + hour)
        // A program outside an app is judged on its own.
        let node = SystemMemory.group([sample("/opt/homebrew/bin/node", pid: 1, cpu: 10)], idle: tracker, now: now)
        #expect(node[0].idleSince == t0)
    }

    @Test func noTrackerNoLabel() {
        let groups = SystemMemory.group([sample("/opt/homebrew/bin/node", pid: 1, cpu: 10)])
        #expect(groups[0].idleSince == nil)
    }

    @Test func readsCPUTimeOfThisMac() throws {
        let me = try #require(SystemMemory.cpuTimes().first { $0.pid == ProcessInfo.processInfo.processIdentifier })
        #expect(me.cpuTime > 0)
        #expect(me.startedAt != nil)
        // Same numbers as the full sample, converted from machine ticks to seconds.
        let full = try #require(SystemMemory.processes().first { $0.pid == me.pid })
        #expect(full.cpuTime >= me.cpuTime)
        #expect(full.cpuTime - me.cpuTime < 5)
    }
}
