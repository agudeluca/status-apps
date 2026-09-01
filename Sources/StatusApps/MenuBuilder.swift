import AppKit
import StatusAppsCore

/// What the menu can ask the app to do. Passed in rather than reached for, so the builder stays
/// a pure function of its inputs and never touches the system itself.
struct MenuActions {
    var stop: (DevServer, Bool) -> Void
    var stopMany: ([DevServer]) -> Void
    var clean: (DevServer) -> Void
    var rerun: (DevServer) -> Void
    var rerunKnown: (KnownServer) -> Void
    var attach: (DevServer) -> Void
    var openBrowser: (UInt16) -> Void
    var reveal: (String) -> Void
    var forget: (KnownServer) -> Void
    var refresh: () -> Void
    var toggleLaunchAtLogin: () -> Void
    var quit: () -> Void
}

struct MenuContext {
    var servers: [DevServer]
    var recent: [KnownServer]
    var swap: SwapUsage?
    var tmuxAvailable: Bool
    var launchAtLogin: Bool?
    /// When each running server was last seen doing work, keyed by identity. Absent means the app
    /// has not watched it long enough to say.
    var lastUsed: [String: Date] = [:]
}

enum MenuBuilder {

    /// What shows in the menu bar itself: how many servers are up and what they cost together.
    static func statusTitle(servers: [DevServer]) -> String {
        guard !servers.isEmpty else { return "⇅0" }
        let total = servers.reduce(UInt64(0)) { $0 + $1.footprint }
        return "⇅\(servers.count)  \(Formatters.memory(total))"
    }

    static func populate(_ menu: NSMenu, context: MenuContext, actions: MenuActions) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        if context.servers.isEmpty {
            menu.addItem(NSMenuItem.label("No dev servers listening"))
        } else {
            menu.addItem(NSMenuItem.label(Formatters.serverRowHeader))
            for server in context.servers {
                menu.addItem(serverItem(server, context: context, actions: actions))
            }
        }

        if !context.servers.isEmpty {
            menu.addItem(.separator())
            menu.addItem(bulkStopItem(context.servers, actions: actions))
        }

        if !context.recent.isEmpty {
            menu.addItem(.separator())
            menu.addItem(recentItem(context.recent, tmuxAvailable: context.tmuxAvailable, actions: actions))
        }

        if let swap = context.swap {
            menu.addItem(.separator())
            let critical = swap.fraction >= 0.8
            menu.addItem(NSMenuItem.label(
                Formatters.swap(swap),
                color: critical ? .systemRed : .secondaryLabelColor
            ))
        }

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Refresh", handler: actions.refresh))

        if let launchAtLogin = context.launchAtLogin {
            let item = ClosureMenuItem(title: "Open at Login", handler: actions.toggleLaunchAtLogin)
            item.state = launchAtLogin ? .on : .off
            menu.addItem(item)
        }

        let quit = ClosureMenuItem(title: "Quit", handler: actions.quit)
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    // MARK: - Rows

    private static func serverItem(
        _ server: DevServer, context: MenuContext, actions: MenuActions
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: Formatters.serverRow(server, lastUsed: context.lastUsed[server.identity]),
            action: nil, keyEquivalent: ""
        ).monospaced()
        item.submenu = serverSubmenu(server, context: context, actions: actions)
        return item
    }

    private static func serverSubmenu(
        _ server: DevServer, context: MenuContext, actions: MenuActions
    ) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        if let port = server.primaryPort {
            submenu.addItem(ClosureMenuItem(title: "Open http://localhost:\(port)") {
                actions.openBrowser(port)
            })
        }

        submenu.addItem(.separator())
        submenu.addItem(ClosureMenuItem(title: "Stop") { actions.stop(server, false) })
        submenu.addItem(ClosureMenuItem(title: "Force kill (-9)") { actions.stop(server, true) })

        let clean = ClosureMenuItem(title: "Clean cache", enabled: server.kind.supportsCacheClean) {
            actions.clean(server)
        }
        if !server.kind.supportsCacheClean {
            clean.toolTip = "Only Metro has a known cache recipe."
        }
        submenu.addItem(clean)

        let rerun = ClosureMenuItem(title: "Rerun", enabled: context.tmuxAvailable) {
            actions.rerun(server)
        }
        let attach = ClosureMenuItem(title: "Attach (tmux)", enabled: context.tmuxAvailable) {
            actions.attach(server)
        }
        if !context.tmuxAvailable {
            let reason = "Requires tmux: brew install tmux"
            rerun.toolTip = reason
            attach.toolTip = reason
        }
        submenu.addItem(rerun)
        submenu.addItem(attach)

        submenu.addItem(.separator())
        submenu.addItem(NSMenuItem.label(
            "PID \(server.pid) · up \(Formatters.uptime(server.uptime))"
            + " · idle \(Formatters.idle(since: context.lastUsed[server.identity]))"
            + " · \(Formatters.ports(server.ports))"
        ))

        if !server.workingDirectory.isEmpty {
            let directory = server.workingDirectory
            submenu.addItem(ClosureMenuItem(title: "Reveal in Finder") { actions.reveal(directory) })
        }

        return submenu
    }

    /// Bulk stop is offered per runtime rather than as one blunt "kill everything": a list that
    /// mixes Metro bundlers with the Postgres you need running makes a single action a trap.
    private static func bulkStopItem(_ servers: [DevServer], actions: MenuActions) -> NSMenuItem {
        let groups = DevServerClassifier.groupedByKind(servers)

        guard groups.count > 1 else {
            return ClosureMenuItem(title: "Kill all (\(servers.count))") {
                actions.stopMany(servers)
            }
        }

        let item = NSMenuItem(title: "Kill…", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        for group in groups {
            submenu.addItem(
                ClosureMenuItem(title: "All \(group.kind.displayName) (\(group.servers.count))") {
                    actions.stopMany(group.servers)
                }
            )
        }

        submenu.addItem(.separator())
        submenu.addItem(ClosureMenuItem(title: "Everything (\(servers.count))") {
            actions.stopMany(servers)
        })

        item.submenu = submenu
        return item
    }

    private static func recentItem(
        _ recent: [KnownServer], tmuxAvailable: Bool, actions: MenuActions
    ) -> NSMenuItem {
        let item = NSMenuItem(title: "Recent (\(recent.count))", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        for known in recent {
            let entry = NSMenuItem(
                title: Formatters.recentRow(known), action: nil, keyEquivalent: ""
            )
            let entryMenu = NSMenu()
            entryMenu.autoenablesItems = false

            let rerun = ClosureMenuItem(title: "Rerun", enabled: tmuxAvailable) {
                actions.rerunKnown(known)
            }
            if !tmuxAvailable { rerun.toolTip = "Requires tmux: brew install tmux" }
            entryMenu.addItem(rerun)
            entryMenu.addItem(ClosureMenuItem(title: "Forget") { actions.forget(known) })
            entryMenu.addItem(.separator())

            entryMenu.addItem(NSMenuItem.label(known.workingDirectory))

            entry.submenu = entryMenu
            submenu.addItem(entry)
        }

        item.submenu = submenu
        return item
    }
}
