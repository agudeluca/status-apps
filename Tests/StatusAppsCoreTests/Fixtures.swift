import Foundation
@testable import StatusAppsCore

/// Captured from a real machine: the three Metro bundlers that prompted this app, alongside the
/// other processes that were listening at the same time and must stay out of the list.
enum Fixtures {

    static func process(
        pid: Int32 = 1,
        pgid: Int32 = 1,
        executablePath: String,
        arguments: [String] = [],
        workingDirectory: String = "",
        footprint: UInt64 = 1024,
        ports: [UInt16] = [8080],
        startedAt: Date = Date(timeIntervalSince1970: 1_788_000_000),
        cpuTime: UInt64 = 0,
        diskBytesRead: UInt64 = 0
    ) -> RunningProcess {
        RunningProcess(
            pid: pid,
            processGroupID: pgid,
            executablePath: executablePath,
            arguments: arguments,
            workingDirectory: workingDirectory,
            startedAt: startedAt,
            physicalFootprint: footprint,
            listeningPorts: ports,
            cpuTime: cpuTime,
            diskBytesRead: diskBytesRead
        )
    }

    // MARK: - Development servers

    static let metroInWorktree = process(
        pid: 36315,
        executablePath: "/Users/a/.nvm/versions/node/v20.20.0/bin/node",
        arguments: [
            "/Users/a/.nvm/versions/node/v20.20.0/bin/node",
            "/Users/a/projects/humand-mobile/.worktrees/oli-barge-in/node_modules/.bin/expo",
            "start", "-d", "--port", "8082",
        ],
        workingDirectory: "/Users/a/projects/humand-mobile/.worktrees/oli-barge-in",
        footprint: 4_949_000_000,
        ports: [8082]
    )

    static let metroInMainCheckout = process(
        pid: 5857,
        executablePath: "/Users/a/.nvm/versions/node/v20.20.0/bin/node",
        arguments: [
            "node", "/Users/a/projects/humand-mobile/node_modules/.bin/expo",
            "start", "--port", "8083",
        ],
        workingDirectory: "/Users/a/projects/humand-mobile",
        footprint: 4_737_000_000,
        ports: [8083]
    )

    static let bunAPI = process(
        pid: 64374,
        executablePath: "/Users/a/.bun/bin/bun",
        arguments: ["bun", "--env-file=../../.env", "src/index.ts"],
        workingDirectory: "/Users/a/projects/toto/apps/api",
        footprint: 68_000_000,
        ports: [3000]
    )

    static let postgres = process(
        pid: 76579,
        executablePath: "/opt/homebrew/Cellar/postgresql@18/18.3/bin/postgres",
        arguments: ["postgres", "-D", "/opt/homebrew/var/postgresql@18"],
        workingDirectory: "/opt/homebrew/var/postgresql@18",
        footprint: 17_000_000,
        ports: [54322]
    )

    // MARK: - Listening, but not development servers

    static let adb = process(
        pid: 918,
        executablePath: "/Users/a/Library/Android/sdk/platform-tools/adb",
        arguments: ["adb", "-L", "tcp:5037"],
        workingDirectory: "/",
        ports: [5037]
    )

    static let wineserver = process(
        pid: 64089,
        executablePath: "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wineserver",
        arguments: ["wineserver"],
        workingDirectory: "/private/tmp/.wine-501/server-100000f-1ad2007",
        ports: [4341, 27012, 27036]
    )

    static let logitech = process(
        pid: 810,
        executablePath: "/Library/Application Support/Logitech.localized/LogiOptionsPlus/logioptionsplus_agent.app/Contents/MacOS/logioptionsplus_agent",
        arguments: ["logioptionsplus_agent", "--launchd"],
        workingDirectory: "/",
        ports: [59869]
    )

    static let controlCenter = process(
        pid: 674,
        executablePath: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter",
        arguments: ["ControlCenter"],
        workingDirectory: "/",
        ports: [5000, 7000]
    )

    static let all: [RunningProcess] = [
        metroInWorktree, metroInMainCheckout, bunAPI, postgres,
        adb, wineserver, logitech, controlCenter,
    ]
}
