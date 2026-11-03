import Foundation

/// Which language the interface speaks.
enum Language: String, CaseIterable {
    case system, uk, en

    /// Shown in the language submenu. The two real languages name themselves,
    /// the way language pickers everywhere do — a Ukrainian speaker looking for
    /// Ukrainian should not have to read English to find it.
    var menuTitle: String {
        switch self {
        case .system: return S.languageSystem
        case .uk: return "Українська"
        case .en: return "English"
        }
    }
}

/// Everything the app says, one table per language.
///
/// Not `.lproj` bundles: `build.sh` hands `swiftc` a list of files and the app
/// carries no resource pipeline, and a table in Swift makes the manual override
/// take effect at once — picking a language redraws the menu instead of asking
/// for a relaunch. The struct has no defaults on purpose, so adding a string
/// fails to compile until both languages have it.
struct Strings {
    // Menu bar and panel
    let menuBarTooltip: String
    let loading: String
    let remainingHeader: String
    let extraCredits: String
    let spendUsed: (String, String) -> String
    let spendDisabled: (String) -> String
    let usedPercent: (Int) -> String
    let resetsAt: (String) -> String
    let weeklyBySource: String

    // Limit windows, by API key
    let windowNames: [String: String]
    let windowShortNames: [String: String]

    // Keeping awake
    let dontSleep: String
    let dontSleepActive: (String) -> String
    let turnOff: String
    let retryWithPassword: String
    let alsoWithLidClosed: String
    let lidTooltip: String
    let durations: [String]
    let noTimeLimit: String
    let remainingHoursMinutes: (Int, Int) -> String
    let remainingMinutes: (Int) -> String

    // What the lid-closed half is doing
    let lidCovered: String
    let lidWaiting: String
    let lidRefused: (String) -> String
    let lidApplying: String
    let lidOpenOnly: String
    let lidHintNeedsPassword: String
    let lidHintEnterPassword: String
    let lidHintPressRetry: String
    let systemHold: String

    // Tooltip lines
    let sleepBlocked: (String) -> String
    let lidCoveredLine: String
    let lidOpenOnlyLine: String
    let systemHoldWarning: String

    // Problems worth a dialog
    let sleepAlertTitle: String
    let assertionFailed: String
    let passwordNotEntered: String
    let pmsetFailed: (String) -> String
    let pmsetUnverified: String
    let pmsetRefused: String
    let shortPasswordNotEntered: String
    let shortStateUnknown: String
    let shortSystemRefused: String
    let errorCode: (Int) -> String
    let launchAtLoginFailed: String

    // The rest of the menu
    let refresh: String
    let refreshWithTime: (String) -> String
    let usagePage: String
    let launchAtLogin: String
    let language: String
    let languageSystem: String
    let quit: String

    // Credentials and the API
    let keychainUnreadable: String
    let keychainMalformed: String
    let tokenExpiredNoRefresh: String
    let refreshFailed: (String) -> String
    let unexpectedResponse: String
    let loginRejected: String
    let serverHTTP: (Int) -> String
    let malformedResponse: String
    let noLimitsReported: String

    // `--once`
    let cliUsed: String
    let cliLeft: String
    let cliReset: String

    func windowName(_ key: String) -> String { windowNames[key] ?? key }
    func windowShortName(_ key: String) -> String { windowShortNames[key] ?? key }
}

