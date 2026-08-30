import Foundation

/// Remembers how each server was launched, so one that has died can still be relaunched.
///
/// Without this, "rerun" could only restart something already running, which is the case where
/// it is least useful. This is the app's only persistent state.
public final class KnownServersStore {
    /// Enough to cover the projects in rotation without the menu growing unbounded.
    static let entryLimit = 20
    static let maximumAge: TimeInterval = 30 * 24 * 60 * 60

    private let fileURL: URL
    private var entries: [String: KnownServer]

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.entries = Self.load(from: self.fileURL)
    }

    public static func defaultFileURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("StatusApps/known.json")
    }

    /// Updates the record for every server currently running.
    public func record(_ servers: [DevServer], now: Date = Date()) {
        for server in servers {
            let known = KnownServer(server: server, lastSeen: now)
            entries[known.identity] = known
        }
        prune(now: now)
        save()
    }

    /// Servers seen before that are not running now, most recent first.
    public func recentlyStopped(excluding running: [DevServer]) -> [KnownServer] {
        let live = Set(running.map { KnownServer(server: $0).identity })
        return entries.values
            .filter { !live.contains($0.identity) }
            .sorted { $0.lastSeen > $1.lastSeen }
    }

    public func forget(_ known: KnownServer) {
        entries[known.identity] = nil
        save()
    }

    public func removeAll() {
        entries.removeAll()
        save()
    }

    // MARK: - Persistence

    private func prune(now: Date) {
        for (identity, entry) in entries where now.timeIntervalSince(entry.lastSeen) > Self.maximumAge {
            entries[identity] = nil
        }
        let excess = entries.count - Self.entryLimit
        guard excess > 0 else { return }
        for entry in entries.values.sorted(by: { $0.lastSeen < $1.lastSeen }).prefix(excess) {
            entries[entry.identity] = nil
        }
    }

    private static func load(from url: URL) -> [String: KnownServer] {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([KnownServer].self, from: data)
        else { return [:] }
        // A corrupt or outdated file is not worth surfacing; starting empty is recoverable.
        return Dictionary(stored.map { ($0.identity, $0) }, uniquingKeysWith: { $1 })
    }

    private func save() {
        let sorted = entries.values.sorted { $0.lastSeen > $1.lastSeen }
        guard let data = try? JSONEncoder().encode(sorted) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
