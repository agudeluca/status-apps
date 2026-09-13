import XCTest
@testable import StatusAppsCore

/// The counters are cumulative, so every case here is about a *pair* of observations. The single
/// reading cases — first sight, a recycled pid — are the ones where the honest answer is "unknown"
/// rather than "idle", and they are the easiest to get wrong.
final class ActivityMonitorTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_788_000_000)
    private lazy var t0 = Date(timeIntervalSince1970: 1_788_100_000)

    /// 1% of one core over `seconds`, in nanoseconds — comfortably over the 0.2% threshold.
    private func busyCPU(seconds: TimeInterval) -> UInt64 {
        UInt64(seconds * 1_000_000_000 * 0.01)
    }

    private func server(
        cpuTime: UInt64 = 0,
        diskBytesRead: UInt64 = 0,
        pid: Int32 = 1,
        startedAt: Date? = nil,
        label: String = "alpha"
    ) -> DevServer {
        DevServer(
            process: Fixtures.process(
                pid: pid,
                executablePath: "/bin/node",
                arguments: ["node", label],
                workingDirectory: "/p/\(label)",
                startedAt: startedAt ?? start,
                cpuTime: cpuTime,
                diskBytesRead: diskBytesRead
            ),
            kind: .metro,
            label: label
        )
    }

    func testTheFirstObservationReportsNothing() {
        let monitor = ActivityMonitor()

        let active = monitor.activeIdentities(among: [server(cpuTime: 999_999_999_999)], now: t0)

        XCTAssertTrue(
            active.isEmpty,
            "with no baseline there is no rate, and a huge cumulative counter says only that the process is old"
        )
    }

    func testCPUAboveTheThresholdCountsAsWork() {
        let monitor = ActivityMonitor()
        _ = monitor.activeIdentities(among: [server(cpuTime: 0)], now: t0)

        let busy = server(cpuTime: busyCPU(seconds: 5))
        let active = monitor.activeIdentities(among: [busy], now: t0.addingTimeInterval(5))

        XCTAssertEqual(active, [busy.identity])
    }

    func testAnIdleServerIsNotReportedAsWorking() {
        let monitor = ActivityMonitor()
        _ = monitor.activeIdentities(among: [server(cpuTime: 0)], now: t0)

        // 0.01% of a core: what every idle bundler measured on a real machine was doing.
        let idle = server(cpuTime: UInt64(5 * 1_000_000_000 * 0.0001))
        let active = monitor.activeIdentities(among: [idle], now: t0.addingTimeInterval(5))

        XCTAssertTrue(active.isEmpty)
    }

    func testDiskReadsCountEvenWhenTheCPUStaysFlat() {
        let monitor = ActivityMonitor()
        _ = monitor.activeIdentities(among: [server(diskBytesRead: 0)], now: t0)

        let reading = server(diskBytesRead: 4 * 1024 * 1024)
        let active = monitor.activeIdentities(among: [reading], now: t0.addingTimeInterval(5))

        XCTAssertEqual(active, [reading.identity], "a bundler rebuilding reads its sources")
    }

    func testAWindowTooShortToMeasureKeepsTheOlderBaseline() {
        let monitor = ActivityMonitor()
        _ = monitor.activeIdentities(among: [server(cpuTime: 0)], now: t0)

        // A second scan almost immediately: dividing by ~0 here would read as a burst of work.
        let burst = monitor.activeIdentities(
            among: [server(cpuTime: busyCPU(seconds: 2))], now: t0.addingTimeInterval(0.1)
        )
        XCTAssertTrue(burst.isEmpty, "two scans in the same instant must not manufacture a rate")

        // No further CPU since that discarded sample. It still counts as work, because the
        // comparison has to run against the baseline from t0 rather than the one it refused.
        let busy = server(cpuTime: busyCPU(seconds: 2))
        let active = monitor.activeIdentities(among: [busy], now: t0.addingTimeInterval(2))

        XCTAssertEqual(active, [busy.identity])
    }

    func testARecycledPIDStartsOverInsteadOfReportingTheDifference() {
        let monitor = ActivityMonitor()
        _ = monitor.activeIdentities(among: [server(cpuTime: 500_000_000_000)], now: t0)

        // Same pid, different launch: a new process whose counters restarted from zero.
        let replacement = server(
            cpuTime: busyCPU(seconds: 5), startedAt: start.addingTimeInterval(90_000)
        )
        let active = monitor.activeIdentities(among: [replacement], now: t0.addingTimeInterval(5))

        XCTAssertTrue(active.isEmpty, "the drop across a recycled pid is not idleness or work")
    }

    func testACounterGoingBackwardsClaimsNothing() {
        let monitor = ActivityMonitor()
        _ = monitor.activeIdentities(among: [server(cpuTime: 10_000_000_000)], now: t0)

        let active = monitor.activeIdentities(
            among: [server(cpuTime: 1_000_000_000)], now: t0.addingTimeInterval(5)
        )

        XCTAssertTrue(active.isEmpty)
    }

    func testAServerThatDisappearsLosesItsBaseline() {
        let monitor = ActivityMonitor()
        _ = monitor.activeIdentities(among: [server(cpuTime: 0)], now: t0)
        _ = monitor.activeIdentities(among: [], now: t0.addingTimeInterval(5))

        // Back with plenty of accumulated CPU, but nothing to compare it against any more.
        let returned = server(cpuTime: busyCPU(seconds: 100))
        let active = monitor.activeIdentities(among: [returned], now: t0.addingTimeInterval(10))

        XCTAssertTrue(active.isEmpty)
    }

    func testServersAreJudgedIndependently() {
        let monitor = ActivityMonitor()
        let idleBefore = server(cpuTime: 0, pid: 1, label: "idle")
        let busyBefore = server(cpuTime: 0, pid: 2, label: "busy")
        _ = monitor.activeIdentities(among: [idleBefore, busyBefore], now: t0)

        let busyAfter = server(cpuTime: busyCPU(seconds: 5), pid: 2, label: "busy")
        let active = monitor.activeIdentities(
            among: [server(cpuTime: 0, pid: 1, label: "idle"), busyAfter],
            now: t0.addingTimeInterval(5)
        )

        XCTAssertEqual(active, [busyAfter.identity])
    }
}
