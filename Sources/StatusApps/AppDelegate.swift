import AppKit
import ServiceManagement
import StatusAppsCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    /// Fast enough to feel live, cheap enough to ignore: a scan is a few milliseconds.
    private static let refreshInterval: TimeInterval = 5

    /// A fetch over the network, against a repository that changes a few times a week at most.
    private static let updateCheckInterval: TimeInterval = 6 * 60 * 60

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let store = KnownServersStore()
    private var timer: Timer?
    private var servers: [DevServer] = []

    private let updateSource = SelfUpdate.bundledSourcePath
    private var updateState: UpdateState = .unavailable
    private var updateTimer: Timer?
    private var updateProcess: Process?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

        menu.delegate = self
        statusItem.menu = menu

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        checkForUpdate()
        updateTimer = Timer.scheduledTimer(
            withTimeInterval: Self.updateCheckInterval, repeats: true
        ) { [weak self] _ in
            self?.checkForUpdate()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        updateTimer?.invalidate()
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
            launchAtLogin: launchAtLoginState(),
            update: updateState
        )
        MenuBuilder.populate(menu, context: context, actions: makeActions())
    }

    // MARK: - Actions

    private func makeActions() -> MenuActions {
        MenuActions(
            stop: { [weak self] server, force in
                self?.perform("Stop") { try ServerActions.stop(server, force: force) }
            },
            stopMany: { [weak self] servers in
                self?.confirmAndStop(servers)
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
            checkForUpdate: { [weak self] in self?.checkForUpdate() },
            installUpdate: { [weak self] in self?.installUpdate() },
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

    /// Asks before a bulk stop, listing the processes by name rather than only their count, and
    /// defaults to Cancel so a stray click cannot take down a row of servers.
    private func confirmAndStop(_ servers: [DevServer]) {
        guard !servers.isEmpty else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = servers.count == 1
            ? "Stop 1 process?"
            : "Stop \(servers.count) processes?"
        alert.informativeText = Formatters.bulkStopSummary(servers)
        alert.addButton(withTitle: "Cancel")
        let stopButton = alert.addButton(withTitle: "Stop")
        stopButton.hasDestructiveAction = true

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = ServerActions.stop(servers)
            DispatchQueue.main.async { [weak self] in
                self?.refresh()
                guard !outcome.isCompleteSuccess else { return }
                self?.presentBulkFailure(outcome)
            }
        }
    }

    private func presentBulkFailure(_ outcome: BulkStopOutcome) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Stopped \(outcome.stopped) of \(outcome.requested)"
        alert.informativeText = outcome.failures.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func presentFailure(action: String, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(action) failed"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Updating

    /// Kept off the scan timer: this one talks to the network and spawns git. The menu draws
    /// whatever the last check left behind, so opening it never waits.
    private func checkForUpdate() {
        guard let source = updateSource, updateState != .inProgress else { return }
        DispatchQueue.global(qos: .utility).async {
            let state = SelfUpdate.check(in: source)
            DispatchQueue.main.async { [weak self] in
                // An update started while the check was in flight outranks its result.
                guard self?.updateState != .inProgress else { return }
                self?.updateState = state
            }
        }
    }

    /// Asks first, because the app is about to be rebuilt, killed and reopened under the user.
    private func installUpdate() {
        guard let source = updateSource,
              case .available(let update) = updateState,
              update.blocked == nil
        else { return }

        let alert = NSAlert()
        alert.messageText = "Update Status Apps?"
        alert.informativeText = Formatters.updateSummary(update, source: source)
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Update")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        updateState = .inProgress
        do {
            updateProcess = try SelfUpdate.apply(
                in: source,
                // Wherever this copy lives, so the update lands on top of it rather than in
                // /Applications by default.
                destination: Bundle.main.bundleURL.deletingLastPathComponent().path,
                logPath: SelfUpdate.defaultLogURL().path,
                onFailure: { reason in
                    DispatchQueue.main.async { [weak self] in self?.updateState = .failed(reason) }
                }
            )
        } catch {
            updateState = .failed(error.localizedDescription)
            presentFailure(action: "Update", error: error)
        }
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
            presentFailure(action: "Open at Login", error: error)
        }
    }
}

private enum CleanResult: LocalizedError {
    case nothingToRemove

    var errorDescription: String? {
        "No Metro caches to remove."
    }
}
