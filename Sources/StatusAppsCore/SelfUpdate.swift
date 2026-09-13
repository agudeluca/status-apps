import Foundation

/// Whether a newer build is waiting in the checkout the app was built from.
public enum UpdateState: Equatable {
    /// Nothing to compare against: no recorded checkout, or not a git work tree with an upstream.
    /// The menu shows no row at all rather than a permanently dead one.
    case unavailable
    case upToDate
    case available(PendingUpdate)
    case inProgress
    case failed(String)
}

public struct PendingUpdate: Equatable {
    public let count: Int
    /// Newest first, capped. The menu shows these as a tooltip, not as a changelog.
    public let subjects: [String]
    /// Why the update cannot be applied from the menu, when it cannot.
    public let blocked: String?

    public init(count: Int, subjects: [String], blocked: String? = nil) {
        self.count = count
        self.subjects = subjects
        self.blocked = blocked
    }
}

/// Updating in place. The app was built from a checkout, so it can watch that checkout's upstream
/// and rebuild from it.
///
/// The build belongs to `scripts/install.sh`, the same script the one-command install runs.
/// Nothing here knows how to compile or where the app goes: it fetches, decides whether there is
/// anything new, and hands the work over.
public enum SelfUpdate {

    /// Enough to tell what is coming without turning a tooltip into release notes.
    static let subjectLimit = 5

    /// The checkout this bundle was built from, stamped into `Info.plist` by `scripts/bundle.sh`.
    /// Absent when the binary runs straight out of `swift build`, where there is no bundle.
    public static var bundledSourcePath: String? {
        guard let path = Bundle.main.object(forInfoDictionaryKey: "StatusAppsSourcePath") as? String,
              !path.isEmpty
        else { return nil }
        return path
    }

    /// Alongside the app's other state, so a failed update leaves something to read.
    public static func defaultLogURL() -> URL {
        KnownServersStore.defaultFileURL()
            .deletingLastPathComponent()
            .appendingPathComponent("update.log")
    }

    // MARK: - Checking

    /// Fetches, then compares the checkout against its upstream.
    ///
    /// A network round trip and several subprocesses, which is why the caller keeps it off the
    /// scan timer and the menu reads the last result rather than waiting for a new one.
    public static func check(in source: String) -> UpdateState {
        guard let gitPath = ServerActions.which("git"), isDirectory(source) else { return .unavailable }

        func git(_ arguments: [String]) -> ServerActions.CommandResult {
            (try? ServerActions.run(gitPath, ["-C", source] + arguments))
                ?? ServerActions.CommandResult(status: -1, output: "could not run git")
        }

        guard git(["rev-parse", "--is-inside-work-tree"]).output == "true" else { return .unavailable }
        // No upstream is not a failure: a branch nobody pushed has nothing to be behind.
        guard git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]).status == 0 else {
            return .unavailable
        }

        let fetched = git(["fetch", "--quiet"])
        guard fetched.status == 0 else {
            return .failed(firstLine(fetched.output, fallback: "git fetch failed"))
        }

        let counted = git(["rev-list", "--count", "HEAD..@{u}"])
        guard counted.status == 0, let count = Int(counted.output) else {
            return .failed(firstLine(counted.output, fallback: "could not compare against the upstream"))
        }
        guard count > 0 else { return .upToDate }

        let log = git(["log", "--format=%s", "-n", "\(subjectLimit)", "HEAD..@{u}"])
        let subjects = log.status == 0 ? log.output.split(separator: "\n").map(String.init) : []

        // Installing resets the checkout, which would take uncommitted work with it. Someone
        // editing the source can still run `make install` and decide for themselves.
        let dirty = !git(["status", "--porcelain"]).output.isEmpty
        return .available(PendingUpdate(
            count: count,
            subjects: subjects,
            blocked: dirty ? "\(source) has uncommitted changes." : nil
        ))
    }

    // MARK: - Installing

    /// Starts the install script and returns as soon as it is running.
    ///
    /// It outlives this process on purpose: a successful update kills the app partway through and
    /// reopens the copy it just wrote. The caller holds the returned process so it stays alive
    /// long enough to report a failure, which is the only outcome the app survives to see.
    ///
    /// `STATUS_APPS_SRC` is what makes the script fetch and reset instead of building the tree as
    /// it stands — run from a checkout it would otherwise rebuild the code already installed.
    public static func apply(
        in source: String,
        destination: String,
        logPath: String,
        onFailure: @escaping (String) -> Void
    ) throws -> Process {
        let script = (source as NSString).appendingPathComponent("scripts/install.sh")
        guard FileManager.default.isExecutableFile(atPath: script) else {
            throw ActionError.launchFailed("\(script) is missing or not executable")
        }

        let log = try openLog(at: logPath)

        let process = Process()
        // A login shell, as Rerun uses, so the build sees the PATH a terminal would.
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", ServerActions.shellQuote(script)]
        var environment = ProcessInfo.processInfo.environment
        environment["STATUS_APPS_SRC"] = source
        environment["STATUS_APPS_DEST"] = destination
        process.environment = environment
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { finished in
            try? log.close()
            guard finished.terminationStatus != 0 else { return }
            onFailure(tail(of: logPath))
        }

        try process.run()
        return process
    }

    // MARK: - Helpers

    private static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    private static func openLog(at path: String) throws -> FileHandle {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: path) else {
            throw ActionError.launchFailed("could not write \(path)")
        }
        return handle
    }

    /// The end of the log is where the failure is; the build output above it is noise.
    static func tail(of path: String, lines: Int = 6) -> String {
        let fallback = "The update failed. See \(path)."
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return fallback }
        let trailing = contents.split(separator: "\n").suffix(lines)
        return trailing.isEmpty ? fallback : trailing.joined(separator: "\n")
    }

    private static func firstLine(_ output: String, fallback: String) -> String {
        output.split(separator: "\n").first.map(String.init) ?? fallback
    }
}
