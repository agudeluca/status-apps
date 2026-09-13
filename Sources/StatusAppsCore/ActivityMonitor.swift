import Foundation

/// Decides which servers are doing work, rather than merely existing.
///
/// `uptime` answers "how long has this been running", which is the wrong question: the three
/// Metro bundlers that prompted this app had been up for ten days *and* untouched for six. The
/// difference between those two numbers is the whole signal.
///
/// The counters behind it — CPU nanoseconds and bytes read from disk — are cumulative since
/// launch, so a single reading says nothing. Only the difference between two scans is a rate,
/// which is why this holds state instead of being a free function.
///
/// A note on what was *not* used. Counting established TCP connections is tempting and free, from
/// the same descriptor walk `ProcessScanner.listeningPorts` already does. It does not work.
/// Measured on a real machine, an idle bundler held six established sockets at 0.01% CPU: browser
/// tabs and simulators keep connections open indefinitely. That count measures whether somebody is
/// attached, not whether anything is happening.
public final class ActivityMonitor {

    /// What counts as work in one sample window.
    ///
    /// Calibrated against a real machine, where the separation turned out to be wide enough that
    /// the exact figures barely matter: every idle server sat at 0.00–0.01% of a core and read
    /// zero bytes, while the one bundler actually rebuilding hit 1.79% and read 55 MB. The CPU
    /// threshold sits ~20x above that noise floor and ~9x below the active case.
    ///
    /// It leans towards over-reporting activity on purpose. Calling a busy server idle invites
    /// killing something in use; calling an idle server busy merely leaves it in the list one
    /// more window.
    public struct Thresholds {
        /// Fraction of one core, averaged over the window.
        public var cpuFraction: Double
        /// Bytes read from disk during the window. A bundler that rebuilds reads its sources;
        /// a server answering from an in-memory cache does not, which is why CPU comes first
        /// and this is only the second chance to notice.
        public var diskBytes: UInt64

        public init(cpuFraction: Double = 0.002, diskBytes: UInt64 = 512 * 1024) {
            self.cpuFraction = cpuFraction
            self.diskBytes = diskBytes
        }
    }

    /// Two scans landing in the same instant would divide by ~zero and read as a burst of work.
    /// `AppDelegate` refreshes on a timer *and* when the menu opens, so this happens in practice.
    /// Below this, the previous sample is kept rather than replaced, and the next comparison
    /// simply spans a longer window.
    static let minimumWindow: TimeInterval = 1

    private struct Sample {
        let startedAt: Date
        let cpuTime: UInt64
        let diskBytesRead: UInt64
        let takenAt: Date
    }

    private let thresholds: Thresholds
    private var samples: [Int32: Sample] = [:]

    public init(thresholds: Thresholds = Thresholds()) {
        self.thresholds = thresholds
    }

    /// The identities of the servers that did measurable work since the previous scan.
    ///
    /// A server seen for the first time is never reported: with no baseline there is no rate, and
    /// guessing would put a fake "active" on every server the moment the app launches.
    public func activeIdentities(among servers: [DevServer], now: Date = Date()) -> Set<String> {
        var active: Set<String> = []
        var live: Set<Int32> = []

        for server in servers {
            live.insert(server.pid)
            let current = Sample(
                startedAt: server.process.startedAt,
                cpuTime: server.process.cpuTime,
                diskBytesRead: server.process.diskBytesRead,
                takenAt: now
            )

            // A recycled pid is a different process wearing the same number; its counters restart,
            // so comparing across it would report an enormous negative or positive delta.
            guard let previous = samples[server.pid], previous.startedAt == current.startedAt else {
                samples[server.pid] = current
                continue
            }

            let elapsed = now.timeIntervalSince(previous.takenAt)
            guard elapsed >= Self.minimumWindow else { continue }

            samples[server.pid] = current
            if didWork(from: previous, to: current, over: elapsed) {
                active.insert(server.identity)
            }
        }

        // Baselines for processes that have gone are dead weight, and keeping them would let a
        // recycled pid match against a stale entry.
        samples = samples.filter { live.contains($0.key) }
        return active
    }

    private func didWork(from before: Sample, to after: Sample, over elapsed: TimeInterval) -> Bool {
        // These counters only climb. A drop means the reading cannot be trusted, so claim nothing.
        guard after.cpuTime >= before.cpuTime, after.diskBytesRead >= before.diskBytesRead else {
            return false
        }

        let nanoseconds = Double(after.cpuTime - before.cpuTime)
        if nanoseconds / (elapsed * 1_000_000_000) >= thresholds.cpuFraction { return true }
        return after.diskBytesRead - before.diskBytesRead >= thresholds.diskBytes
    }
}
