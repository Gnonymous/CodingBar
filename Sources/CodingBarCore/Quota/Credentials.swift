import Foundation

// MARK: - Credential reading for online quota fetch (ported from the Agnos approach).
//
// The single most important detail here is *how we read the Claude Code OAuth
// token without re-prompting for the keychain password on every read*.
//
// macOS authorizes keychain access against the *calling process'* code identity.
// CodingBar is self-signed with no Team ID, so a direct `SecItemCopyMatching` on
// the `Claude Code-credentials` item (owned by Claude Code) is not durably
// trusted and macOS re-prompts for the keychain password every time. By contrast
// `/usr/bin/security` is Apple-signed and sits in that item's trusted-application
// ACL / `apple-tool:` partition, so it reads the secret silently. Spawning it
// makes `security` (not CodingBar) the authorized caller — no popup.
//
// If the read fails for any reason we degrade to "credential unavailable" and the
// quota simply does not show, rather than nagging the user with a password box.

public enum CredentialStatus: Sendable, Equatable {
    case valid
    case expired
    case notFound
    case parseError
}

public struct UsageCredential: Sendable, Equatable {
    public let token: String?
    public let accountID: String?
    public let status: CredentialStatus
    public let message: String?

    public init(token: String?, accountID: String? = nil, status: CredentialStatus, message: String? = nil) {
        self.token = token
        self.accountID = accountID
        self.status = status
        self.message = message
    }
}

/// Reads a generic-password keychain item by shelling out to the Apple-signed
/// `/usr/bin/security` tool, so the keychain authorizes `security` (silent) and
/// not our self-signed process (which would re-prompt). Returns nil on any
/// failure so callers fall through to a file-based credential.
public struct SecurityCommandReader: Sendable {
    public typealias Runner = @Sendable (_ executable: URL, _ arguments: [String], _ timeout: TimeInterval) -> (status: Int32, stdout: Data)?

    public var executableURL = URL(fileURLWithPath: "/usr/bin/security")
    public var timeout: TimeInterval = 4
    public var runner: Runner = { SecurityCommandReader.defaultRunner(executable: $0, arguments: $1, timeout: $2) }

    public init() {}

    /// Raw secret bytes for `service`, or nil when the tool failed, timed out,
    /// produced no output, or the item was not found.
    public func genericPassword(service: String) -> Data? {
        let arguments = ["find-generic-password", "-s", service, "-w"]
        guard let result = runner(executableURL, arguments, timeout),
              result.status == 0,
              !result.stdout.isEmpty else {
            return nil
        }
        // `security -w` appends a trailing newline after the password bytes.
        var data = result.stdout
        if data.last == 0x0A { data.removeLast() }
        return data.isEmpty ? nil : data
    }

    public static func defaultRunner(executable: URL, arguments: [String], timeout: TimeInterval) -> (status: Int32, stdout: Data)? {
        // Use the shared event-driven runner with a hard SIGKILL timeout. The old
        // implementation here did a blocking `readDataToEndOfFile()` + `waitUntilExit()`
        // and a SIGTERM-only watchdog, so a `security` tool that wedged in
        // uninterruptible I/O (or ignored SIGTERM) could block this thread forever and
        // stall every subsequent quota refresh on the QuotaService actor. `Subprocess.run`
        // never blocks a thread on the child and force-kills it past the timeout.
        guard let result = Subprocess.run(executable, arguments, timeout: timeout) else { return nil }
        return (result.status, result.stdout)
    }
}

// MARK: - Credential parsing

public enum CredentialParser {

    /// Parse the Claude Code keychain JSON (`claudeAiOauth.accessToken` + `expiresAt`).
    public static func parseClaudeCredentials(data: Data, now: Date = Date(), language: AppLanguage = .en) -> UsageCredential {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            return UsageCredential(token: nil, status: .parseError, message: language.t("Claude credential: invalid JSON", "Claude 凭证 JSON 解析失败"))
        }
        guard let entry = (root["claudeAiOauth"] ?? root["claude.ai_oauth"]) as? [String: Any] else {
            return UsageCredential(token: nil, status: .parseError, message: language.t("Claude credential: missing OAuth field", "Claude 凭证缺少 OAuth 字段"))
        }
        guard let token = entry["accessToken"] as? String, !token.isEmpty else {
            return UsageCredential(token: nil, status: .parseError, message: language.t("Claude credential: missing accessToken", "Claude accessToken 缺失"))
        }
        if let expiresAt = entry["expiresAt"], isExpired(expiresAt, now: now) {
            return UsageCredential(token: token, status: .expired, message: language.t("Claude Code needs re-login", "Claude Code 需要重新登录"))
        }
        return UsageCredential(token: token, status: .valid)
    }

    /// Parse the Codex `auth.json` (`auth_mode == chatgpt`, `tokens.access_token`,
    /// `tokens.account_id`, `last_refresh`).
    public static func parseCodexCredentials(data: Data, now: Date = Date(), language: AppLanguage = .en) -> UsageCredential {
        guard let auth = try? JSONDecoder().decode(CodexAuthFile.self, from: data) else {
            return UsageCredential(token: nil, status: .parseError, message: language.t("Codex credential: parse failed", "Codex 凭证解析失败"))
        }
        guard auth.authMode == "chatgpt" else {
            return UsageCredential(token: nil, status: .notFound, message: language.t("Codex not signed in with OAuth", "Codex 未使用 OAuth 登录"))
        }
        guard let token = auth.tokens?.accessToken, !token.isEmpty else {
            return UsageCredential(token: nil, status: .parseError, message: language.t("Codex credential: missing access_token", "Codex access_token 缺失"))
        }
        // `last_refresh` is only when the CLI last refreshed the token, NOT an expiry:
        // Codex `auth.json` carries no expiry field and the refresh token is long-lived,
        // so a weeks-old `last_refresh` says nothing about whether the access token still
        // works. The authoritative expiry signal is the endpoint's 401/403, handled in
        // CodexQuotaFetcher (→ authFailed). An earlier 8-day staleness heuristic here
        // false-negatived active sessions (any user idle >8 days saw "Codex unavailable"
        // despite a valid token), so a present token is treated as valid and the server
        // is left to decide.
        return UsageCredential(token: token, accountID: auth.tokens?.accountID, status: .valid)
    }

    // MARK: - Expiry helpers

    private static func isExpired(_ value: Any, now: Date) -> Bool {
        if let timestamp = value as? Double { return date(fromTimestamp: timestamp) < now }
        if let timestamp = value as? Int { return date(fromTimestamp: Double(timestamp)) < now }
        if let string = value as? String, let d = parseDateTime(string) { return d < now }
        return false
    }

    private static func date(fromTimestamp timestamp: Double) -> Date {
        // Tolerate both seconds and milliseconds epochs.
        let seconds = timestamp > 1_000_000_000_000 ? timestamp / 1_000 : timestamp
        return Date(timeIntervalSince1970: seconds)
    }

    private static func parseDateTime(_ value: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: value) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: value) { return d }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        if let d = formatter.date(from: value) { return d }
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: value)
    }
}

// MARK: - Codex auth.json shape

private struct CodexAuthFile: Decodable {
    let authMode: String?
    let lastRefresh: String?
    let tokens: CodexAuthTokens?
    enum CodingKeys: String, CodingKey {
        case authMode = "auth_mode"
        case lastRefresh = "last_refresh"
        case tokens
    }
}

private struct CodexAuthTokens: Decodable {
    let accessToken: String?
    let accountID: String?
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case accountID = "account_id"
    }
}
