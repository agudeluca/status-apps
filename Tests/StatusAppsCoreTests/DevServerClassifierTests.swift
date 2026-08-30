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

extension DevServerClassifierTests {

    func testGroupsByRuntimeLargestFirst() {
        let servers = DevServerClassifier.classify(Fixtures.all)

        let groups = DevServerClassifier.groupedByKind(servers)

        XCTAssertEqual(groups.first?.kind, .metro)
        XCTAssertEqual(groups.first?.servers.count, 2)
        XCTAssertEqual(Set(groups.map(\.kind)), [.metro, .bun, .postgres])
    }

    func testGroupsOfEqualSizeAreOrderedByName() {
        let servers = DevServerClassifier.classify([Fixtures.bunAPI, Fixtures.postgres])

        let groups = DevServerClassifier.groupedByKind(servers)

        XCTAssertEqual(groups.map(\.kind), [.bun, .postgres])
    }

    func testEveryServerAppearsInExactlyOneGroup() {
        let servers = DevServerClassifier.classify(Fixtures.all)

        let grouped = DevServerClassifier.groupedByKind(servers).flatMap(\.servers)

        XCTAssertEqual(Set(grouped.map(\.pid)), Set(servers.map(\.pid)))
        XCTAssertEqual(grouped.count, servers.count)
    }
}

extension DevServerClassifierTests {

    /// Homebrew's Python lives at `Python.app/Contents/MacOS/Python`: the basename is capitalised
    /// and carries no version, while argv[0] is the familiar `python3`.
    func testHomebrewPythonIsRecognised() {
        let process = Fixtures.process(
            executablePath: "/opt/homebrew/Cellar/python@3.14/3.14.6/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python",
            arguments: ["python3", "-m", "http.server", "8099"],
            workingDirectory: "/Users/a/projects/status-apps",
            ports: [8099]
        )

        XCTAssertEqual(DevServerClassifier.kind(for: process), .python)
    }

    func testVersionedExecutableNamesAreRecognised() {
        for (name, expected) in [
            ("python3.14", DevServerKind.python), ("php8.2", .php), ("node20", .node), ("ruby3.3", .ruby),
        ] {
            let process = Fixtures.process(executablePath: "/usr/local/bin/\(name)")
            XCTAssertEqual(DevServerClassifier.kind(for: process), expected, "for \(name)")
        }
    }

    func testNormalisationDoesNotConflateDifferentTools() {
        XCTAssertEqual(DevServerClassifier.normalize("javac"), "javac")
        XCTAssertNil(DevServerClassifier.kind(for: Fixtures.process(executablePath: "/usr/bin/javac")))
    }

    func testNormalisationKeepsNamesThatAreOnlyDigits() {
        XCTAssertEqual(DevServerClassifier.normalize("7"), "7")
    }
}
