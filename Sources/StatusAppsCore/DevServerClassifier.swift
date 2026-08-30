import Foundation

/// Decides which listening processes are development servers, and what to call them.
///
/// Pure input-to-output: it never touches the system. This is the module that changes when a new
/// runtime shows up, which is why it is kept apart from scanning and from the menu.
public enum DevServerClassifier {

    /// Runtimes worth listing. An allowlist rather than a denylist, so an app that starts
    /// listening on a port tomorrow stays out without anyone maintaining an exclusion list.
    static let allowedExecutables: [String: DevServerKind] = [
        "node": .node,
        "bun": .bun,
        "deno": .deno,
        "python": .python,
        "ruby": .ruby,
        "java": .java,
        "postgres": .postgres,
        "redis-server": .redis,
        "php": .php,
    ]

    /// Tools recognised from the argument vector, for processes whose executable alone is not
    /// enough — a Metro bundler is just `node` until you look at what it is running.
    static let toolMarkers: Set<String> = [
        "expo", "metro", "vite", "next", "webpack", "rails", "uvicorn", "gunicorn",
    ]

    public static func classify(_ processes: [RunningProcess]) -> [DevServer] {
        processes
            .compactMap { process in
                guard let kind = kind(for: process) else { return nil }
                return DevServer(process: process, kind: kind, label: label(for: process))
            }
            .sorted { $0.footprint > $1.footprint }
    }

    /// Servers bucketed by runtime, biggest group first, so a bulk action can offer "every Metro"
    /// without offering to take Postgres down with it.
    public static func groupedByKind(_ servers: [DevServer]) -> [(kind: DevServerKind, servers: [DevServer])] {
        Dictionary(grouping: servers, by: \.kind)
            .map { (kind: $0.key, servers: $0.value) }
            .sorted {
                $0.servers.count != $1.servers.count
                    ? $0.servers.count > $1.servers.count
                    : $0.kind.rawValue < $1.kind.rawValue
            }
    }

    // MARK: - Kind

    static func kind(for process: RunningProcess) -> DevServerKind? {
        let markers = matchedMarkers(in: process.arguments)
        if markers.contains("expo") || markers.contains("metro") { return .metro }

        if let kind = allowedExecutables[normalize(process.executableName)] { return kind }
        // Homebrew's Python runs from `Python.app/Contents/MacOS/Python`, so the path says
        // "Python" while argv[0] says "python3". Either one is good enough to recognise it.
        if let launcher = process.arguments.first,
           let kind = allowedExecutables[normalize((launcher as NSString).lastPathComponent)] {
            return kind
        }

        // A recognised tool run through an unlisted interpreter still counts.
        return markers.isEmpty ? nil : .node
    }

    /// Runtimes ship under names that carry their version and their own capitalisation:
    /// `Python`, `python3.14`, `php8.2`, `node20`. Compare them stripped of both.
    static func normalize(_ executableName: String) -> String {
        let lowercased = executableName.lowercased()
        let base = lowercased.reversed().drop { $0.isNumber || $0 == "." }.reversed()
        // A name made entirely of digits keeps its digits rather than becoming empty.
        return base.isEmpty ? lowercased : String(base)
    }

    /// A marker matches a whole path component, never a bare substring: `/node_modules/.bin/expo`
    /// and `/node_modules/metro/src/cli.js` match, a project directory called `nextcloud` does not.
    static func matchedMarkers(in arguments: [String]) -> Set<String> {
        var found = Set<String>()
        for argument in arguments {
            for component in argument.split(separator: "/") {
                let name = component.split(separator: ".").first.map(String.init) ?? String(component)
                if toolMarkers.contains(name) { found.insert(name) }
            }
        }
        return found
    }

    // MARK: - Label

    /// A name you can tell apart in a menu: the worktree if there is one, otherwise the project
    /// directory, falling back to the executable when the working directory says nothing useful.
    static func label(for process: RunningProcess) -> String {
        label(workingDirectory: process.workingDirectory, executableName: process.executableName)
    }

    static func label(workingDirectory: String, executableName: String) -> String {
        let directory = workingDirectory.trimmingCharacters(in: .whitespaces)

        if let range = directory.range(of: "/.worktrees/") {
            let repository = (String(directory[..<range.lowerBound]) as NSString).lastPathComponent
            let worktree = directory[range.upperBound...].split(separator: "/").first.map(String.init)
            if !repository.isEmpty, let worktree, !worktree.isEmpty {
                return "\(repository)/\(worktree)"
            }
        }

        let base = (directory as NSString).lastPathComponent
        if directory.isEmpty || directory == "/" || base.isEmpty { return executableName }
        return base
    }
}
