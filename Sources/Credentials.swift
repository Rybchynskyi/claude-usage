import Foundation
import CryptoKit

enum CredentialsError: LocalizedError {
    case keychainUnavailable
    case malformed
    case noRefreshToken
    case refreshFailed(String)

    var errorDescription: String? {
        switch self {
        case .keychainUnavailable:
            return "Не вдалося прочитати вхід Claude Code з keychain. Виконайте `claude` і увійдіть."
        case .malformed:
            return "Збережений вхід Claude Code має неочікуваний формат."
        case .noRefreshToken:
            return "Термін дії токена сплив, а refresh-токена немає. Виконайте `claude /login`."
        case .refreshFailed(let why):
            return "Не вдалося оновити токен: \(why)"
        }
    }
}

/// Access to the OAuth credentials that Claude Code keeps in the login keychain.
///
/// Reads and writes go through `/usr/bin/security`, exactly the way Claude Code
/// itself does it, so the keychain item's ACL stays untouched and macOS does not
/// raise an extra authorisation prompt for this app.
enum Credentials {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!

    /// Claude Code suffixes the keychain service with a hash of CLAUDE_CONFIG_DIR
    /// when that variable is set; otherwise the plain name is used.
    static var service: String {
        let suffix: String
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            let digest = SHA256.hash(data: Data(dir.precomposedStringWithCanonicalMapping.utf8))
            suffix = "-" + digest.map { String(format: "%02x", $0) }.joined().prefix(8)
        } else {
            suffix = ""
        }
        return "Claude Code-credentials\(suffix)"
    }

    /// Plan name as stored by Claude Code ("max", "pro", …), refreshed on every
    /// keychain read so the panel can show it as a badge.
    private(set) static var subscriptionType: String?

    private static var account: String {
        ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
    }

    /// A usable access token, refreshing it first when it has (nearly) expired.
    static func accessToken(forceRefresh: Bool = false) throws -> String {
        var stored = try read()
        guard var oauth = stored["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw CredentialsError.malformed
        }

        subscriptionType = oauth["subscriptionType"] as? String

        let expiresAtMs = (oauth["expiresAt"] as? Double) ?? 0
        let oneMinuteFromNow = Date().timeIntervalSince1970 * 1000 + 60_000
        if !forceRefresh && expiresAtMs > oneMinuteFromNow { return token }

        guard let refreshToken = oauth["refreshToken"] as? String, !refreshToken.isEmpty else {
            throw CredentialsError.noRefreshToken
        }

        let fresh = try exchange(refreshToken: refreshToken, scopes: oauth["scopes"] as? [String])
        oauth["accessToken"] = fresh.accessToken
        oauth["refreshToken"] = fresh.refreshToken ?? refreshToken
        oauth["expiresAt"] = fresh.expiresAtMs
        if let refreshExpiry = fresh.refreshTokenExpiresAtMs {
            oauth["refreshTokenExpiresAt"] = refreshExpiry
        }
        stored["claudeAiOauth"] = oauth
        // A failed write only costs us one extra refresh next time around, so it is
        // never worth failing the whole fetch over.
        try? write(stored)
        return fresh.accessToken
    }

    // MARK: - Keychain

    private static func read() throws -> [String: Any] {
        let raw = try security(["find-generic-password", "-a", account, "-w", "-s", service])
        guard let data = raw.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CredentialsError.malformed
        }
        return json
    }

    private static func write(_ credentials: [String: Any]) throws {
        guard let oauth = credentials["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty,
              let refresh = oauth["refreshToken"] as? String, !refresh.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: credentials) else {
            throw CredentialsError.malformed   // never overwrite a good item with junk
        }
        // -X takes the secret as hex, which keeps it out of shell quoting entirely.
        let hex = data.map { String(format: "%02X", $0) }.joined()
        _ = try security(["add-generic-password", "-U", "-a", account, "-s", service, "-X", hex])
    }

    private static func security(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() } catch { throw CredentialsError.keychainUnavailable }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        _ = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CredentialsError.keychainUnavailable }
        return String(decoding: output, as: UTF8.self)
    }

    // MARK: - Refresh

    private struct FreshToken {
        let accessToken: String
        let refreshToken: String?
        let expiresAtMs: Double
        let refreshTokenExpiresAtMs: Double?
    }

    private static func exchange(refreshToken: String, scopes: [String]?) throws -> FreshToken {
        var body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        // Ask for exactly the scopes already granted, so the refreshed token stays
        // equivalent to the one Claude Code is using.
        if let scopes, !scopes.isEmpty { body["scope"] = scopes.joined(separator: " ") }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, status) = try HTTP.send(request)
        guard status == 200 else {
            throw CredentialsError.refreshFailed("HTTP \(status)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty else {
            throw CredentialsError.refreshFailed("неочікувана відповідь")
        }
        let lifetime = (json["expires_in"] as? Double) ?? 3600
        let refreshLifetime = json["refresh_token_expires_in"] as? Double
        let nowMs = Date().timeIntervalSince1970 * 1000
        return FreshToken(
            accessToken: access,
            refreshToken: json["refresh_token"] as? String,
            expiresAtMs: nowMs + lifetime * 1000,
            refreshTokenExpiresAtMs: refreshLifetime.map { nowMs + $0 * 1000 }
        )
    }
}

/// Minimal blocking HTTP, for use off the main thread.
enum HTTP {
    static func send(_ request: URLRequest) throws -> (Data, Int) {
        var result: Result<(Data, Int), Error>!
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                result = .success((data ?? Data(), status))
            }
            done.signal()
        }.resume()
        done.wait()
        return try result.get()
    }
}
