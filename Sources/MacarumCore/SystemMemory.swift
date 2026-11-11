import Darwin
import Foundation

/// How hard macOS is working to find memory, as Activity Monitor's pressure graph shows it.
public enum MemoryPressure: Int, Sendable, Comparable {
    case normal, warning, critical

    /// From `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
    public init(kernelLevel: Int) {
        self = kernelLevel >= 4 ? .critical : kernelLevel >= 2 ? .warning : .normal
    }

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// One process and its memory.
public struct ProcessSample: Sendable, Equatable {
    public let pid: pid_t
    public let path: String
    /// Command line words after the executable, used to tell programs apart (which project a
    /// dev server runs for). Empty when macOS does not hand them out.
    public let arguments: [String]
    /// What the process holds in total: Activity Monitor's "Memory".
    public let footprint: UInt64
    /// The part of it that sits in RAM right now.
    public let resident: UInt64
    public let startedAt: Date?
    /// User plus system CPU time since it started, in seconds.
    public let cpuTime: TimeInterval

    public init(pid: pid_t, path: String, arguments: [String] = [], footprint: UInt64, resident: UInt64,
                startedAt: Date? = nil, cpuTime: TimeInterval = 0) {
        self.pid = pid
        self.path = path
        self.arguments = arguments
        self.footprint = footprint
        self.resident = resident
        self.startedAt = startedAt
        self.cpuTime = cpuTime
    }

    public var cpu: ProcessCPU { ProcessCPU(pid: pid, startedAt: startedAt, cpuTime: cpuTime) }

    /// Memory the process holds but macOS moved out of RAM (compressed or written to swap)
    /// because it was not being used. This is what fills swap.
    public var outOfRAM: UInt64 { footprint > resident ? footprint - resident : 0 }
}

/// Memory of one app with all its helper processes, or of one program (a dev server, a script).
public struct AppUsage: Sendable, Equatable, Identifiable {
    public var id: String { key }
    /// The app bundle path (`/Applications/Google Chrome.app`), or `pid:<n>` for a program.
    public let key: String
    public let name: String
    /// For programs: what it runs, e.g. "expo start · shop".
    public let detail: String?
    public let isAppBundle: Bool
    public let bytes: UInt64
    public let outOfRAM: UInt64
    public let processCount: Int
    /// For a program: its process, so it can be stopped. Nil for apps.
    public let pid: pid_t?
    public let startedAt: Date?
    /// Set when every process of it has used no real CPU for at least an hour (see IdleTracker).
    public let idleSince: Date?
}

public struct SwapUsage: Sendable, Equatable {
    public let used: UInt64
    public let total: UInt64
}

/// Reads memory facts any user can read; nothing here needs admin rights.
public enum SystemMemory {
    public static func swap() -> SwapUsage {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return SwapUsage(used: 0, total: 0) }
        return SwapUsage(used: usage.xsu_used, total: usage.xsu_total)
    }

    public static func pressure() -> MemoryPressure {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        return MemoryPressure(kernelLevel: Int(level))
    }

    public static var physicalMemory: UInt64 { ProcessInfo.processInfo.physicalMemory }

    /// Every process this user may inspect. Processes of other users (root, system daemons)
    /// are refused by macOS and simply left out.
    public static func processes() -> [ProcessSample] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var samples: [ProcessSample] = []
        samples.reserveCapacity(count)
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        for pid in pids.prefix(count) where pid > 0 {
            guard let info = rusage(of: pid) else { continue }
            let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            guard length > 0 else { continue }
            let path = String(decoding: pathBuffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            // Arguments only matter for programs outside an app; skip the extra call for app helpers.
            let arguments = path.contains(".app/") ? [] : Self.arguments(of: pid)
            samples.append(ProcessSample(pid: pid, path: path, arguments: arguments,
                                         footprint: info.ri_phys_footprint, resident: info.ri_resident_size,
                                         startedAt: startTime(of: pid), cpuTime: cpuSeconds(info)))
        }
        return samples
    }

