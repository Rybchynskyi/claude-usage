import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac awake, optionally for a limited time.
///
/// Two mechanisms, because macOS treats them differently:
/// * a power assertion stops *idle* sleep and needs no privileges;
/// * `pmset disablesleep` is the only thing that also keeps the Mac awake with
///   the lid shut, and it needs an administrator, so macOS asks for a password.
///
/// The assertion dies with the process, but `disablesleep` outlives it — hence
/// the stranded-state flag, so a crash or a forced quit cannot leave the Mac
/// permanently unable to sleep without saying so.
final class SleepGuard {
    static let durations: [(title: String, seconds: TimeInterval?)] = [
        ("15 хвилин", 15 * 60),
        ("30 хвилин", 30 * 60),
        ("1 година", 60 * 60),
        ("2 години", 2 * 60 * 60),
        ("4 години", 4 * 60 * 60),
        ("Поки не вимкну", nil),
    ]

    private static let lidKey = "keepAwakeWithLidClosed"
    private static let strandedKey = "sleepDisabledByClaudeUsage"

    private(set) var isActive = false
    private(set) var expiresAt: Date?
    private(set) var chosenDuration: TimeInterval?
    private(set) var lidClosedCovered = false

    /// Called whenever the state changes, including when the timer runs out.
    var onChange: (() -> Void)?

    private var assertionID: IOPMAssertionID = 0
    private var expiryTimer: Timer?

    /// Whether the user wants the lid-closed part. Persisted between launches.
    var keepAwakeWithLidClosed: Bool {
        get { UserDefaults.standard.bool(forKey: Self.lidKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.lidKey) }
    }

    var remainingDescription: String {
        guard isActive else { return "" }
        guard let expiresAt else { return "без обмеження часу" }
        let remaining = max(0, Int(expiresAt.timeIntervalSinceNow.rounded()))
        let hours = remaining / 3600, minutes = (remaining % 3600 + 59) / 60
        if hours > 0 { return "ще \(hours) год \(minutes) хв" }
        return "ще \(max(1, minutes)) хв"
    }

    // MARK: - Switching on and off

    /// Returns a message to show the user when something went only partly right.
    @discardableResult
    func activate(duration: TimeInterval?) -> String? {
        releaseAssertion()
        chosenDuration = duration
        expiresAt = duration.map { Date(timeIntervalSinceNow: $0) }

        var warning: String?
        if createAssertion() {
            isActive = true
        } else {
            isActive = false
            onChange?()
            return "Система не дозволила заборонити сон."
        }

        if keepAwakeWithLidClosed && !lidClosedCovered {
            if setSleepDisabled(true) {
                lidClosedCovered = true
            } else {
                warning = "Сон заборонено, але лише поки кришка відкрита: "
                    + "для закритої кришки потрібен пароль адміністратора."
            }
        }

        scheduleExpiry()
        onChange?()
        return warning
    }

    func deactivate() {
        releaseAssertion()
        if lidClosedCovered { _ = setSleepDisabled(false) }
        isActive = false
        expiresAt = nil
        chosenDuration = nil
        expiryTimer?.invalidate()
        expiryTimer = nil
        onChange?()
    }

    /// Applies a change of the lid-closed preference to a guard already running.
    func lidPreferenceChanged() {
        guard isActive else { return }
        if keepAwakeWithLidClosed && !lidClosedCovered {
            lidClosedCovered = setSleepDisabled(true)
        } else if !keepAwakeWithLidClosed && lidClosedCovered {
            if setSleepDisabled(false) { lidClosedCovered = false }
        }
        onChange?()
    }

    /// Picks the guard back up if a previous run left `disablesleep` on.
    func restoreIfStranded() {
        guard UserDefaults.standard.bool(forKey: Self.strandedKey),
              Self.systemSleepDisabled() else {
            UserDefaults.standard.set(false, forKey: Self.strandedKey)
            return
        }
        lidClosedCovered = true
        isActive = createAssertion()
        expiresAt = nil            // the old deadline is gone; treat it as open-ended
        chosenDuration = nil
        onChange?()
    }

    /// Called when the app is quitting: never leave the Mac unable to sleep.
    func prepareForTermination() {
        releaseAssertion()
        if lidClosedCovered { _ = setSleepDisabled(false) }
    }

    // MARK: - Mechanisms

    private func createAssertion() -> Bool {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Claude Usage: keep awake" as CFString,
            &id)
        guard result == kIOReturnSuccess else { return false }
        assertionID = id
        return true
    }

    private func releaseAssertion() {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
    }

    /// `pmset -a disablesleep` needs root, so this goes through the standard
    /// macOS authorisation dialog. Returns false if the user cancels.
    private func setSleepDisabled(_ disabled: Bool) -> Bool {
        let command = "/usr/bin/pmset -a disablesleep \(disabled ? 1 : 0)"
        let source = "do shell script \"\(command)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard error == nil else { return false }
        UserDefaults.standard.set(disabled, forKey: Self.strandedKey)
        return true
    }

    private static func systemSleepDisabled() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .contains { $0.contains("SleepDisabled") && $0.contains("1") }
    }

    private func scheduleExpiry() {
        expiryTimer?.invalidate()
        guard let expiresAt else { expiryTimer = nil; return }
        expiryTimer = Timer.scheduledTimer(
            withTimeInterval: max(1, expiresAt.timeIntervalSinceNow), repeats: false
        ) { [weak self] _ in
            self?.deactivate()
        }
    }
}
