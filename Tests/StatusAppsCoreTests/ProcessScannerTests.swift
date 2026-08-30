import Darwin
import XCTest
@testable import StatusAppsCore

/// Integration tests: they run against the live system rather than fixtures, because the point of
/// the scanner is that it agrees with what the kernel actually reports.
final class ProcessScannerTests: XCTestCase {

    private var socketDescriptor: Int32 = -1

    override func tearDown() {
        if socketDescriptor >= 0 { close(socketDescriptor) }
        socketDescriptor = -1
        super.tearDown()
    }

    func testFindsAPortThisProcessIsListeningOn() throws {
        let port = try startListening()

        let ports = ProcessScanner.listeningPorts(getpid())

        XCTAssertTrue(ports.contains(port), "expected \(port) among \(ports)")
    }

    func testScanIncludesThisProcessOnceItListens() throws {
        let port = try startListening()

        let found = ProcessScanner.scanListeningProcesses().first { $0.pid == getpid() }

        let process = try XCTUnwrap(found, "the test process should appear in its own scan")
        XCTAssertTrue(process.listeningPorts.contains(port))
        XCTAssertGreaterThan(process.physicalFootprint, 0)
        XCTAssertFalse(process.executablePath.isEmpty)
        XCTAssertFalse(process.arguments.isEmpty)
        XCTAssertFalse(process.workingDirectory.isEmpty)
    }

    func testStartTimeIsInThePast() throws {
        _ = try startListening()

        let process = try XCTUnwrap(
            ProcessScanner.scanListeningProcesses().first { $0.pid == getpid() }
        )
        XCTAssertLessThanOrEqual(process.startedAt, Date())
    }

    func testEnumeratesEveryProcessTheSystemReports() {
        let pids = ProcessScanner.allPIDs()

        XCTAssertTrue(pids.contains(getpid()))
        XCTAssertTrue(pids.contains(1), "launchd should always be present")
        XCTAssertEqual(pids.count, Set(pids).count, "pids should not repeat")
    }

    func testClosedSocketsAreNotReported() {
        let ports = ProcessScanner.listeningPorts(getpid())
        XCTAssertTrue(ports.isEmpty, "nothing is listening before the socket is opened")
    }

    // MARK: - Helpers

    /// Binds an ephemeral port so the kernel picks one that is free, and returns it.
    private func startListening() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        try XCTSkipIf(descriptor < 0, "could not create a socket")
        socketDescriptor = descriptor

        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0  // ephemeral
        address.sin_addr.s_addr = INADDR_ANY
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)

        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, size) }
        }
        XCTAssertEqual(bound, 0, "bind failed: \(String(cString: strerror(errno)))")
        XCTAssertEqual(listen(descriptor, 1), 0)

        var assigned = sockaddr_in()
        var assignedSize = size
        let named = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &assignedSize)
            }
        }
        XCTAssertEqual(named, 0)
        return UInt16(bigEndian: assigned.sin_port)
    }
}
