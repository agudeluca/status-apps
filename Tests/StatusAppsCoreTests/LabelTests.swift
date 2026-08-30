import XCTest
@testable import StatusAppsCore

final class LabelTests: XCTestCase {

    func testWorktreeYieldsRepositoryAndWorktreeName() {
        let label = DevServerClassifier.label(
            workingDirectory: "/Users/a/projects/humand-mobile/.worktrees/oli-barge-in",
            executableName: "node"
        )
        XCTAssertEqual(label, "humand-mobile/oli-barge-in")
    }

    func testWorktreeSubdirectoryStillYieldsTheWorktreeName() {
        let label = DevServerClassifier.label(
            workingDirectory: "/Users/a/projects/humand-mobile/.worktrees/oli-barge-in/apps/mobile",
            executableName: "node"
        )
        XCTAssertEqual(label, "humand-mobile/oli-barge-in")
    }

    func testPlainCheckoutYieldsDirectoryName() {
        let label = DevServerClassifier.label(
            workingDirectory: "/Users/a/projects/humand-mobile", executableName: "node"
        )
        XCTAssertEqual(label, "humand-mobile")
    }

    func testRootDirectoryFallsBackToExecutable() {
        XCTAssertEqual(
            DevServerClassifier.label(workingDirectory: "/", executableName: "adb"), "adb"
        )
    }

    func testMissingDirectoryFallsBackToExecutable() {
        XCTAssertEqual(
            DevServerClassifier.label(workingDirectory: "", executableName: "postgres"), "postgres"
        )
    }

    func testTrailingSlashDoesNotProduceEmptyLabel() {
        XCTAssertEqual(
            DevServerClassifier.label(workingDirectory: "/Users/a/projects/toto/", executableName: "bun"),
            "toto"
        )
    }

    func testWorktreesDirectoryWithoutANamedWorktreeFallsBack() {
        let label = DevServerClassifier.label(
            workingDirectory: "/Users/a/projects/humand-mobile/.worktrees", executableName: "node"
        )
        XCTAssertEqual(label, ".worktrees")
    }
}
