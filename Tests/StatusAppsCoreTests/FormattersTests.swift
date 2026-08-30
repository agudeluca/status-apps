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
