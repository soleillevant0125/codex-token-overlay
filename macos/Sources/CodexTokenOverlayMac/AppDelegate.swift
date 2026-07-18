import AppKit
import Foundation
import ServiceManagement
import CodexTokenCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let visibleFieldsKey = "visibleFields"
    private static let repositoryURL = URL(string: "https://github.com/soleillevant0125/codex-token-overlay")!

    private let routeMonitor = CodexIPCActiveThreadMonitor()
    private let routePreferenceTracker = ActiveThreadPreferenceTracker()
    private let logMonitor = TokenLogMonitor()
    private let pollQueue = DispatchQueue(
        label: "io.github.soleillevant0125.CodexTokenOverlay.logs",
        qos: .utility
    )

    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var summaryMenuItem: NSMenuItem!
    private var taskMenuItem: NSMenuItem!
    private var routeMenuItem: NSMenuItem!
    private var lockMenuItem: NSMenuItem!
    private var loginMenuItem: NSMenuItem!
    private var fieldMenuItems: [DisplayField: NSMenuItem] = [:]

    private var visibleFields: DisplayField = .defaultFields
    private var lastSnapshot: TokenSnapshot?
    private var lastRouteStatus = ActiveThreadRouteStatus(
        threadID: nil,
        activeWindowCount: 0,
        isConnected: false,
        version: 0,
        socketPath: nil,
        lastError: nil
    )
    private var pollInFlight = false
    private var isTaskLocked = false
    private var forceNextPoll = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        let savedFields = UserDefaults.standard.integer(forKey: Self.visibleFieldsKey)
        let restoredFields = DisplayField(rawValue: savedFields).intersection(.allFields)
        if !restoredFields.isEmpty {
            visibleFields = restoredFields
        }

        configureStatusItem()
        configureMenu()
        refreshFieldMenuStates()
        refreshLoginItemState()

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = 0.08
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        routeMonitor.stop()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshFieldMenuStates()
        refreshLoginItemState()
        updateMenu(snapshot: lastSnapshot, routeStatus: lastRouteStatus)
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "Token —"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            button.toolTip = L10n.waiting
        }
    }

    private func configureMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        summaryMenuItem = NSMenuItem(title: L10n.noTokenSnapshot, action: nil, keyEquivalent: "")
        summaryMenuItem.isEnabled = false
        menu.addItem(summaryMenuItem)

        taskMenuItem = NSMenuItem(title: "\(L10n.currentTask)：—", action: nil, keyEquivalent: "")
        taskMenuItem.isEnabled = false
        menu.addItem(taskMenuItem)

        routeMenuItem = NSMenuItem(title: L10n.ipcFallback, action: nil, keyEquivalent: "")
        routeMenuItem.isEnabled = false
        menu.addItem(routeMenuItem)
        menu.addItem(.separator())

        let fieldsItem = NSMenuItem(title: L10n.displayFields, action: nil, keyEquivalent: "")
        let fieldsMenu = NSMenu()
        for field in DisplayField.ordered {
            let item = NSMenuItem(
                title: L10n.fieldName(field),
                action: #selector(toggleField(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = field.rawValue
            fieldsMenu.addItem(item)
            fieldMenuItems[field] = item
        }
        fieldsItem.submenu = fieldsMenu
        menu.addItem(fieldsItem)

        lockMenuItem = NSMenuItem(
            title: L10n.lockTask,
            action: #selector(toggleTaskLock(_:)),
            keyEquivalent: ""
        )
        lockMenuItem.target = self
        menu.addItem(lockMenuItem)

        loginMenuItem = NSMenuItem(
            title: L10n.launchAtLogin,
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        loginMenuItem.target = self
        menu.addItem(loginMenuItem)
        menu.addItem(.separator())

        let openSessionsItem = NSMenuItem(
            title: L10n.openSessions,
            action: #selector(openSessionsDirectory(_:)),
            keyEquivalent: ""
        )
        openSessionsItem.target = self
        menu.addItem(openSessionsItem)

        let openProjectItem = NSMenuItem(
            title: L10n.openProject,
            action: #selector(openProjectPage(_:)),
            keyEquivalent: ""
        )
        openProjectItem.target = self
        menu.addItem(openProjectItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: L10n.quit,
            action: #selector(quitApplication(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func refresh() {
        guard !pollInFlight else {
            return
        }

        let routeStatus = routeMonitor.status()
        let preferredThreadID = routePreferenceTracker.preferredThreadID(for: routeStatus)
        let routeChanged = routeStatus.version != lastRouteStatus.version
        let forceFullScan = forceNextPoll || routeChanged
        let locked = isTaskLocked

        forceNextPoll = false
        lastRouteStatus = routeStatus
        pollInFlight = true

        pollQueue.async { [weak self] in
            guard let self else {
                return
            }

            self.logMonitor.pinActiveSession = locked
            self.logMonitor.preferredThreadID = locked ? nil : preferredThreadID
            let snapshot = self.logMonitor.poll(forceFullScan: forceFullScan)

            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                self.pollInFlight = false
                self.apply(snapshot: snapshot, routeStatus: routeStatus)
            }
        }
    }

    private func apply(snapshot: TokenSnapshot?, routeStatus: ActiveThreadRouteStatus) {
        lastSnapshot = snapshot

        if let snapshot {
            let title = TokenFormatter.statusTitle(snapshot: snapshot, fields: visibleFields)
            statusItem.button?.title = title.isEmpty ? "Token —" : title
            statusItem.button?.toolTip = TokenFormatter.fullSummary(snapshot: snapshot)
        } else {
            statusItem.button?.title = routeStatus.threadID == nil ? "Token —" : "Token …"
            statusItem.button?.toolTip = L10n.noTokenSnapshot
        }

        updateMenu(snapshot: snapshot, routeStatus: routeStatus)
    }

    private func updateMenu(snapshot: TokenSnapshot?, routeStatus: ActiveThreadRouteStatus) {
        if let snapshot {
            summaryMenuItem.title = TokenFormatter.fullSummary(snapshot: snapshot)
            taskMenuItem.title = "\(L10n.currentTask)：\(TokenFormatter.shortThreadID(snapshot.threadID))"
        } else {
            summaryMenuItem.title = L10n.noTokenSnapshot
            let routeThread = routeStatus.threadID.map(TokenFormatter.shortThreadID) ?? "—"
            taskMenuItem.title = "\(L10n.currentTask)：\(routeThread)"
        }

        routeMenuItem.title = routeStatus.isConnected ? L10n.ipcConnected : L10n.ipcFallback
        lockMenuItem.title = isTaskLocked ? L10n.lockedTask : L10n.lockTask
        lockMenuItem.state = isTaskLocked ? .on : .off
        lockMenuItem.isEnabled = snapshot != nil || isTaskLocked
    }

    private func refreshFieldMenuStates() {
        for (field, item) in fieldMenuItems {
            item.state = visibleFields.contains(field) ? .on : .off
        }
    }

    private func refreshLoginItemState() {
        loginMenuItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func toggleField(_ sender: NSMenuItem) {
        let field = DisplayField(rawValue: sender.tag)
        var nextFields = visibleFields
        if nextFields.contains(field) {
            nextFields.remove(field)
        } else {
            nextFields.insert(field)
        }

        guard !nextFields.isEmpty else {
            NSSound.beep()
            return
        }

        visibleFields = nextFields
        UserDefaults.standard.set(visibleFields.rawValue, forKey: Self.visibleFieldsKey)
        refreshFieldMenuStates()

        if let lastSnapshot {
            apply(snapshot: lastSnapshot, routeStatus: lastRouteStatus)
        }
    }

    @objc private func toggleTaskLock(_ sender: NSMenuItem) {
        isTaskLocked.toggle()
        forceNextPoll = true
        updateMenu(snapshot: lastSnapshot, routeStatus: lastRouteStatus)
        refresh()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            refreshLoginItemState()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.launchAtLoginFailed
            alert.informativeText = "\(error.localizedDescription)\n\n\(L10n.confirmSource)"
            alert.runModal()
            refreshLoginItemState()
        }
    }

    @objc private func openSessionsDirectory(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(URL(fileURLWithPath: logMonitor.sessionRoot, isDirectory: true))
    }

    @objc private func openProjectPage(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(Self.repositoryURL)
    }

    @objc private func quitApplication(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }
}
