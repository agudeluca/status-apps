import Foundation

/// A process observed on the system, with no policy applied.
/// `ProcessScanner` produces these; `DevServerClassifier` decides which ones matter.
public struct RunningProcess: Codable, Equatable {
    public let pid: Int32
    public let processGroupID: Int32
    public let executablePath: String
    public let arguments: [String]
    public let workingDirectory: String
    public let startedAt: Date
    /// Bytes, from `ri_phys_footprint` — the figure Activity Monitor shows.
    public let physicalFootprint: UInt64
    public let listeningPorts: [UInt16]

    public init(
        pid: Int32,
        processGroupID: Int32,
        executablePath: String,
        arguments: [String],
        workingDirectory: String,
        startedAt: Date,
        physicalFootprint: UInt64,
        listeningPorts: [UInt16]
    ) {
        self.pid = pid
        self.processGroupID = processGroupID
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.startedAt = startedAt
        self.physicalFootprint = physicalFootprint
        self.listeningPorts = listeningPorts
    }

    public var executableName: String {
        (executablePath as NSString).lastPathComponent
    }
}

public enum DevServerKind: String, Codable, CaseIterable {
    case metro, node, bun, deno, python, ruby, java, postgres, redis, php

    public var displayName: String {
        switch self {
        case .metro: return "metro"
        case .node: return "node"
        case .bun: return "bun"
        case .deno: return "deno"
        case .python: return "python"
        case .ruby: return "ruby"
        case .java: return "java"
        case .postgres: return "postgres"
        case .redis: return "redis"
        case .php: return "php"
        }
    }

    /// Only Metro has a cache layout we understand well enough to clear safely.
    public var supportsCacheClean: Bool { self == .metro }
}

/// A running process that the classifier recognised as a development server.
public struct DevServer: Equatable {
    public let process: RunningProcess
    public let kind: DevServerKind
    public let label: String

    public init(process: RunningProcess, kind: DevServerKind, label: String) {
        self.process = process
        self.kind = kind
        self.label = label
    }

    public var pid: Int32 { process.pid }
    public var ports: [UInt16] { process.listeningPorts }
    public var primaryPort: UInt16? { process.listeningPorts.first }
    public var footprint: UInt64 { process.physicalFootprint }
    public var workingDirectory: String { process.workingDirectory }
    public var uptime: TimeInterval { Date().timeIntervalSince(process.startedAt) }
}

/// The last known state of a server, persisted so it can be relaunched after it dies.
public struct KnownServer: Codable, Equatable {
    public let label: String
    public let kind: DevServerKind
    public let workingDirectory: String
    public let arguments: [String]
    public let primaryPort: UInt16?
    public var lastSeen: Date

    public init(
        label: String,
        kind: DevServerKind,
        workingDirectory: String,
        arguments: [String],
        primaryPort: UInt16?,
        lastSeen: Date
    ) {
        self.label = label
        self.kind = kind
        self.workingDirectory = workingDirectory
        self.arguments = arguments
        self.primaryPort = primaryPort
        self.lastSeen = lastSeen
    }

    /// Identity across restarts: the same command in the same directory is the same server,
    /// even though its pid and port may change.
    ///
    /// Keyed on the arguments rather than the label, because one project can run several servers
    /// from the same directory — two `bun` entry points, or a bundler and an API side by side.
    public var identity: String {
        ([kind.rawValue, workingDirectory] + arguments).joined(separator: "\u{1}")
    }

    public init(server: DevServer, lastSeen: Date = Date()) {
        self.init(
            label: server.label,
            kind: server.kind,
            workingDirectory: server.workingDirectory,
            arguments: server.process.arguments,
            primaryPort: server.primaryPort,
            lastSeen: lastSeen
        )
    }
}
