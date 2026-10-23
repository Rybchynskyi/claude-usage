import AppKit
import ServiceManagement

final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let queue = DispatchQueue(label: "claude-usage.fetch")
    private let refreshInterval: TimeInterval = 180

    private let sleepGuard = SleepGuard()
    private var snapshot: UsageSnapshot?
    private var lastError: String?
    private var isFetching = false
    private var timer: Timer?

    private lazy var clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private lazy var clockWithDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "uk_UA")
        formatter.setLocalizedDateFormatFromTemplate("EEE HH:mm")
        return formatter
    }()

    override init() {
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        sleepGuard.onChange = { [weak self] in self?.render() }
        sleepGuard.restoreIfStranded()
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.toolTip = "Ліміти Claude Code"
        render()
        refresh()

        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // Sleeping through a reset window is the main way the display goes stale.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refreshNow),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    // MARK: - Fetching

    @objc private func refreshNow() { refresh(force: true) }

    private func refresh(force: Bool = false) {
        if isFetching { return }
        if !force, let snapshot, Date().timeIntervalSince(snapshot.fetchedAt) < 20 { return }
        isFetching = true
        queue.async { [weak self] in
            let result = Result { try UsageAPI.fetch() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isFetching = false
                switch result {
                case .success(let snapshot):
                    self.snapshot = snapshot
                    self.lastError = nil
                case .failure(let error):
                    self.lastError = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                }
                self.render()
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
        refresh()
    }

    // MARK: - Menu bar

    private func render() {
        guard let button = statusItem.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

        guard let window = snapshot?.binding else {
            button.image = ClaudeMark.image(color: lastError == nil ? Brand.kraft : Brand.clay,
                                            badge: sleepGuard.isActive)
            button.attributedTitle = NSAttributedString(
                string: lastError == nil ? " …" : " ⚠",
                attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
            button.toolTip = lastError ?? "Завантаження…"
            return
        }

        let severity = Severity(percentLeft: window.percentLeft)
        button.image = ClaudeMark.image(color: severity.menuBarColor, badge: sleepGuard.isActive)
        button.attributedTitle = NSAttributedString(
            string: " \(Int(window.percentLeft.rounded()))%",
            attributes: [.font: font,
                         .foregroundColor: severity == .normal
                             ? NSColor.labelColor : severity.menuBarColor])
        button.toolTip = tooltip()
        rebuildMenu()
    }

    private func tooltip() -> String {
        var lines: [String] = []
        if let snapshot {
            lines.append("Claude Code — залишилось:")
            lines += snapshot.windows.map { "\($0.name): \(Int($0.percentLeft.rounded()))%" }
        } else {
            lines.append(lastError ?? "Завантаження…")
        }
        if sleepGuard.isActive {
            lines.append("Сон заборонено · \(sleepGuard.remainingDescription)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Dropdown

    private func rebuildMenu() {
        menu.removeAllItems()
        menu.addItem(viewItem(panel()))

        if let snapshot {
            let active = snapshot.weeklyBreakdown.filter { $0.percent > 0 }
            if !active.isEmpty {
                let header = NSMenuItem(title: "Тиждень за джерелами", action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                for row in active.sorted(by: { $0.percent > $1.percent }) {
                    submenu.addItem(viewItem(InfoRowView(
                        title: row.name, trailing: "\(Int(row.percent.rounded()))%")))
                }
                header.submenu = submenu
                menu.addItem(header)
                menu.addItem(.separator())
            }
        }

        let sleepItem = NSMenuItem(
            title: sleepGuard.isActive
                ? "Не засинати · \(sleepGuard.remainingDescription)"
                : "Не засинати",
            action: nil, keyEquivalent: "")
        sleepItem.state = sleepGuard.isActive ? .on : .off
        sleepItem.submenu = sleepSubmenu()
        menu.addItem(sleepItem)
        menu.addItem(.separator())

        let updated = snapshot.map { "Оновити · дані за \(clock.string(from: $0.fetchedAt))" }
            ?? "Оновити"
        let refreshItem = NSMenuItem(title: updated, action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let openItem = NSMenuItem(title: "Сторінка використання…",
                                  action: #selector(openUsagePage), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let loginItem = NSMenuItem(title: "Запускати при вході",
                                   action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Вийти", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func panel() -> UsagePanelView {
        let badge = Credentials.subscriptionType?.uppercased()

        guard let snapshot else {
            return UsagePanelView(badge: badge, rows: [], footer: nil,
                                  message: lastError ?? "Завантаження…")
        }

        let rows = snapshot.windows.map { window -> UsagePanelView.Row in
            var detail = "використано \(Int(window.percentUsed.rounded()))%"
            if let resetsAt = window.resetsAt {
                let soon = resetsAt.timeIntervalSinceNow < 12 * 3600
                let stamp = soon ? clock.string(from: resetsAt) : clockWithDay.string(from: resetsAt)
                detail += " · оновиться о \(stamp)"
            }
            return UsagePanelView.Row(
                name: window.name,
                primary: "\(Int(window.percentLeft.rounded()))%",
                secondary: detail,
                fraction: window.percentUsed / 100,
                severity: Severity(percentLeft: window.percentLeft))
        }

        var footer: UsagePanelView.Footer?
        if let spend = snapshot.spend {
            footer = UsagePanelView.Footer(
                title: "Додаткові кредити",
                detail: spend.enabled
                    ? "використано \(spend.used) з \(spend.limit)"
                    : "вимкнено · ліміт \(spend.limit)",
                trailing: spend.enabled ? "\(Int(spend.percentUsed.rounded()))%" : "—")
        }

        return UsagePanelView(badge: badge, rows: rows, footer: footer)
    }

    private func sleepSubmenu() -> NSMenu {
        let submenu = NSMenu()

        if sleepGuard.isActive {
            let stop = NSMenuItem(title: "Вимкнути", action: #selector(stopSleepGuard),
                                  keyEquivalent: "")
            stop.target = self
            submenu.addItem(stop)
            let covers = sleepGuard.lidClosedCovered
                ? "Діє і з закритою кришкою"
                : "Діє, поки кришка відкрита"
            submenu.addItem(viewItem(InfoRowView(title: covers, trailing: "", secondary: true)))
            submenu.addItem(.separator())
        }

        for option in SleepGuard.durations {
            let item = NSMenuItem(title: option.title, action: #selector(startSleepGuard(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = option.seconds as Any?
            if sleepGuard.isActive && sleepGuard.chosenDuration == option.seconds {
                item.state = .on
            }
            submenu.addItem(item)
        }

        submenu.addItem(.separator())
        let lid = NSMenuItem(title: "Також із закритою кришкою",
                             action: #selector(toggleLidPolicy), keyEquivalent: "")
        lid.target = self
        lid.state = sleepGuard.keepAwakeWithLidClosed ? .on : .off
        lid.toolTip = "Потребує пароля адміністратора: змінює системний параметр pmset disablesleep."
        submenu.addItem(lid)
        submenu.addItem(viewItem(InfoRowView(title: "потрібен пароль адміністратора",
                                             trailing: "", secondary: true)))

        return submenu
    }

    @objc private func startSleepGuard(_ sender: NSMenuItem) {
        let duration = sender.representedObject as? TimeInterval
        if let warning = sleepGuard.activate(duration: duration) {
            let alert = NSAlert()
            alert.messageText = "Заборона сну"
            alert.informativeText = warning
            alert.runModal()
        }
    }

    @objc private func stopSleepGuard() { sleepGuard.deactivate() }

    @objc private func toggleLidPolicy() {
        sleepGuard.keepAwakeWithLidClosed.toggle()
        sleepGuard.lidPreferenceChanged()
        render()
    }

    func prepareForTermination() { sleepGuard.prepareForTermination() }

    private func viewItem(_ view: NSView) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = view
        return item
    }

    // MARK: - Actions

    @objc private func openUsagePage() {
        if let url = URL(string: "https://claude.ai/settings/usage") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Не вдалося змінити автозапуск"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        rebuildMenu()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
