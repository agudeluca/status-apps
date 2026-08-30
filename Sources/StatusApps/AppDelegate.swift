import AppKit
import ServiceManagement
import StatusAppsCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    /// Fast enough to feel live, cheap enough to ignore: a scan is a few milliseconds.
    private static let refreshInterval: TimeInterval = 5

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let store = KnownServersStore()
    private var timer: Timer?
    private var servers: [DevServer] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

        menu.delegate = self
        statusItem.menu = menu

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    // MARK: - Refreshing

    /// Rescans and updates the menu bar title. The menu itself is rebuilt on open.
    private func refresh() {
        servers = DevServerClassifier.classify(ProcessScanner.scanListeningProcesses())
        store.record(servers)
        statusItem.button?.title = MenuBuilder.statusTitle(servers: servers)
    }

    /// AppKit calls this before the menu is shown, which is the only moment its contents matter.
    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        let context = MenuContext(
            servers: servers,
            recent: store.recentlyStopped(excluding: servers),
            swap: SystemMemory.swapUsage(),
            tmuxAvailable: ServerActions.tmuxPath != nil,
            launchAtLogin: launchAtLoginState()
        )
        MenuBuilder.populate(menu, context: context, actions: makeActions())
    }

    // MARK: - Actions

    private func makeActions() -> MenuActions {
        MenuActions(
            stop: { [weak self] server, force in
                self?.perform("Stop") { try ServerActions.stop(server, force: force) }
            },
            clean: { [weak self] server in
                self?.perform("Clean cache") {
                    let removed = ServerActions.cleanCaches(for: server)
                    if removed.isEmpty { throw CleanResult.nothingToRemove }
                }
            },
            rerun: { [weak self] server in
                self?.perform("Rerun") { try ServerActions.rerun(server) }
            },
            rerunKnown: { [weak self] known in
                self?.perform("Rerun") { try ServerActions.rerun(known) }
            },
            attach: { [weak self] server in
                let session = ServerActions.sessionName(for: server)
                self?.perform("Attach") { try ServerActions.attach(session: session) }
            },
            openBrowser: { ServerActions.openInBrowser(port: $0) },
            reveal: { ServerActions.revealInFinder(path: $0) },
            forget: { [weak self] known in
                self?.store.forget(known)
                self?.refresh()
            },
            refresh: { [weak self] in self?.refresh() },
            toggleLaunchAtLogin: { [weak self] in self?.toggleLaunchAtLogin() },
            quit: { NSApp.terminate(nil) }
        )
    }

    /// Runs a mutating action off the main thread — cache cleaning walks the filesystem and tmux
    /// spawns a process — then refreshes, reporting failures instead of swallowing them.
    private func perform(_ name: String, _ work: @escaping () throws -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try work()
                DispatchQueue.main.async { [weak self] in self?.refresh() }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.refresh()
                    self?.presentFailure(action: name, error: error)
                }
            }
        }
    }

    private func presentFailure(action: String, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(action) no se completó"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Launch at login

    /// `nil` when the executable is not running from an app bundle, where the API does not apply.
    private func launchAtLoginState() -> Bool? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return SMAppService.mainApp.status == .enabled
    }

    private func toggleLaunchAtLogin() {
        guard let enabled = launchAtLoginState() else { return }
        do {
            if enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            presentFailure(action: "Abrir al iniciar sesión", error: error)
        }
    }
}

private enum CleanResult: LocalizedError {
    case nothingToRemove

    var errorDescription: String? {
        "No había caches de Metro para borrar."
    }
}
