import XCTest
@testable import StatusAppsCore

final class FormattersTests: XCTestCase {

    func testMemoryUsesTheUnitThatKeepsTheColumnNarrow() {
        XCTAssertEqual(Formatters.memory(4_949_000_000), "4.6G")
        XCTAssertEqual(Formatters.memory(68_000_000), "65M")
        XCTAssertEqual(Formatters.memory(4_096), "4K")
        XCTAssertEqual(Formatters.memory(512), "512B")
    }

    func testUptimeIsCoarse() {
        XCTAssertEqual(Formatters.uptime(9 * 86_400 + 22 * 3_600), "9d 22h")
        XCTAssertEqual(Formatters.uptime(10 * 86_400), "10d")
        XCTAssertEqual(Formatters.uptime(3 * 3_600 + 5 * 60), "3h 5m")
        XCTAssertEqual(Formatters.uptime(180), "3m")
        XCTAssertEqual(Formatters.uptime(12), "12s")
    }

    func testUptimeClampsNegativeIntervals() {
        XCTAssertEqual(Formatters.uptime(-100), "0s")
    }

    func testPaddingNeverTruncates() {
        XCTAssertEqual(Formatters.pad(":80", to: 8), ":80     ")
        XCTAssertEqual(Formatters.pad(":100000", to: 4), ":100000")
    }

    func testSwapReportsPercentage() {
        let usage = SwapUsage(total: 20 * 1024 * 1024 * 1024, used: 18 * 1024 * 1024 * 1024)
        XCTAssertEqual(Formatters.swap(usage), "Swap 18.0G / 20.0G (90%)")
    }

    func testSwapWithNoAllocationDoesNotDivideByZero() {
        XCTAssertEqual(SwapUsage(total: 0, used: 0).fraction, 0)
    }
}

extension FormattersTests {

    private var metro: DevServer {
        DevServer(
            process: Fixtures.metroInWorktree,
            kind: .metro,
            label: "humand-mobile/oli-barge-in"
        )
    }

    /// The reference case: a Metro bundler up for nine days and untouched for six, which is the
    /// situation the app exists to make visible. Neither number says it alone.
    func testServerRowPlacesEveryValueInItsColumn() {
        let started = Fixtures.metroInWorktree.startedAt
        let now = started.addingTimeInterval(9 * 86_400 + 22 * 3_600)
        let lastUsed = now.addingTimeInterval(-(6 * 86_400 + 4 * 3_600))

        let row = Formatters.serverRow(metro, lastUsed: lastUsed, now: now)

        XCTAssertEqual(row, ":8082   4.6G   9d 22h   6d 4h    metro — humand-mobile/oli-barge-in")
    }

    func testServerRowLeavesTheIdleColumnBlankBeforeTheFirstObservation() {
        let started = Fixtures.metroInWorktree.startedAt
        let now = started.addingTimeInterval(9 * 86_400 + 22 * 3_600)

        let row = Formatters.serverRow(metro, now: now)

        XCTAssertEqual(row, ":8082   4.6G   9d 22h   —        metro — humand-mobile/oli-barge-in")
    }

    func testHeaderColumnsLineUpWithARow() {
        let started = Fixtures.metroInWorktree.startedAt
        let row = Formatters.serverRow(metro, now: started.addingTimeInterval(60))

        for column in ["MEM", "UP", "IDLE", "PROCESS"] {
            let headerOffset = try? XCTUnwrap(Formatters.serverRowHeader.range(of: column))
            XCTAssertNotNil(headerOffset)
        }
        XCTAssertEqual(
            Formatters.serverRowHeader.distance(
                from: Formatters.serverRowHeader.startIndex,
                to: Formatters.serverRowHeader.range(of: "PROCESS")!.lowerBound
            ),
            row.distance(from: row.startIndex, to: row.range(of: "metro —")!.lowerBound),
            "the process column must start at the same offset in the header and in a row"
        )
    }

