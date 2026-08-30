import Darwin
import Foundation

public struct BulkStopOutcome: Equatable {
    public let requested: Int
    public let failures: [String]

    public init(requested: Int, failures: [String]) {
        self.requested = requested
        self.failures = failures
    }

    public var stopped: Int { requested - failures.count }
    public var isCompleteSuccess: Bool { failures.isEmpty }
}

public enum ActionError: LocalizedError {
    case tmuxUnavailable
    case signalFailed(String)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .tmuxUnavailable:
            return "tmux is not installed. Install it with `brew install tmux`."
        case .signalFailed(let reason):
            return "Could not stop the process: \(reason)"
        case .launchFailed(let reason):
            return "Could not start the session: \(reason)"
        }
    }
}

/// The only module that shells out. Everything here is triggered by the user, never by the timer.
public enum ServerActions {

    // MARK: - Stopping

    /// Signals the whole process group.
    ///
    /// A Metro bundler is `yarn start` spawning `node`; the listener is the child, so signalling
    /// only its pid would leave the parent behind holding the port.
    public static func stop(_ server: DevServer, force: Bool = false) throws {
        let signal = force ? SIGKILL : SIGTERM
        let group = server.process.processGroupID

        // Signalling our own group would take the app down with the server.
        if group > 1, group != getpgrp(), kill(-group, signal) == 0 { return }
        // The group may already be gone, or belong to a session we cannot signal; try the pid.
        if kill(server.pid, signal) == 0 { return }
        if errno == ESRCH { return }  // already dead, which is what we wanted
        throw ActionError.signalFailed(String(cString: strerror(errno)))
    }

    /// Stops several servers, carrying on past failures so one stubborn process does not strand
    /// the rest, and reporting what did not die.
    @discardableResult
    public static func stop(_ servers: [DevServer], force: Bool = false) -> BulkStopOutcome {
        var failures: [String] = []
        for server in servers {
            do {
                try stop(server, force: force)
            } catch {
                failures.append("\(server.label): \(error.localizedDescription)")
            }
        }
        return BulkStopOutcome(requested: servers.count, failures: failures)
    }

