import XCTest
@testable import StatusAppsCore

final class ServerActionsTests: XCTestCase {

    private func known(
        label: String, kind: DevServerKind = .bun, port: UInt16?, cwd: String = "/p/api"
    ) -> KnownServer {
        KnownServer(
            label: label, kind: kind, workingDirectory: cwd,
            arguments: ["bun", "src/index.ts"], primaryPort: port, lastSeen: Date()
        )
    }

    /// Two servers can share a directory and a label; their tmux sessions must not collide, or a
    /// rerun of one would tear down the other.
    func testSessionNamesDifferWhenOnlyThePortDiffers() {
        let first = ServerActions.sessionName(for: known(label: "api", port: 3000))
        let second = ServerActions.sessionName(for: known(label: "api", port: 3999))

        XCTAssertNotEqual(first, second)
    }

    func testSessionNameStripsCharactersTmuxTreatsAsSeparators() {
        let name = ServerActions.sessionName(
            for: known(label: "humand-mobile/oli.barge:in", kind: .metro, port: 8082)
        )

        XCTAssertFalse(name.contains("."))
        XCTAssertFalse(name.contains(":"))
        XCTAssertFalse(name.contains("/"))
        XCTAssertTrue(name.hasPrefix("metro-"))
    }

    func testSessionNameFallsBackToTheDirectoryWhenThereIsNoPort() {
        let first = ServerActions.sessionName(for: known(label: "scratchpad", port: nil, cwd: "/a/scratchpad"))
        let second = ServerActions.sessionName(for: known(label: "scratchpad", port: nil, cwd: "/b/scratchpad"))

        XCTAssertNotEqual(first, second)
    }

    func testSessionNameIsStableForTheSameServer() {
        let server = known(label: "api", port: 3000)

        XCTAssertEqual(ServerActions.sessionName(for: server), ServerActions.sessionName(for: server))
    }

    func testShellQuotingSurvivesEmbeddedQuotes() {
        XCTAssertEqual(ServerActions.shellQuote("it's"), #"'it'\''s'"#)
        XCTAssertEqual(ServerActions.shellQuote("--env-file=../../.env"), "'--env-file=../../.env'")
    }

    func testCleanIsRefusedForKindsWithoutAKnownCacheLayout() {
        let server = DevServer(
            process: Fixtures.bunAPI, kind: .bun, label: "api"
        )
        XCTAssertTrue(ServerActions.cleanCaches(for: server).isEmpty)
    }

    func testIsRunningRecognisesThisProcess() {
        XCTAssertTrue(ServerActions.isRunning(pid: getpid()))
    }
}

extension ServerActionsTests {

    private func devServer(pid: Int32, pgid: Int32, label: String = "victim") -> DevServer {
        DevServer(
            process: Fixtures.process(
                pid: pid, pgid: pgid, executablePath: "/bin/sleep",
                arguments: ["sleep", "30"], workingDirectory: "/tmp", ports: [9999]
            ),
            kind: .node,
            label: label
        )
    }

    private func spawnSleep() throws -> Process {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        return child
    }

    /// The production path: a dev server runs in its own process group, and stopping it signals
    /// the group so a `yarn start` parent goes down with its `node` child.
    func testStopEndsARealProcessViaItsProcessGroup() throws {
        let child = try spawnSleep()
        let pid = child.processIdentifier
        XCTAssertNotEqual(getpgid(pid), getpgrp(), "precondition: the child has its own group")

        try ServerActions.stop(devServer(pid: pid, pgid: getpgid(pid)))
        child.waitUntilExit()

        XCTAssertFalse(child.isRunning)
    }

    /// If a scanned process ever reported our own process group, signalling it would take the app
    /// down along with the server. Stopping must fall through to the pid instead.
    ///
    /// Were the guard missing, this test would kill the test runner rather than fail.
    func testStopNeverSignalsTheCallersOwnProcessGroup() throws {
        let child = try spawnSleep()

        try ServerActions.stop(devServer(pid: child.processIdentifier, pgid: getpgrp()))
        child.waitUntilExit()

        XCTAssertFalse(child.isRunning, "the pid fallback should still have stopped it")
        XCTAssertTrue(ServerActions.isRunning(pid: getpid()), "the caller must survive")
    }

    func testStoppingSomethingAlreadyGoneIsNotAnError() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["0"]
        try child.run()
        let pid = child.processIdentifier
        child.waitUntilExit()

        XCTAssertNoThrow(try ServerActions.stop(devServer(pid: pid, pgid: getpgrp())))
    }

    func testBulkStopReportsWhatSucceeded() {
        let outcome = ServerActions.stop([DevServer]())

        XCTAssertEqual(outcome, BulkStopOutcome(requested: 0, failures: []))
        XCTAssertTrue(outcome.isCompleteSuccess)
    }

    func testBulkOutcomeCountsSuccessesAgainstFailures() {
        let outcome = BulkStopOutcome(requested: 5, failures: ["a: no", "b: no"])

        XCTAssertEqual(outcome.stopped, 3)
        XCTAssertFalse(outcome.isCompleteSuccess)
    }
}