    /// Apps with all their helper processes add up to one entry: everything inside `X.app`
    /// counts as X (Chrome's tabs, Code's extensions). Chrome also runs a copy of itself from a
    /// temporary `Google Chrome.app.bundle`, folded into the same name. Programs outside an app
    /// stay one entry per process, so two dev servers do not hide inside one "node".
    /// Sorted by what they hold out of RAM, which is what fills swap. With a tracker, each entry
    /// says since when it has been idle (an app only when all its processes are).
    public static func group(_ samples: [ProcessSample], idle tracker: IdleTracker? = nil,
                             now: Date = Date()) -> [AppUsage] {
        struct Bucket {
            var bytes: UInt64 = 0; var out: UInt64 = 0; var count = 0; var key = ""; var started: Date?
            var ids: [ProcessID] = []
        }
        var apps: [String: Bucket] = [:]
        var programs: [AppUsage] = []
        for sample in samples {
            guard let (bundle, name) = appBundle(of: sample.path) else {
                let name = (sample.path as NSString).lastPathComponent
                programs.append(AppUsage(key: "pid:\(sample.pid)", name: name, detail: describe(sample.arguments),
                                         isAppBundle: false, bytes: sample.footprint, outOfRAM: sample.outOfRAM,
                                         processCount: 1, pid: sample.pid, startedAt: sample.startedAt,
                                         idleSince: tracker?.idleSince(sample.cpu.id, now: now)))
                continue
            }
            var bucket = apps[name] ?? Bucket()
            bucket.bytes += sample.footprint
            bucket.out += sample.outOfRAM
            bucket.count += 1
            bucket.ids.append(sample.cpu.id)
            // Prefer the real install location over a temporary copy as the key.
            if bucket.key.isEmpty || !bundle.hasSuffix(".app.bundle") { bucket.key = bundle }
            if let started = sample.startedAt, bucket.started.map({ started < $0 }) ?? true { bucket.started = started }
            apps[name] = bucket
        }
        let appUsages = apps.map {
            AppUsage(key: $0.value.key, name: $0.key, detail: nil, isAppBundle: !$0.value.key.hasSuffix(".app.bundle"),
                     bytes: $0.value.bytes, outOfRAM: $0.value.out, processCount: $0.value.count, pid: nil,
                     startedAt: $0.value.started, idleSince: tracker?.idleSince(all: $0.value.ids, now: now))
        }
        return (appUsages + programs).sorted {
            $0.outOfRAM == $1.outOfRAM ? $0.name < $1.name : $0.outOfRAM > $1.outOfRAM
        }
    }

    /// The outermost bundle a path lives in: helpers sit in X.app/Contents/Frameworks/…/Y.app.
    static func appBundle(of path: String) -> (bundle: String, name: String)? {
        for marker in [".app/", ".app.bundle/"] {
            if let range = path.range(of: marker) {
                let bundle = String(path[..<range.lowerBound]) + marker.dropLast()
                let folder = (bundle as NSString).lastPathComponent
                let name = folder.replacingOccurrences(of: ".app.bundle", with: "").replacingOccurrences(of: ".app", with: "")
                return (bundle, name)
            }
        }
        return nil
    }

    /// A short line saying what a program runs, from its arguments: the script or tool, its
    /// first word of command, and the project folder it belongs to.
    /// `node …/shop/node_modules/.bin/expo start --port 8081` → "expo start · shop".
    static func describe(_ arguments: [String]) -> String? {
        guard let script = arguments.first(where: { !$0.hasPrefix("-") }) else { return nil }
        var tool = (script as NSString).lastPathComponent
        if ["index.js", "main.js", "cli.js", "server.js"].contains(tool) {
            // Name the package instead of a generic file name: …/node_modules/openclaw/dist/index.js.
            let parts = script.split(separator: "/")
            if let i = parts.lastIndex(of: "node_modules"), i + 1 < parts.count { tool = String(parts[i + 1]) }
        }
        let rest = arguments.drop { $0 != script }.dropFirst()
        if let command = rest.first, !command.hasPrefix("-"), !command.contains("/"), command.count <= 20 {
            tool += " " + command
        }
        if let project = projectFolder(in: script) { return tool + " · " + project }
        return tool
    }

    /// The folder right above `node_modules`, `.venv` or a `bin` folder, when the script lives in a project.
    static func projectFolder(in path: String) -> String? {
        // Global installs (npx cache, Homebrew's lib) have no project.
        if ["/_npx/", "/.npm/", "/lib/node_modules/"].contains(where: path.contains) { return nil }
        let parts = path.split(separator: "/").map(String.init)
        for marker in ["node_modules", ".venv", "venv", "vendor"] {
            if let i = parts.firstIndex(of: marker), i > 0 {
                let folder = parts[i - 1]
                return folder.hasPrefix(".") || folder.count > 40 ? nil : folder
            }
        }
        return nil
    }

    /// The command line of a process of this user (KERN_PROCARGS2), without the executable.
    static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        // Layout: argc, executable path, padding zeros, then argc zero-terminated words.
        var words: [String] = []
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 } // executable path
        while index < size, buffer[index] == 0 { index += 1 } // padding
        var start = index
        while index < size, words.count < Int(argc) {
            if buffer[index] == 0 {
                words.append(String(decoding: buffer[start..<index], as: UTF8.self))
                start = index + 1
            }
            index += 1
        }
        return Array(words.dropFirst()) // argv[0] is the program itself
    }

    static func startTime(of pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }
}
