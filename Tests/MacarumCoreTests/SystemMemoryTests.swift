import Foundation
import Testing
@testable import MacarumCore

@Suite struct SystemMemoryTests {
    private let mb: UInt64 = 1_048_576

    private func sample(_ path: String, _ footprintMB: UInt64, resident residentMB: UInt64 = 0,
                        pid: pid_t = 1, args: [String] = []) -> ProcessSample {
        ProcessSample(pid: pid, path: path, arguments: args, footprint: footprintMB * mb, resident: residentMB * mb)
    }

    @Test func helpersCountTowardTheirApp() {
        let groups = SystemMemory.group([
            sample("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", 500, resident: 400),
            sample("/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)", 300, resident: 100),
            sample("/private/var/folders/x/X/com.google.Chrome.code_sign_clone/code_sign_clone.abc/Google Chrome.app.bundle/Contents/MacOS/Google Chrome", 200, resident: 200),
        ])
        #expect(groups.count == 1)
        #expect(groups[0].name == "Google Chrome")
        #expect(groups[0].bytes == 1000 * mb)
        #expect(groups[0].outOfRAM == 300 * mb)
        #expect(groups[0].processCount == 3)
        #expect(groups[0].key == "/Applications/Google Chrome.app")
        #expect(groups[0].isAppBundle)
    }

    @Test func sortedByMemoryOutOfRAMNotByTotal() {
        // Chrome is bigger but busy; the forgotten dev server holds more that is not used.
        let groups = SystemMemory.group([
            sample("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", 9000, resident: 7000),
            sample("/opt/homebrew/bin/node", 3000, resident: 30, pid: 82762,
                   args: ["/Users/me/Projects/shop/node_modules/.bin/expo", "start", "--port", "8081"]),
        ])
        #expect(groups.map(\.name) == ["node", "Google Chrome"])
        #expect(groups[0].detail == "expo start · shop")
        #expect(groups[0].pid == 82762)
        #expect(!groups[0].isAppBundle)
    }

    @Test func programsStayOnePerProcess() {
        let groups = SystemMemory.group([
            sample("/opt/homebrew/bin/node", 100, pid: 10),
            sample("/opt/homebrew/bin/node", 50, pid: 11),
        ])
        #expect(groups.map(\.key) == ["pid:10", "pid:11"])
    }

    @Test(arguments: [
        (["/Users/me/Projects/notes/node_modules/.bin/expo", "start", "--port", "8082"], "expo start · notes"),
        (["/opt/homebrew/lib/node_modules/openclaw/dist/index.js", "gateway", "--port", "18789"], "openclaw gateway"),
        (["/Users/me/.npm/_npx/705d/node_modules/.bin/mcp-remote", "https://erp.example.com/mcp"], "mcp-remote"),
        (["--inspect", "server.js"], "server.js"),
        ([String](), nil),
    ] as [([String], String?)])
    func describesPrograms(args: [String], expected: String?) {
        #expect(SystemMemory.describe(args) == expected)
    }

    @Test func pressureLevels() {
        #expect(MemoryPressure(kernelLevel: 1) == .normal)
        #expect(MemoryPressure(kernelLevel: 2) == .warning)
        #expect(MemoryPressure(kernelLevel: 4) == .critical)
    }

    @Test func readsThisMac() throws {
        #expect(SystemMemory.physicalMemory > 0)
        let me = try #require(SystemMemory.processes().first { $0.pid == ProcessInfo.processInfo.processIdentifier })
        #expect(me.footprint > 0)
        #expect(me.startedAt.map { $0 < Date() } == true)
        let swap = SystemMemory.swap()
        #expect(swap.used <= swap.total)
    }
}
