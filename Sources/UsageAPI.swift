import Foundation

struct LimitWindow {
    let key: String
    let percentUsed: Double
    let resetsAt: Date?

    /// Looked up rather than stored, so switching the interface language
    /// renames the windows without re-fetching anything.
    var name: String { S.windowName(key) }          // full, for the dropdown
    var shortName: String { S.windowShortName(key) } // compact, for the menu bar

    var percentLeft: Double { max(0, 100 - percentUsed) }
}

struct SpendInfo {
    let enabled: Bool
    let usedMinor: Int
    let limitMinor: Int
    let exponent: Int
    let currency: String

    private func money(_ minor: Int) -> String {
        let value = Double(minor) / pow(10, Double(exponent))
        let symbol = currency == "USD" ? "$" : "\(currency) "
        return String(format: "\(symbol)%.2f", value)
    }

    var used: String { money(usedMinor) }
    var limit: String { money(limitMinor) }
    var percentUsed: Double {
        limitMinor > 0 ? Double(usedMinor) / Double(limitMinor) * 100 : 0
    }
}

struct UsageSnapshot {
    var windows: [LimitWindow]
    var spend: SpendInfo?
    var weeklyBreakdown: [(name: String, percent: Double)]
    var fetchedAt: Date

    /// The window that will stop you first — the one worth putting in the menu bar.
    var binding: LimitWindow? {
        windows.max { lhs, rhs in lhs.percentUsed < rhs.percentUsed }
    }
}

enum UsageError: LocalizedError {
    case http(Int)
    case malformed
    case empty

    var errorDescription: String? {
        switch self {
        case .http(401): return S.loginRejected
        case .http(let code): return S.serverHTTP(code)
        case .malformed: return S.malformedResponse
        case .empty: return S.noLimitsReported
        }
    }
}

enum UsageAPI {
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Windows in the order they should be listed. The display names live in
    /// `Strings`, keyed by these same keys.
    private static let known = [
        "five_hour",
        "seven_day",
        "seven_day_opus",
        "seven_day_sonnet",
        "seven_day_oauth_apps",
        "seven_day_cowork",
    ]

    static func fetch() throws -> UsageSnapshot {
        var token = try Credentials.accessToken()
        var (data, status) = try get(token: token)
        if status == 401 {
            // The stored token may have been revoked ahead of its stated expiry.
            token = try Credentials.accessToken(forceRefresh: true)
            (data, status) = try get(token: token)
        }
        guard status == 200 else { throw UsageError.http(status) }
        return try parse(data)
    }

    private static func get(token: String) throws -> (Data, Int) {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        return try HTTP.send(request)
    }

    static func parse(_ data: Data) throws -> UsageSnapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.malformed
        }

        var windows: [LimitWindow] = []
        for key in known {
            guard let window = json[key] as? [String: Any],
                  let utilization = window["utilization"] as? Double else { continue }
            windows.append(LimitWindow(
                key: key,
                percentUsed: utilization,
                resetsAt: date(window["resets_at"])
            ))
        }
        if windows.isEmpty { throw UsageError.empty }

        var spend: SpendInfo?
        if let block = json["spend"] as? [String: Any],
           let used = block["used"] as? [String: Any],
           let limit = block["limit"] as? [String: Any],
           let usedMinor = used["amount_minor"] as? Int,
           let limitMinor = limit["amount_minor"] as? Int {
            spend = SpendInfo(
                enabled: (block["enabled"] as? Bool) ?? false,
                usedMinor: usedMinor,
                limitMinor: limitMinor,
                exponent: (limit["exponent"] as? Int) ?? 2,
                currency: (limit["currency"] as? String) ?? "USD"
            )
        }

        var breakdown: [(String, Double)] = []
        if let block = json["seven_day_breakdown"] as? [String: Any],
           let rows = block["rows"] as? [[String: Any]] {
            for row in rows {
                guard let percent = row["percent"] as? Double else { continue }
                let name = (row["display_name"] as? String) ?? (row["key"] as? String) ?? "—"
                breakdown.append((name, percent))
            }
        }

        return UsageSnapshot(windows: windows, spend: spend,
                             weeklyBreakdown: breakdown, fetchedAt: Date())
    }

    private static let isoWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso = ISO8601DateFormatter()

    /// `resets_at` arrives as an ISO-8601 string, but older builds sent epoch seconds.
    private static func date(_ value: Any?) -> Date? {
        if let text = value as? String {
            return isoWithFraction.date(from: text) ?? iso.date(from: text)
        }
        if let seconds = value as? Double { return Date(timeIntervalSince1970: seconds) }
        return nil
    }
}
