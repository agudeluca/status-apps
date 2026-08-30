import AppKit
import StatusAppsCore

/// What the menu can ask the app to do. Passed in rather than reached for, so the builder stays
/// a pure function of its inputs and never touches the system itself.
struct MenuActions {
    var stop: (DevServer, Bool) -> Void
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
}

enum MenuBuilder {

    private static let portColumn = 8
    private static let memoryColumn = 7

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
            menu.addItem(NSMenuItem.label("Ningún dev server escuchando"))
        } else {
            menu.addItem(NSMenuItem.label(
                Formatters.pad("PUERTO", to: portColumn) + Formatters.pad("MEM", to: memoryColumn) + "PROCESO"
            ))
            for server in context.servers {
                menu.addItem(serverItem(server, context: context, actions: actions))
            }
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
        menu.addItem(ClosureMenuItem(title: "Refrescar", handler: actions.refresh))

        if let launchAtLogin = context.launchAtLogin {
            let item = ClosureMenuItem(title: "Abrir al iniciar sesión", handler: actions.toggleLaunchAtLogin)
            item.state = launchAtLogin ? .on : .off
            menu.addItem(item)
        }

        let quit = ClosureMenuItem(title: "Salir", handler: actions.quit)
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    // MARK: - Rows

    private static func serverItem(
        _ server: DevServer, context: MenuContext, actions: MenuActions
    ) -> NSMenuItem {
        let port = server.primaryPort.map { ":\($0)" } ?? "—"
        let title = Formatters.pad(port, to: portColumn)
            + Formatters.pad(Formatters.memory(server.footprint), to: memoryColumn)
            + "\(server.kind.displayName) — \(server.label)"

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "").monospaced()
        item.submenu = serverSubmenu(server, context: context, actions: actions)
        return item
    }

    private static func serverSubmenu(
        _ server: DevServer, context: MenuContext, actions: MenuActions
    ) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        if let port = server.primaryPort {
            submenu.addItem(ClosureMenuItem(title: "Abrir http://localhost:\(port)") {
                actions.openBrowser(port)
            })
        }

        submenu.addItem(.separator())
        submenu.addItem(ClosureMenuItem(title: "Stop") { actions.stop(server, false) })
        submenu.addItem(ClosureMenuItem(title: "Forzar kill (-9)") { actions.stop(server, true) })

        let clean = ClosureMenuItem(title: "Clean cache", enabled: server.kind.supportsCacheClean) {
            actions.clean(server)
        }
        if !server.kind.supportsCacheClean {
            clean.toolTip = "Solo Metro tiene una receta de limpieza conocida."
        }
        submenu.addItem(clean)

        let rerun = ClosureMenuItem(title: "Rerun", enabled: context.tmuxAvailable) {
            actions.rerun(server)
        }
        let attach = ClosureMenuItem(title: "Attach (tmux)", enabled: context.tmuxAvailable) {
            actions.attach(server)
        }
        if !context.tmuxAvailable {
            let reason = "Requiere tmux: brew install tmux"
            rerun.toolTip = reason
            attach.toolTip = reason
        }
        submenu.addItem(rerun)
        submenu.addItem(attach)

        submenu.addItem(.separator())
        submenu.addItem(NSMenuItem.label(
            "PID \(server.pid) · up \(Formatters.uptime(server.uptime)) · \(Formatters.ports(server.ports))"
        ))

        if !server.workingDirectory.isEmpty {
            let directory = server.workingDirectory
            submenu.addItem(ClosureMenuItem(title: "Abrir carpeta") { actions.reveal(directory) })
        }

        return submenu
    }

    private static func recentItem(
        _ recent: [KnownServer], tmuxAvailable: Bool, actions: MenuActions
    ) -> NSMenuItem {
        let item = NSMenuItem(title: "Recientes (\(recent.count))", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        for known in recent {
            let port = known.primaryPort.map { " :\($0)" } ?? ""
            let entry = NSMenuItem(
                title: "\(known.kind.displayName) — \(known.label)\(port)", action: nil, keyEquivalent: ""
            )
            let entryMenu = NSMenu()
            entryMenu.autoenablesItems = false

            let rerun = ClosureMenuItem(title: "Rerun", enabled: tmuxAvailable) {
                actions.rerunKnown(known)
            }
            if !tmuxAvailable { rerun.toolTip = "Requiere tmux: brew install tmux" }
            entryMenu.addItem(rerun)
            entryMenu.addItem(ClosureMenuItem(title: "Olvidar") { actions.forget(known) })
            entryMenu.addItem(.separator())

            entryMenu.addItem(NSMenuItem.label(known.workingDirectory))

            entry.submenu = entryMenu
            submenu.addItem(entry)
        }

        item.submenu = submenu
        return item
    }
}
