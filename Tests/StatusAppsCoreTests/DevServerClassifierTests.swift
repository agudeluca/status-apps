import XCTest
@testable import StatusAppsCore

final class DevServerClassifierTests: XCTestCase {

    func testKeepsOnlyDevelopmentServers() {
        let servers = DevServerClassifier.classify(Fixtures.all)
        let pids = Set(servers.map(\.pid))

        XCTAssertEqual(pids, [36315, 5857, 64374, 76579])
    }

    func testExcludesListenersThatAreNotDevelopmentTools() {
        let servers = DevServerClassifier.classify([
            Fixtures.adb, Fixtures.wineserver, Fixtures.logitech, Fixtures.controlCenter,
        ])
        XCTAssertTrue(servers.isEmpty)
    }

    func testNodeRunningExpoIsClassifiedAsMetro() {
        XCTAssertEqual(DevServerClassifier.kind(for: Fixtures.metroInWorktree), .metro)
        XCTAssertEqual(DevServerClassifier.kind(for: Fixtures.metroInMainCheckout), .metro)
    }

    func testRuntimesAreClassifiedByExecutable() {
        XCTAssertEqual(DevServerClassifier.kind(for: Fixtures.bunAPI), .bun)
        XCTAssertEqual(DevServerClassifier.kind(for: Fixtures.postgres), .postgres)
    }

    func testSortsByFootprintDescending() {
        let servers = DevServerClassifier.classify(Fixtures.all)
        XCTAssertEqual(servers.map(\.footprint), servers.map(\.footprint).sorted(by: >))
    }

    // MARK: - Marker matching

    func testMarkerMatchesWholePathComponent() {
        let markers = DevServerClassifier.matchedMarkers(in: [
            "/Users/a/project/node_modules/.bin/expo", "start",
        ])
        XCTAssertEqual(markers, ["expo"])
    }

    func testMarkerMatchesFileWithExtension() {
        let markers = DevServerClassifier.matchedMarkers(in: ["node", "/app/node_modules/metro/src/cli.js"])
        XCTAssertTrue(markers.contains("metro"))
    }

    /// A directory called `nextcloud` must not register as the `next` dev server.
    func testMarkerDoesNotMatchSubstringOfAnotherName() {
        let markers = DevServerClassifier.matchedMarkers(in: ["/Users/a/nextcloud/server.py"])
        XCTAssertTrue(markers.isEmpty)
    }

    func testUnknownInterpreterRunningKnownToolStillCounts() {
        let process = Fixtures.process(
            executablePath: "/opt/weird/runtime",
            arguments: ["runtime", "/app/node_modules/.bin/vite"]
        )
        XCTAssertEqual(DevServerClassifier.kind(for: process), .node)
    }
}