    public static func isRunning(pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    // MARK: - Cache cleaning

    /// Clears the caches a Metro bundler leaves behind. Returns what it actually removed, so the
    /// caller can report honestly rather than claiming more than happened.
    @discardableResult
    public static func cleanCaches(for server: DevServer) -> [String] {
        guard server.kind.supportsCacheClean else { return [] }
        var removed: [String] = []
        let fileManager = FileManager.default

        let temporaryDirectory = NSTemporaryDirectory()
        let prefixes = ["metro-", "haste-map-", "react-native-packager-", "react-"]
        if let entries = try? fileManager.contentsOfDirectory(atPath: temporaryDirectory) {
            for entry in entries where prefixes.contains(where: entry.hasPrefix) {
                let path = (temporaryDirectory as NSString).appendingPathComponent(entry)
                if (try? fileManager.removeItem(atPath: path)) != nil { removed.append(entry) }
            }
        }

        let expoCache = (server.workingDirectory as NSString).appendingPathComponent(".expo")
        if !server.workingDirectory.isEmpty, fileManager.fileExists(atPath: expoCache),
           (try? fileManager.removeItem(atPath: expoCache)) != nil {
            removed.append(".expo")
        }

        // watchman is optional; without it the rest of the clean still stands.
        if let watchman = which("watchman"), !server.workingDirectory.isEmpty {
            _ = try? run(watchman, ["watch-del", server.workingDirectory])
            removed.append("watchman watch")
        }

        return removed
    }

    // MARK: - tmux sessions

    public static var tmuxPath: String? { which("tmux") }

    /// Unique per server, not per label: two servers can run from one directory under the same
    /// label, and colliding names would make a rerun of one tear down the other.
    public static func sessionName(
        for label: String, kind: DevServerKind, port: UInt16?, workingDirectory: String = ""
    ) -> String {
        // tmux treats "." and ":" as address separators, so they cannot appear in a name.
        let sanitized = String(label.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let suffix = port.map(String.init) ?? shortHash(workingDirectory)
        return "\(kind.rawValue)-\(sanitized)-\(suffix)"
    }

    public static func sessionName(for server: DevServer) -> String {
        sessionName(
            for: server.label, kind: server.kind,
            port: server.primaryPort, workingDirectory: server.workingDirectory
        )
    }

    public static func sessionName(for known: KnownServer) -> String {
        sessionName(
            for: known.label, kind: known.kind,
            port: known.primaryPort, workingDirectory: known.workingDirectory
        )
    }

    /// FNV-1a, purely to keep session names short and stable when there is no port to use.
    static func shortHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return String(hash % 0xffffff, radix: 16)
    }

    /// Relaunches a server in a detached tmux session, replacing any session of the same name.
    ///
    /// The command runs under a login shell so it picks up nvm and the user's PATH, and the pane
    /// drops to an interactive shell afterwards so a crash leaves its output there to read.
    public static func rerun(
        label: String,
        kind: DevServerKind,
        workingDirectory: String,
        arguments: [String],
        port: UInt16?
    ) throws {
        guard let tmux = tmuxPath else { throw ActionError.tmuxUnavailable }
        guard !arguments.isEmpty else { throw ActionError.launchFailed("no recorded command") }

        let session = sessionName(
            for: label, kind: kind, port: port, workingDirectory: workingDirectory
        )
        _ = try? run(tmux, ["kill-session", "-t", session])

        let command = arguments.map(shellQuote).joined(separator: " ")
        let script = "/bin/zsh -l -c \(shellQuote(command)); exec /bin/zsh -l"

        var options = ["new-session", "-d", "-s", session]
        if !workingDirectory.isEmpty { options += ["-c", workingDirectory] }
        options.append(script)

        let result = try run(tmux, options)
        guard result.status == 0 else {
            throw ActionError.launchFailed(result.output.isEmpty ? "tmux exited \(result.status)" : result.output)
        }
    }

    public static func rerun(_ server: DevServer) throws {
        try rerun(
            label: server.label,
            kind: server.kind,
            workingDirectory: server.workingDirectory,
            arguments: server.process.arguments,
            port: server.primaryPort
        )
    }

    public static func rerun(_ known: KnownServer) throws {
        try rerun(
            label: known.label,
            kind: known.kind,
            workingDirectory: known.workingDirectory,
            arguments: known.arguments,
            port: known.primaryPort
        )
    }

    public static func hasSession(named session: String) -> Bool {
        guard let tmux = tmuxPath else { return false }
        return (try? run(tmux, ["has-session", "-t", session]))?.status == 0
    }

    /// Opens Terminal.app attached to the session.
    public static func attach(session: String) throws {
        guard tmuxPath != nil else { throw ActionError.tmuxUnavailable }
        let script = """
        tell application "Terminal"
            activate
            do script "tmux attach -t \(session)"
        end tell
        """
        let result = try run("/usr/bin/osascript", ["-e", script])
        guard result.status == 0 else { throw ActionError.launchFailed(result.output) }
    }

    public static func openInBrowser(port: UInt16) {
        guard let url = URL(string: "http://localhost:\(port)") else { return }
        _ = try? run("/usr/bin/open", [url.absoluteString])
    }

    public static func revealInFinder(path: String) {
        guard !path.isEmpty else { return }
        _ = try? run("/usr/bin/open", [path])
    }

    // MARK: - Shell helpers

    struct CommandResult {
        let status: Int32
        let output: String
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return CommandResult(status: process.terminationStatus, output: output)
    }

    /// tmux and watchman live in Homebrew paths that a GUI app does not inherit.
    static func which(_ tool: String) -> String? {
        let candidates = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        for directory in candidates {
            let path = (directory as NSString).appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
