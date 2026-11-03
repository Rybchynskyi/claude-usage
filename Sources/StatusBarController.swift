import AppKit
import ServiceManagement

/// The menu bar item and its dropdown.
///
/// The menu is built once, in `init`, and from then on only ever *updated*:
/// titles, checkmarks and the panel's contents change, but no item is ever
/// removed or inserted. That is deliberate. Opening the menu kicks off a fetch,
/// and the old code rebuilt every item when that fetch came back — half a
/// second later, right under the cursor. A click then landed on an item that no
/// longer existed and did nothing, which is why the keep-awake switch so often
/// needed a second go. Anything that would change the menu's *shape* is held
/// back until the menu closes (`pendingLayout`), so items never move either.
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
    private var tickTimer: Timer?

    private var isMenuOpen = false
    private var pendingLayout = true

    // MARK: Menu furniture, created once

    private let panelView = UsagePanelView(badge: nil, rows: [], footer: nil,
                                           message: "Завантаження…")
    private let panelItem = NSMenuItem()

    private let breakdownItem = NSMenuItem(title: "Тиждень за джерелами",
                                           action: nil, keyEquivalent: "")
    private let breakdownSeparator = NSMenuItem.separator()
    /// A fixed pool: the API decides how many sources there are, and growing or
    /// shrinking a live menu is exactly what we are avoiding.
    private let breakdownRows: [(item: NSMenuItem, view: InfoRowView)] =
        (0..<8).map { _ in
            let view = InfoRowView(title: "", trailing: "")
            let item = NSMenuItem()
            item.view = view
            return (item, view)
        }

    private let sleepItem = NSMenuItem(title: "Не засинати", action: nil, keyEquivalent: "")
    private let sleepSubmenu = NSMenu()
    private let stopItem = NSMenuItem(title: "Вимкнути", action: nil, keyEquivalent: "")
    private let lidStatusView = InfoRowView(title: "", trailing: "", secondary: true)
    private let lidStatusItem = NSMenuItem()
    private let lidRetryItem = NSMenuItem(title: "Спробувати ще раз (пароль)",
                                          action: nil, keyEquivalent: "")
    private let sleepTopSeparator = NSMenuItem.separator()
    private let durationItems: [NSMenuItem] = SleepGuard.durations.map {
        let item = NSMenuItem(title: $0.title, action: nil, keyEquivalent: "")
        item.representedObject = $0.seconds as Any?
        return item
    }
    private let lidSeparator = NSMenuItem.separator()
    private let lidItem = NSMenuItem(title: "Також із закритою кришкою",
                                     action: nil, keyEquivalent: "")
    private let lidHintView = InfoRowView(title: "потрібен пароль адміністратора",
                                          trailing: "", secondary: true)
    private let lidHintItem = NSMenuItem()

    /// Only ever visible in the one case that used to be silently wrong: the
    /// guard is off, but clearing `pmset disablesleep` was refused, so the Mac
    /// still cannot sleep.
    private let systemHoldItem = NSMenuItem(title: "Сон і далі заборонено системно — зняти",
                                            action: nil, keyEquivalent: "")

    private let refreshItem = NSMenuItem(title: "Оновити", action: nil, keyEquivalent: "r")
    private let openItem = NSMenuItem(title: "Сторінка використання…",
                                      action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Запускати при вході",
                                       action: nil, keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "Вийти", action: nil, keyEquivalent: "q")

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
        buildMenu()

        sleepGuard.onChange = { [weak self] in self?.render() }
        sleepGuard.onProblem = { [weak self] message in self?.report(message) }
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

    // MARK: - Building, once

    private func buildMenu() {
        panelItem.view = panelView
        menu.addItem(panelItem)

        let breakdownMenu = NSMenu()
        for row in breakdownRows { breakdownMenu.addItem(row.item) }
        breakdownItem.submenu = breakdownMenu
        menu.addItem(breakdownItem)
        menu.addItem(breakdownSeparator)

        stopItem.target = self
        stopItem.action = #selector(stopSleepGuard)
        sleepSubmenu.addItem(stopItem)

        lidStatusItem.view = lidStatusView
        sleepSubmenu.addItem(lidStatusItem)

        lidRetryItem.target = self
        lidRetryItem.action = #selector(retryLid)
        sleepSubmenu.addItem(lidRetryItem)
        sleepSubmenu.addItem(sleepTopSeparator)

        for item in durationItems {
            item.target = self
            item.action = #selector(startSleepGuard(_:))
            sleepSubmenu.addItem(item)
        }

        sleepSubmenu.addItem(lidSeparator)
        lidItem.target = self
        lidItem.action = #selector(toggleLidPolicy)
        lidItem.toolTip = "Потребує пароля адміністратора: змінює системний параметр pmset disablesleep."
        sleepSubmenu.addItem(lidItem)
        lidHintItem.view = lidHintView
        sleepSubmenu.addItem(lidHintItem)

        sleepItem.submenu = sleepSubmenu
        menu.addItem(sleepItem)

        systemHoldItem.target = self
        systemHoldItem.action = #selector(retryLid)
        menu.addItem(systemHoldItem)
        menu.addItem(.separator())

        refreshItem.target = self
        refreshItem.action = #selector(refreshNow)
        menu.addItem(refreshItem)

        openItem.target = self
        openItem.action = #selector(openUsagePage)
        menu.addItem(openItem)

        loginItem.target = self
        loginItem.action = #selector(toggleLaunchAtLogin)
        menu.addItem(loginItem)

        menu.addItem(.separator())
        quitItem.target = self
        quitItem.action = #selector(quit)
        menu.addItem(quitItem)
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
        guard menu === self.menu else { return }
        isMenuOpen = true
        syncLayout()          // safe now: the menu is not on screen yet
        syncTitles()
        refresh()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        isMenuOpen = false
        if pendingLayout { syncLayout() }
    }

    // MARK: - Menu bar

    private func render() {
        renderButton()
        syncTitles()
        syncLayout()        // defers itself if the shape would change mid-click
        updateTick()
    }

    private func renderButton() {
        guard let button = statusItem.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        // The dot means "this Mac is not going to sleep" — including the case
        // where only the system-wide setting is still holding it awake.
        let awake = sleepGuard.isActive || sleepGuard.sleepDisabledSystemWide

        guard let window = snapshot?.binding else {
            button.image = ClaudeMark.image(color: lastError == nil ? Brand.kraft : Brand.clay,
                                            badge: awake)
            button.attributedTitle = NSAttributedString(
                string: lastError == nil ? " …" : " ⚠",
                attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
            button.toolTip = lastError ?? "Завантаження…"
            return
        }

        let severity = Severity(percentLeft: window.percentLeft)
        button.image = ClaudeMark.image(color: severity.menuBarColor, badge: awake)
        button.attributedTitle = NSAttributedString(
            string: " \(Int(window.percentLeft.rounded()))%",
            attributes: [.font: font,
                         .foregroundColor: severity == .normal
                             ? NSColor.labelColor : severity.menuBarColor])
        button.toolTip = tooltip()
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
            lines.append(sleepGuard.lidClosedCovered
                ? "Діє і з закритою кришкою"
                : "Діє, поки кришка відкрита")
        } else if sleepGuard.sleepDisabledSystemWide {
            lines.append("Увага: системна заборона сну досі ввімкнена")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Dropdown, updated in place

    /// Text and checkmarks only. Changing these under the cursor is harmless.
    private func syncTitles() {
        sleepItem.title = sleepGuard.isActive
            ? "Не засинати · \(sleepGuard.remainingDescription)"
            : "Не засинати"
        sleepItem.state = sleepGuard.isActive ? .on : .off

        for (item, option) in zip(durationItems, SleepGuard.durations) {
            item.state = sleepGuard.isActive && sleepGuard.chosenDuration == option.seconds
                ? .on : .off
        }

        lidItem.state = sleepGuard.keepAwakeWithLidClosed ? .on : .off
        lidStatusView.update(title: lidStatusText, trailing: "")
        lidHintView.update(title: lidHintText, trailing: "")

        let sources = breakdownSources()
        for (index, row) in breakdownRows.enumerated() where index < sources.count {
            row.view.update(title: sources[index].name,
                            trailing: "\(Int(sources[index].percent.rounded()))%")
        }

        refreshItem.title = snapshot.map { "Оновити · дані за \(clock.string(from: $0.fetchedAt))" }
            ?? "Оновити"
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private var lidStatusText: String {
        switch sleepGuard.lidState {
        case .covered: return "діє і з закритою кришкою"
        case .waiting: return "запитую пароль…"
        case .refused(let why): return "лише поки кришка відкрита · \(why)"
        case .off:
            return sleepGuard.keepAwakeWithLidClosed
                ? "застосовую…" : "діє, поки кришка відкрита"
        }
    }

    private var lidHintText: String {
        switch sleepGuard.lidState {
        case .waiting: return "введіть пароль у вікні системи"
        case .refused: return "натисніть «Спробувати ще раз»"
        default: return "потрібен пароль адміністратора"
        }
    }

    private func breakdownSources() -> [(name: String, percent: Double)] {
        Array((snapshot?.weeklyBreakdown ?? [])
            .filter { $0.percent > 0 }
            .sorted { $0.percent > $1.percent }
            .prefix(breakdownRows.count))
    }

    /// Everything about the menu that affects its *shape*: which items show and
    /// how tall the panel is. Two of these in a row that match means nothing
    /// moves, so an update is safe even with the menu on screen.
    private struct Layout: Equatable {
        let sources: Int
        let active: Bool
        let retry: Bool
        let hold: Bool
        let panelRows: Int
        let hasFooter: Bool
        let hasMessage: Bool
    }

    private var appliedLayout: Layout?

    private func desiredLayout() -> Layout {
        let model = panelModel()
        let refused: Bool
        if case .refused = sleepGuard.lidState { refused = true } else { refused = false }
        return Layout(
            sources: breakdownSources().count,
            active: sleepGuard.isActive,
            // While the guard is off, the top-level "still held" item is the
            // one that offers to ask again — two of them would just confuse.
            retry: refused && sleepGuard.isActive,
            hold: sleepGuard.sleepDisabledSystemWide && !sleepGuard.isActive,
            panelRows: model.rows.count,
            hasFooter: model.footer != nil,
            hasMessage: model.message != nil)
    }

    private func syncLayout() {
        let wanted = desiredLayout()

        // Same shape as what is on screen: only the numbers changed, and the
        // panel keeps its height, so this is safe mid-click.
        if wanted == appliedLayout {
            pendingLayout = false
            syncPanel()
            return
        }
        // A different shape while the menu is open would move items out from
        // under the cursor. It waits for `menuDidClose`.
        if isMenuOpen {
            pendingLayout = true
            return
        }

        for (index, row) in breakdownRows.enumerated() {
            row.item.isHidden = index >= wanted.sources
        }
        breakdownItem.isHidden = wanted.sources == 0
        breakdownSeparator.isHidden = wanted.sources == 0

        stopItem.isHidden = !wanted.active
        lidStatusItem.isHidden = !wanted.active
        sleepTopSeparator.isHidden = !wanted.active
        lidRetryItem.isHidden = !wanted.retry
        systemHoldItem.isHidden = !wanted.hold

        syncPanel()
        appliedLayout = wanted
        pendingLayout = false
    }

    private func syncPanel() {
        let model = panelModel()
        panelView.update(badge: model.badge, rows: model.rows,
                         footer: model.footer, message: model.message)
    }

    private struct PanelModel {
        let badge: String?
        let rows: [UsagePanelView.Row]
        let footer: UsagePanelView.Footer?
        let message: String?
    }

    private func panelModel() -> PanelModel {
        let badge = Credentials.subscriptionType?.uppercased()

        guard let snapshot else {
            return PanelModel(badge: badge, rows: [], footer: nil,
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

        return PanelModel(badge: badge, rows: rows, footer: footer, message: nil)
    }

    /// Keeps "ще 42 хв" honest while the guard is running, and costs nothing
    /// when it is not.
    private func updateTick() {
        let wanted = sleepGuard.isActive && sleepGuard.expiresAt != nil
        if wanted, tickTimer == nil {
            tickTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
                self?.syncTitles()
            }
        } else if !wanted {
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }

    // MARK: - Actions

    @objc private func startSleepGuard(_ sender: NSMenuItem) {
        sleepGuard.activate(duration: sender.representedObject as? TimeInterval)
    }

    @objc private func stopSleepGuard() { sleepGuard.deactivate() }

    @objc private func retryLid() { sleepGuard.retryLid() }

    @objc private func toggleLidPolicy() {
        sleepGuard.setLidPreference(!sleepGuard.keepAwakeWithLidClosed)
    }

    func prepareForTermination() { sleepGuard.prepareForTermination() }

    private func report(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Заборона сну"
        alert.informativeText = message
        alert.runModal()
    }

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
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Не вдалося змінити автозапуск"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        syncTitles()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