extension Strings {
    static let uk = Strings(
        menuBarTooltip: "Ліміти Claude Code",
        loading: "Завантаження…",
        remainingHeader: "Claude Code — залишилось:",
        extraCredits: "Додаткові кредити",
        spendUsed: { used, limit in "використано \(used) з \(limit)" },
        spendDisabled: { limit in "вимкнено · ліміт \(limit)" },
        usedPercent: { "використано \($0)%" },
        resetsAt: { "оновиться о \($0)" },
        weeklyBySource: "Тиждень за джерелами",

        windowNames: [
            "five_hour": "Сесія · 5 годин",
            "seven_day": "Тиждень · усе",
            "seven_day_opus": "Тиждень · Opus",
            "seven_day_sonnet": "Тиждень · Sonnet",
            "seven_day_oauth_apps": "Тиждень · застосунки",
            "seven_day_cowork": "Тиждень · Cowork",
        ],
        windowShortNames: [
            "five_hour": "5г",
            "seven_day": "7д",
            "seven_day_opus": "Opus",
            "seven_day_sonnet": "Sonnet",
            "seven_day_oauth_apps": "Застосунки",
            "seven_day_cowork": "Cowork",
        ],

        dontSleep: "Не засинати",
        dontSleepActive: { "Не засинати · \($0)" },
        turnOff: "Вимкнути",
        retryWithPassword: "Спробувати ще раз (пароль)",
        alsoWithLidClosed: "Також із закритою кришкою",
        lidTooltip: "Потребує пароля адміністратора: змінює системний параметр pmset disablesleep.",
        durations: ["15 хвилин", "30 хвилин", "1 година", "2 години", "4 години",
                    "Поки не вимкну"],
        noTimeLimit: "без обмеження часу",
        remainingHoursMinutes: { hours, minutes in "ще \(hours) год \(minutes) хв" },
        remainingMinutes: { "ще \($0) хв" },

        lidCovered: "діє і з закритою кришкою",
        lidWaiting: "запитую пароль…",
        lidRefused: { "лише поки кришка відкрита · \($0)" },
        lidApplying: "застосовую…",
        lidOpenOnly: "діє, поки кришка відкрита",
        lidHintNeedsPassword: "потрібен пароль адміністратора",
        lidHintEnterPassword: "введіть пароль у вікні системи",
        lidHintPressRetry: "натисніть «Спробувати ще раз»",
        systemHold: "Сон і далі заборонено системно — зняти",

        sleepBlocked: { "Сон заборонено · \($0)" },
        lidCoveredLine: "Діє і з закритою кришкою",
        lidOpenOnlyLine: "Діє, поки кришка відкрита",
        systemHoldWarning: "Увага: системна заборона сну досі ввімкнена",

        sleepAlertTitle: "Заборона сну",
        assertionFailed: "Система не дозволила заборонити сон.",
        passwordNotEntered: "Пароль не введено, тому режим із закритою кришкою не змінено.",
        pmsetFailed: { "Не вдалося змінити системний параметр сну: \($0)" },
        pmsetUnverified: "Не вдалося перевірити стан pmset.",
        pmsetRefused: "Система не прийняла pmset disablesleep.",
        shortPasswordNotEntered: "пароль не введено",
        shortStateUnknown: "стан невідомий",
        shortSystemRefused: "система відмовила",
        errorCode: { "помилка \($0)" },
        launchAtLoginFailed: "Не вдалося змінити автозапуск",

        refresh: "Оновити",
        refreshWithTime: { "Оновити · дані за \($0)" },
        usagePage: "Сторінка використання…",
        launchAtLogin: "Запускати при вході",
        language: "Мова",
        languageSystem: "Як у системі",
        quit: "Вийти",

        keychainUnreadable: "Не вдалося прочитати вхід Claude Code з keychain. "
            + "Виконайте `claude` і увійдіть.",
        keychainMalformed: "Збережений вхід Claude Code має неочікуваний формат.",
        tokenExpiredNoRefresh: "Термін дії токена сплив, а refresh-токена немає. "
            + "Виконайте `claude /login`.",
        refreshFailed: { "Не вдалося оновити токен: \($0)" },
        unexpectedResponse: "неочікувана відповідь",
        loginRejected: "Вхід відхилено (401). Виконайте `claude /login`.",
        serverHTTP: { "Сервер відповів HTTP \($0)." },
        malformedResponse: "Не вдалося розібрати відповідь сервера.",
        noLimitsReported: "Для цього акаунта ліміти не повідомляються "
            + "(можливо, оплата за API).",

        cliUsed: "використано",
        cliLeft: "залишилось",
        cliReset: "скидання"
    )

