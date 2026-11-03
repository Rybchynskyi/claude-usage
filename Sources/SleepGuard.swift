import AppKit
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
///
/// Everything privileged is deferred and verified. Deferred, because the old
/// code put the password dialog up from inside the menu's click handler, while
/// the menu was still being tracked — the dialog could end up behind another
/// app, or the click could be swallowed altogether. Now the request goes
/// through the run loop first, so the menu is gone by the time the dialog
/// appears. Verified, because a dialog that closed is no proof the setting
/// took: `pmset -g` is read back, and the guard only ever claims the lid is
/// covered when the system agrees.
final class SleepGuard {
    /// The offered durations. Titles come from `Strings.durations` in the same
    /// order, so the list renames itself when the language changes.
    static let durations: [TimeInterval?] = [15 * 60, 30 * 60, 60 * 60,
                                            2 * 60 * 60, 4 * 60 * 60, nil]

    /// What the lid-closed half of the guard is currently doing.
    enum LidState {
        case off                 // not asked for
        case covered             // `disablesleep` is on and verified
        case waiting             // the password dialog is up
        case refused(String)     // cancelled, or the system would not take it
    }

    private static let lidKey = "keepAwakeWithLidClosed"
    private static let strandedKey = "sleepDisabledByClaudeUsage"

    private(set) var isActive = false
    private(set) var expiresAt: Date?
    private(set) var chosenDuration: TimeInterval?
    private(set) var lidState: LidState = .off

    /// What the *system* is doing, as last verified — not what we asked for.
    /// Stays true after the guard is switched off if clearing it was refused,
    /// because in that case the Mac really still cannot sleep.
    private(set) var sleepDisabledSystemWide = false

    /// Called whenever the state changes, including when the timer runs out.
    var onChange: (() -> Void)?
    /// Called when something went wrong that is worth a dialog. A plain
    /// cancellation of the password prompt is not reported here — the menu
    /// shows it, and offers to try again.
    var onProblem: ((String) -> Void)?

    private var assertionID: IOPMAssertionID = 0
    private var expiryTimer: Timer?
    /// One password dialog at a time: the flag is what makes a second click
    /// while the first prompt is up a no-op instead of a second prompt.
    private var authInFlight = false

    var lidClosedCovered: Bool {
        if case .covered = lidState { return true }
        return false
    }

    /// Whether the user wants the lid-closed part. Persisted between launches.
    var keepAwakeWithLidClosed: Bool {
        get { UserDefaults.standard.bool(forKey: Self.lidKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.lidKey) }
    }

    var remainingDescription: String {
        guard isActive else { return "" }
        guard let expiresAt else { return S.noTimeLimit }
        let remaining = max(0, Int(expiresAt.timeIntervalSinceNow.rounded()))
        let hours = remaining / 3600, minutes = (remaining % 3600 + 59) / 60
        if hours > 0 { return S.remainingHoursMinutes(hours, minutes) }
        return S.remainingMinutes(max(1, minutes))
    }

    // MARK: - Switching on and off

    /// Switches the guard on. The part that needs no password takes effect
    /// before this returns, so the menu shows the result straight away; the
    /// lid-closed part follows once the password dialog is answered.
    func activate(duration: TimeInterval?) {
        releaseAssertion()
        chosenDuration = duration
        expiresAt = duration.map { Date(timeIntervalSinceNow: $0) }

        guard createAssertion() else {
            isActive = false
            expiresAt = nil
            chosenDuration = nil
            onChange?()
            onProblem?(S.assertionFailed)
            return
        }
        isActive = true
        scheduleExpiry()
        onChange?()
        syncLid(userInitiated: true)
    }

    func deactivate() {
        releaseAssertion()
        isActive = false
        expiresAt = nil
        chosenDuration = nil
        expiryTimer?.invalidate()
        expiryTimer = nil
        onChange?()
        // Clearing `disablesleep` needs the password again; if that is refused,
        // `sleepDisabledSystemWide` stays true and the menu keeps saying so.
        syncLid(userInitiated: true)
    }

    /// Stores the lid-closed preference and applies it at once.
    ///
    /// Switching it on while the guard is off starts the guard open-ended:
    /// on its own the setting means nothing, and the point of the switch is to
    /// see the Mac stay awake with the lid shut, not to arm a preference for
    /// some later time.
    func setLidPreference(_ wanted: Bool) {
        keepAwakeWithLidClosed = wanted
        if wanted && !isActive {
            activate(duration: nil)
        } else {
            syncLid(userInitiated: true)
        }
    }

    /// Asks again after a cancelled or failed password prompt.
    func retryLid() { syncLid(userInitiated: true) }

