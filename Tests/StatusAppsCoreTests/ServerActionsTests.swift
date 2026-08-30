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