    static let en = Strings(
        menuBarTooltip: "Claude Code limits",
        loading: "Loading…",
        remainingHeader: "Claude Code — remaining:",
        extraCredits: "Extra credits",
        spendUsed: { used, limit in "\(used) of \(limit) used" },
        spendDisabled: { limit in "off · limit \(limit)" },
        usedPercent: { "\($0)% used" },
        resetsAt: { "resets at \($0)" },
        weeklyBySource: "Week by source",

        windowNames: [
            "five_hour": "Session · 5 hours",
            "seven_day": "Week · everything",
            "seven_day_opus": "Week · Opus",
            "seven_day_sonnet": "Week · Sonnet",
            "seven_day_oauth_apps": "Week · apps",
            "seven_day_cowork": "Week · Cowork",
        ],
        windowShortNames: [
            "five_hour": "5h",
            "seven_day": "7d",
            "seven_day_opus": "Opus",
            "seven_day_sonnet": "Sonnet",
            "seven_day_oauth_apps": "Apps",
            "seven_day_cowork": "Cowork",
        ],

        dontSleep: "Don't sleep",
        dontSleepActive: { "Don't sleep · \($0)" },
        turnOff: "Turn off",
        retryWithPassword: "Try again (password)",
        alsoWithLidClosed: "Also with the lid closed",
        lidTooltip: "Needs an administrator password: it changes the system "
            + "setting pmset disablesleep.",
        durations: ["15 minutes", "30 minutes", "1 hour", "2 hours", "4 hours",
                    "Until I turn it off"],
        noTimeLimit: "no time limit",
        remainingHoursMinutes: { hours, minutes in "\(hours) h \(minutes) min left" },
        remainingMinutes: { "\($0) min left" },

        lidCovered: "works with the lid closed too",
        lidWaiting: "asking for the password…",
        lidRefused: { "only while the lid is open · \($0)" },
        lidApplying: "applying…",
        lidOpenOnly: "works while the lid is open",
        lidHintNeedsPassword: "needs an administrator password",
        lidHintEnterPassword: "enter the password in the system dialog",
        lidHintPressRetry: "press “Try again”",
        systemHold: "Sleep is still disabled system-wide — clear it",

        sleepBlocked: { "Sleep is blocked · \($0)" },
        lidCoveredLine: "Works with the lid closed too",
        lidOpenOnlyLine: "Works while the lid is open",
        systemHoldWarning: "Warning: the system-wide sleep block is still on",

        sleepAlertTitle: "Keeping the Mac awake",
        assertionFailed: "The system would not allow sleep to be blocked.",
        passwordNotEntered: "No password was entered, so the lid-closed mode is unchanged.",
        pmsetFailed: { "Could not change the system sleep setting: \($0)" },
        pmsetUnverified: "Could not verify the pmset state.",
        pmsetRefused: "The system did not accept pmset disablesleep.",
        shortPasswordNotEntered: "no password entered",
        shortStateUnknown: "state unknown",
        shortSystemRefused: "the system refused",
        errorCode: { "error \($0)" },
        launchAtLoginFailed: "Could not change launch at login",

        refresh: "Refresh",
        refreshWithTime: { "Refresh · data from \($0)" },
        usagePage: "Usage page…",
        launchAtLogin: "Launch at login",
        language: "Language",
        languageSystem: "Same as the system",
        quit: "Quit",

        keychainUnreadable: "Could not read the Claude Code login from the keychain. "
            + "Run `claude` and sign in.",
        keychainMalformed: "The stored Claude Code login has an unexpected format.",
        tokenExpiredNoRefresh: "The token has expired and there is no refresh token. "
            + "Run `claude /login`.",
        refreshFailed: { "Could not refresh the token: \($0)" },
        unexpectedResponse: "unexpected response",
        loginRejected: "Login rejected (401). Run `claude /login`.",
        serverHTTP: { "The server answered HTTP \($0)." },
        malformedResponse: "Could not parse the server's answer.",
        noLimitsReported: "This account reports no limits (API billing, perhaps).",

        cliUsed: "used",
        cliLeft: "left",
        cliReset: "resets"
    )
}

/// The chosen language, and the table that follows from it.
enum Localization {
    private static let key = "interfaceLanguage"

    static var language: Language {
        get { Language(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// `.system` resolved to a real language. Anything that is not Ukrainian
    /// gets English, which is the honest choice with only two tables.
    static var resolved: Language {
        let chosen = language
        guard chosen == .system else { return chosen }
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("uk") ? .uk : .en
    }

    static var strings: Strings { resolved == .uk ? .uk : .en }

    /// For date formatting: weekday names in the interface language, while the
    /// clock itself stays 24-hour in both.
    static var locale: Locale { Locale(identifier: resolved == .uk ? "uk_UA" : "en_US") }
}

/// Shorthand, because these are referenced everywhere: `S.dontSleep`.
var S: Strings { Localization.strings }