    /// Picks the guard back up if a previous run left `disablesleep` on.
    func restoreIfStranded() {
        guard UserDefaults.standard.bool(forKey: Self.strandedKey),
              Self.systemSleepDisabled() == true else {
            UserDefaults.standard.set(false, forKey: Self.strandedKey)
            return
        }
        sleepDisabledSystemWide = true
        keepAwakeWithLidClosed = true
        expiresAt = nil            // the old deadline is gone; treat it as open-ended
        chosenDuration = nil
        isActive = createAssertion()
        lidState = isActive ? .covered : .off
        onChange?()
    }

    /// Called when the app is quitting: never leave the Mac unable to sleep.
    /// Synchronous on purpose — there is no run loop left to come back to.
    func prepareForTermination() {
        releaseAssertion()
        guard sleepDisabledSystemWide else { return }
        _ = Self.applySleepDisabled(false)
    }

    // MARK: - The privileged half

    /// Brings the system in line with what the guard wants, if they differ.
    /// `userInitiated` separates a click from the timer and the odd corner: a
    /// prompt the user already cancelled is not put up again on its own.
    private func syncLid(userInitiated: Bool) {
        let wanted = isActive && keepAwakeWithLidClosed

        if wanted == sleepDisabledSystemWide {
            lidState = wanted ? .covered : .off
            onChange?()
            return
        }
        if case .refused = lidState, !userInitiated {
            onChange?()
            return
        }
        guard !authInFlight else { return }   // the answer re-runs this anyway

        // A previous run, or the user by hand, may already have left the system
        // in the wanted state — then there is nothing to ask a password for.
        if let actual = Self.systemSleepDisabled(), actual == wanted {
            sleepDisabledSystemWide = actual
            UserDefaults.standard.set(actual, forKey: Self.strandedKey)
            lidState = wanted ? .covered : .off
            onChange?()
            return
        }

        authInFlight = true
        lidState = .waiting
        onChange?()
        // An accessory app is never frontmost, so the authorisation dialog can
        // come up behind whatever the user is looking at. Ask for the front.
        NSApp.activate(ignoringOtherApps: true)

        // Asynchronously, but still on the main thread: `async` is what gets us
        // out of the menu's click handler, and the main thread is where
        // NSAppleScript and anything that puts up a window belong.
        DispatchQueue.main.async { [weak self] in
            let result = Self.applySleepDisabled(wanted)
            guard let self else { return }
            self.authInFlight = false
            switch result {
            case .success:
                self.sleepDisabledSystemWide = wanted
                UserDefaults.standard.set(wanted, forKey: Self.strandedKey)
                self.lidState = wanted ? .covered : .off
                self.onChange?()
            case .failure(let problem):
                self.lidState = .refused(problem.shortMessage)
                self.onChange?()
                if !problem.cancelled { self.onProblem?(problem.message) }
            }
            // The wish may have changed while the dialog was up.
            self.syncLid(userInitiated: false)
        }
    }

    private struct Problem: Error {
        let message: String
        let shortMessage: String
        let cancelled: Bool
    }

    /// `pmset -a disablesleep` needs root, so this goes through the standard
    /// macOS authorisation dialog — and the result is read back, because a
    /// dialog that closed is not proof that the setting took.
    private static func applySleepDisabled(_ disabled: Bool) -> Result<Void, Problem> {
        let command = "/usr/bin/pmset -a disablesleep \(disabled ? 1 : 0)"
        let source = "do shell script \"\(command)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)

        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            let cancelled = code == -128      // the user dismissed the dialog
            let detail = error[NSAppleScript.errorBriefMessage] as? String
                ?? error[NSAppleScript.errorMessage] as? String
                ?? S.errorCode(code)
            return .failure(Problem(
                message: cancelled ? S.passwordNotEntered : S.pmsetFailed(detail),
                shortMessage: cancelled ? S.shortPasswordNotEntered : detail,
                cancelled: cancelled))
        }

        guard let actual = systemSleepDisabled() else {
            return .failure(Problem(message: S.pmsetUnverified,
                                    shortMessage: S.shortStateUnknown, cancelled: false))
        }
        guard actual == disabled else {
            return .failure(Problem(message: S.pmsetRefused,
                                    shortMessage: S.shortSystemRefused, cancelled: false))
        }
        return .success(())
    }

    /// `nil` when `pmset` could not be read at all — not the same as "sleep is
    /// allowed", and the caller treats it differently.
    private static func systemSleepDisabled() -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        // The line reads "SleepDisabled\t\t0" — take the value, not any digit on
        // the line, so neighbouring settings cannot be mistaken for it.
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n")
        where line.contains("SleepDisabled") {
            guard let value = line.split(whereSeparator: \.isWhitespace).last else { continue }
            return value == "1"
        }
        return false            // pmset answered and never mentioned it: not set
    }

    // MARK: - The free half

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
