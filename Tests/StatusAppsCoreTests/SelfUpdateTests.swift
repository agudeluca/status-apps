import XCTest
@testable import StatusAppsCore

/// The check is git plumbing, so the tests drive real repositories: an origin and a clone of it in
/// a temporary directory. Fixtures of git output would only assert that the strings were copied
/// correctly, not that the commands mean what the code thinks they mean.
final class SelfUpdateTests: XCTestCase {

    private var root: URL!
    private var origin: URL!
    private var clone: URL!

    override func setUpWithError() throws {
        try XCTSkipIf(ServerActions.which("git") == nil, "git is not installed")

        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("status-apps-update-\(UUID().uuidString)")
        origin = root.appendingPathComponent("origin")
        clone = root.appendingPathComponent("clone")
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)

        try git(["init", "--quiet", "--initial-branch=main"], in: origin)
        try git(["config", "user.email", "test@example.com"], in: origin)
        try git(["config", "user.name", "Status Apps Tests"], in: origin)
        try commit("first commit", in: origin)
        try git(["clone", "--quiet", origin.path, clone.path], in: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Driving git

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) throws -> String {
        let path = try XCTUnwrap(ServerActions.which("git"))
        let result = try ServerActions.run(path, ["-C", directory.path] + arguments)
        XCTAssertEqual(result.status, 0, "git \(arguments.joined(separator: " ")): \(result.output)")
        return result.output
    }

    private func commit(_ message: String, in directory: URL) throws {
        let file = directory.appendingPathComponent("file.txt")
        try message.write(to: file, atomically: true, encoding: .utf8)
        try git(["add", "file.txt"], in: directory)
        try git(["commit", "--quiet", "-m", message], in: directory)
    }

    // MARK: - Checking

    func testACloneThatMatchesItsUpstreamIsUpToDate() {
        XCTAssertEqual(SelfUpdate.check(in: clone.path), .upToDate)
    }

    /// The count is the whole point of the menu row, so it has to survive a real fetch rather than
    /// being inferred from "the sha differs".
    func testCommitsWaitingUpstreamAreCountedAndNamed() throws {
        try commit("second commit", in: origin)
        try commit("third commit", in: origin)

        guard case .available(let update) = SelfUpdate.check(in: clone.path) else {
            return XCTFail("expected an available update")
        }

        XCTAssertEqual(update.count, 2)
        XCTAssertEqual(update.subjects, ["third commit", "second commit"])
        XCTAssertNil(update.blocked)
    }

    /// Installing resets the checkout. Someone with edits in it has to be told rather than have
    /// them thrown away by a menu click.
    func testAnUpdateIsBlockedWhileTheCheckoutHasLocalChanges() throws {
        try commit("second commit", in: origin)
        try "edited".write(
            to: clone.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8
        )

        guard case .available(let update) = SelfUpdate.check(in: clone.path) else {
            return XCTFail("expected an available update")
        }

        XCTAssertEqual(update.count, 1)
        XCTAssertNotNil(update.blocked)
    }

    /// A branch nobody pushed has nothing to be behind — that is not a failure to report, it is a
    /// reason to show no row at all.
    func testARepositoryWithoutAnUpstreamIsUnavailableRatherThanFailed() {
        XCTAssertEqual(SelfUpdate.check(in: origin.path), .unavailable)
    }

    func testAPathThatIsNotACheckoutIsUnavailable() {
        XCTAssertEqual(SelfUpdate.check(in: root.path), .unavailable)
    }

    func testAMissingDirectoryIsUnavailable() {
        XCTAssertEqual(SelfUpdate.check(in: root.appendingPathComponent("gone").path), .unavailable)
    }

    // MARK: - Installing

    /// A stub in place of the real script: what is under test is what the app hands over and what
    /// it makes of the result, not the build itself.
    private func installScript(exiting status: Int) throws {
        let scripts = clone.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let script = scripts.appendingPathComponent("install.sh")
        try """
        #!/bin/bash
        echo "src=$STATUS_APPS_SRC"
        echo "dest=$STATUS_APPS_DEST"
        exit \(status)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    /// The checkout and the destination reach the script through the environment. `STATUS_APPS_SRC`
    /// in particular is what makes it fetch and reset rather than rebuild the code already
    /// installed, so an update that silently dropped it would appear to do nothing.
    func testTheScriptIsToldWhichCheckoutToBuildAndWhereToInstallIt() throws {
        try installScript(exiting: 0)
        let log = root.appendingPathComponent("update.log")

        let process = try SelfUpdate.apply(
            in: clone.path,
            destination: "/tmp/destination",
            logPath: log.path,
            onFailure: { XCTFail("a successful install reported a failure: \($0)") }
        )
        process.waitUntilExit()

        let output = try String(contentsOf: log, encoding: .utf8)
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(output.contains("src=\(clone.path)"), output)
        XCTAssertTrue(output.contains("dest=/tmp/destination"), output)
    }

    /// Failure is the only outcome the app survives to report: a successful install kills it
    /// halfway through. What it reports is the end of the log, which is where the error is.
    func testAFailedInstallIsReportedWithTheEndOfItsLog() throws {
        try installScript(exiting: 3)
        let log = root.appendingPathComponent("update.log")
        let reported = expectation(description: "the failure is reported")
        var reason = ""

        _ = try SelfUpdate.apply(
            in: clone.path,
            destination: "/tmp/destination",
            logPath: log.path,
            onFailure: {
                reason = $0
                reported.fulfill()
            }
        )
        wait(for: [reported], timeout: 30)

        XCTAssertTrue(reason.contains("dest=/tmp/destination"), reason)
    }

    func testApplyRefusesACheckoutWithoutTheInstallScript() {
        XCTAssertThrowsError(
            try SelfUpdate.apply(
                in: clone.path,
                destination: root.path,
                logPath: root.appendingPathComponent("update.log").path,
                onFailure: { _ in }
            )
        )
    }

    /// What the menu shows when an update fails is the tail of the log, since the failure is at
    /// the end and the build output above it is noise.
    func testTheReportedFailureIsTheEndOfTheLog() throws {
        let log = root.appendingPathComponent("update.log")
        try (1...20).map { "line \($0)" }.joined(separator: "\n").write(
            to: log, atomically: true, encoding: .utf8
        )

        let tail = SelfUpdate.tail(of: log.path, lines: 3)

        XCTAssertEqual(tail, "line 18\nline 19\nline 20")
    }

    func testAMissingLogStillSaysWhereToLook() {
        let path = root.appendingPathComponent("nowhere.log").path

        XCTAssertTrue(SelfUpdate.tail(of: path).contains(path))
    }
}