    func testServerRowMarksAServerWithNoPort() {
        let server = DevServer(
            process: Fixtures.process(executablePath: "/bin/node", ports: []),
            kind: .node,
            label: "orphan"
        )

        XCTAssertTrue(Formatters.serverRow(server).hasPrefix("—"))
    }

    func testRecentRowSaysHowLongAgoItWasSeen() {
        let seen = Date(timeIntervalSince1970: 1_788_000_000)
        let known = KnownServer(
            label: "humand-mobile/oli-barge-in", kind: .metro,
            workingDirectory: "/p", arguments: ["node"], primaryPort: 8082, lastSeen: seen
        )

        let row = Formatters.recentRow(known, now: seen.addingTimeInterval(3 * 3_600))

        XCTAssertEqual(row, "metro — humand-mobile/oli-barge-in :8082 · 3h ago")
    }

    func testTheIdleColumnKeepsTheRowAlignedWithTheHeader() {
        let metro = DevServer(process: Fixtures.metroInWorktree, kind: .metro, label: "humand-mobile")
        let started = Fixtures.metroInWorktree.startedAt
        let now = started.addingTimeInterval(9 * 86_400)

        // The widest thing the column ever holds, against the narrowest.
        let long = Formatters.serverRow(metro, lastUsed: started, now: now)
        let unknown = Formatters.serverRow(metro, lastUsed: nil, now: now)

        for row in [long, unknown] {
            XCTAssertEqual(
                Formatters.serverRowHeader.distance(
                    from: Formatters.serverRowHeader.startIndex,
                    to: Formatters.serverRowHeader.range(of: "PROCESS")!.lowerBound
                ),
                row.distance(from: row.startIndex, to: row.range(of: "metro —")!.lowerBound),
                "the process column must not shift with the width of the idle value"
            )
        }
    }

    func testIdleIsUnknownUntilTheServerHasBeenWatched() {
        XCTAssertEqual(
            Formatters.idle(since: nil), "—",
            "never observed working is not the same as idle forever, and must not print as a duration"
        )
    }

    func testIdleReadsAsActiveWithinTheLastMinute() {
        let now = Date(timeIntervalSince1970: 1_788_000_000)

        XCTAssertEqual(Formatters.idle(since: now.addingTimeInterval(-3), now: now), "active")
        XCTAssertEqual(Formatters.idle(since: now.addingTimeInterval(-59), now: now), "active")
    }

    func testIdleBecomesADurationOnceItMatters() {
        let now = Date(timeIntervalSince1970: 1_788_000_000)

        XCTAssertEqual(Formatters.idle(since: now.addingTimeInterval(-90), now: now), "1m")
        XCTAssertEqual(
            Formatters.idle(since: now.addingTimeInterval(-6 * 86_400 - 4 * 3_600), now: now),
            "6d 4h"
        )
    }

    func testRecentRowOmitsThePortWhenNoneWasRecorded() {
        let seen = Date()
        let known = KnownServer(
            label: "worker", kind: .bun, workingDirectory: "/p",
            arguments: ["bun"], primaryPort: nil, lastSeen: seen
        )

        XCTAssertEqual(Formatters.recentRow(known, now: seen), "bun — worker · 0s ago")
    }
}

extension FormattersTests {

    /// The dialog has to name what dies, not just count it.
    func testBulkStopSummaryListsEachProcess() {
        let started = Fixtures.metroInWorktree.startedAt
        let now = started.addingTimeInterval(9 * 86_400 + 22 * 3_600)

        let summary = Formatters.bulkStopSummary([metro], now: now)

        XCTAssertEqual(summary, ":8082  metro — humand-mobile/oli-barge-in  ·  9d 22h")
    }

    func testBulkStopSummaryHasOneLinePerServer() {
        let servers = DevServerClassifier.classify(Fixtures.all)

        let summary = Formatters.bulkStopSummary(servers)

        XCTAssertEqual(summary.split(separator: "\n").count, servers.count)
    }
}
