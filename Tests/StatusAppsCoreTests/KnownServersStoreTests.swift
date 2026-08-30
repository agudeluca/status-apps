import XCTest
@testable import StatusAppsCore

final class KnownServersStoreTests: XCTestCase {

    private var fileURL: URL!

    override func setUpWithError() throws {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("status-apps-tests-\(UUID().uuidString)")
            .appendingPathComponent("known.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private func server(label: String, kind: DevServerKind = .metro, pid: Int32 = 1) -> DevServer {
        DevServer(
            process: Fixtures.process(pid: pid, executablePath: "/bin/node", workingDirectory: "/p/\(label)"),
            kind: kind,
            label: label
        )
    }

    func testRecordedServersSurviveAReload() {
        let store = KnownServersStore(fileURL: fileURL)
        store.record([server(label: "alpha")])

        let reloaded = KnownServersStore(fileURL: fileURL)

        XCTAssertEqual(reloaded.recentlyStopped(excluding: []).map(\.label), ["alpha"])
    }

    func testRunningServersAreExcludedFromRecentlyStopped() {
        let store = KnownServersStore(fileURL: fileURL)
        let alpha = server(label: "alpha")
        let beta = server(label: "beta", pid: 2)
        store.record([alpha, beta])

        let stopped = store.recentlyStopped(excluding: [alpha])

        XCTAssertEqual(stopped.map(\.label), ["beta"])
    }

    /// The same command in the same directory is the same server, even with a new pid.
    func testRestartedServerDoesNotCreateASecondEntry() {
        let store = KnownServersStore(fileURL: fileURL)
        store.record([server(label: "alpha", pid: 1)])
        store.record([server(label: "alpha", pid: 999)])

        XCTAssertEqual(store.recentlyStopped(excluding: []).count, 1)
    }

    func testForgetRemovesAnEntry() {
        let store = KnownServersStore(fileURL: fileURL)
        store.record([server(label: "alpha")])
        let entry = try? XCTUnwrap(store.recentlyStopped(excluding: []).first)

        store.forget(try! XCTUnwrap(entry))

        XCTAssertTrue(store.recentlyStopped(excluding: []).isEmpty)
    }

    func testEntriesOlderThanTheMaximumAgeArePruned() {
        let store = KnownServersStore(fileURL: fileURL)
        let longAgo = Date().addingTimeInterval(-KnownServersStore.maximumAge - 60)
        store.record([server(label: "stale")], now: longAgo)

        store.record([server(label: "fresh", pid: 2)])

        XCTAssertEqual(store.recentlyStopped(excluding: []).map(\.label), ["fresh"])
    }

    func testTheListIsCappedKeepingTheMostRecent() {
        let store = KnownServersStore(fileURL: fileURL)
        let total = KnownServersStore.entryLimit + 5
        for index in 0..<total {
            store.record(
                [server(label: "p\(index)", pid: Int32(index + 1))],
                now: Date().addingTimeInterval(TimeInterval(index))
            )
        }

        let stored = store.recentlyStopped(excluding: [])

        XCTAssertEqual(stored.count, KnownServersStore.entryLimit)
        XCTAssertEqual(stored.first?.label, "p\(total - 1)")
    }
}

extension KnownServersStoreTests {

    /// One project can run several servers from the same directory — two `bun` entry points, or a
    /// bundler beside an API. They must not collapse into a single remembered entry.
    func testServersSharingADirectoryAreRememberedSeparately() {
        let store = KnownServersStore(fileURL: fileURL)
        let directory = "/Users/a/projects/toto/apps/api"

        let api = DevServer(
            process: Fixtures.process(
                pid: 64374, executablePath: "/bin/bun",
                arguments: ["bun", "--env-file=../../.env", "src/index.ts"],
                workingDirectory: directory, ports: [3000]
            ),
            kind: .bun, label: "api"
        )
        let worker = DevServer(
            process: Fixtures.process(
                pid: 95021, executablePath: "/bin/bun",
                arguments: ["bun", "src/index.ts"],
                workingDirectory: directory, ports: [3999]
            ),
            kind: .bun, label: "api"
        )

        store.record([api, worker])

        XCTAssertEqual(store.recentlyStopped(excluding: []).count, 2)
        XCTAssertEqual(store.recentlyStopped(excluding: [api]).map(\.primaryPort), [3999])
    }
}
