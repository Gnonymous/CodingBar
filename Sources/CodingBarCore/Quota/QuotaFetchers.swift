import Foundation

// MARK: - Online quota fetchers.
//
// Each fetcher reads its OAuth token from the local keychain/credential file
// (silently, via SecurityCommandReader) and GETs the provider's official usage
// endpoint. token / cost / behavior data stays 100% local; ONLY these quota
// reads touch the network, carrying the user's own OAuth token to read their own
// usage. On any failure they return empty windows plus a human note, never throw.

public struct QuotaFetchResult: Sendable {
    public var windows: [QuotaWindow]
    public var note: String?    // degradation message for the UI, nil on success
    public var authFailed: Bool // true for 401/403/expired — won't recover on its own
    // true when the endpoint answered 2xx but its body no longer parses into any known
    // window (the response schema likely changed). Distinct from a transient transport
    // failure: this note must be surfaced even while last-good windows are still shown,
    // or a silently-broken API parse would hide behind a slowly-ageing freshness label.
    public var schemaFailed: Bool
    public init(windows: [QuotaWindow] = [], note: String? = nil, authFailed: Bool = false, schemaFailed: Bool = false) {
        self.windows = windows
        self.note = note
        self.authFailed = authFailed
        self.schemaFailed = schemaFailed
    }
}

// MARK: - Shared HTTP helper

enum QuotaHTTP {
    /// GET `url` with `headers`; returns (statusCode, body) or nil on transport error.
    static func get(_ url: URL, headers: [String: String], timeout: TimeInterval = 10) async -> (status: Int, body: Data)? {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            return (http.statusCode, data)
        } catch {
            return nil
        }
    }

    static func isoFractional(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

// MARK: - Claude Code quota

public struct ClaudeQuotaFetcher: Sendable {
    private static let service = "Claude Code-credentials"
    private let reader: SecurityCommandReader
    private let credentialsURL: URL

    public init(reader: SecurityCommandReader = SecurityCommandReader(),
                credentialsURL: URL = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".claude").appendingPathComponent(".credentials.json")) {
        self.reader = reader
        self.credentialsURL = credentialsURL
    }

    public func fetch(now: Date = Date(), language: AppLanguage = .en) async -> QuotaFetchResult {
        let credential = readCredential(now: now, language: language)
        guard let token = credential.token else {
            // No token at all → quota silently unavailable (no popup, no note clutter
            // unless the credential was explicitly broken).
            return QuotaFetchResult(note: credential.status == .parseError ? credential.message : nil)
        }
        if credential.status == .expired {
            return QuotaFetchResult(note: credential.message ?? language.t("Claude Code needs re-login", "Claude Code 需要重新登录"), authFailed: true)
        }

        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            return QuotaFetchResult(note: language.t("Claude usage endpoint URL invalid", "Claude 用量接口地址无效"))
        }
        let headers = [
            "Authorization": "Bearer \(token)",
            "anthropic-beta": "oauth-2025-04-20",
            "Accept": "application/json",
        ]
        guard let (status, body) = await QuotaHTTP.get(url, headers: headers) else {
            return QuotaFetchResult(note: language.t("Claude usage fetch failed", "Claude 用量读取失败"))
        }
        if status == 401 || status == 403 {
            return QuotaFetchResult(note: language.t("Claude Code needs re-login", "Claude Code 需要重新登录"), authFailed: true)
        }
        guard (200..<300).contains(status) else {
            return QuotaFetchResult(note: language.t("Claude usage error: HTTP \(status)", "Claude 用量接口错误 HTTP \(status)"))
        }
        let windows = Self.parse(body)
        if windows.isEmpty {
            // HTTP was 2xx but no known windows parsed. A non-empty body yielding
            // nothing usually means the (private) endpoint's response shape changed —
            // distinct from a genuine "no quota" state, so it must not look like "0 used".
            return body.isEmpty
                ? QuotaFetchResult(note: language.t("No Claude quota data yet", "Claude 暂无额度数据"))
                : QuotaFetchResult(note: language.t("Claude quota data malformed (API fields may have changed)", "Claude 额度数据异常（接口字段可能已变更）"), schemaFailed: true)
        }
        return QuotaFetchResult(windows: windows)
    }

    public static func parse(_ data: Data) -> [QuotaWindow] {
        guard let response = try? JSONDecoder().decode(ClaudeUsageResponse.self, from: data) else { return [] }
        let tiers: [(String, ClaudeUsageTier?)] = [
            ("5h", response.fiveHour),
            ("7d", response.sevenDay),
            ("7d·Opus", response.sevenDayOpus),
            ("7d·Sonnet", response.sevenDaySonnet),
        ]
        return tiers.compactMap { label, tier -> QuotaWindow? in
            guard let tier else { return nil }
            let remaining = max(0, min(1, 1 - tier.utilization / 100))
            return QuotaWindow(provider: .claude, label: label, remaining: remaining,
                               resetAt: QuotaHTTP.isoFractional(tier.resetsAt))
        }
    }

    private func readCredential(now: Date, language: AppLanguage) -> UsageCredential {
        // Preferred: Apple-signed `security` CLI reads the keychain item silently.
        if let data = reader.genericPassword(service: Self.service) {
            let c = CredentialParser.parseClaudeCredentials(data: data, now: now, language: language)
            if c.token != nil { return c }
        }
        // Fallback: plaintext credentials file (uncommon on macOS).
        if FileManager.default.fileExists(atPath: credentialsURL.path),
           let data = try? Data(contentsOf: credentialsURL) {
            let c = CredentialParser.parseClaudeCredentials(data: data, now: now, language: language)
            if c.token != nil { return c }
        }
        // Deliberately no direct SecItemCopyMatching here: it would re-trigger the
        // keychain password prompt for our self-signed process. Degrade instead.
        return UsageCredential(token: nil, status: .notFound)
    }
}

// MARK: - Codex quota

public struct CodexQuotaFetcher: Sendable {
    private static let service = "Codex Auth"
    private let reader: SecurityCommandReader
    private let authURL: URL

    public init(reader: SecurityCommandReader = SecurityCommandReader(),
                authURL: URL = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".codex").appendingPathComponent("auth.json")) {
        self.reader = reader
        self.authURL = authURL
    }

    public func fetch(now: Date = Date(), language: AppLanguage = .en) async -> QuotaFetchResult {
        let credential = readCredential(now: now, language: language)
        guard let token = credential.token else {
            return QuotaFetchResult(note: credential.status == .parseError ? credential.message : nil)
        }
        if credential.status == .expired {
            return QuotaFetchResult(note: credential.message ?? language.t("Codex needs re-login", "Codex 需要重新登录"), authFailed: true)
        }

        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            return QuotaFetchResult(note: language.t("Codex usage endpoint URL invalid", "Codex 用量接口地址无效"))
        }
        var headers = [
            "Authorization": "Bearer \(token)",
            "User-Agent": "codex-cli",
            "Accept": "application/json",
        ]
        if let accountID = credential.accountID, !accountID.isEmpty {
            headers["ChatGPT-Account-Id"] = accountID
        }
        guard let (status, body) = await QuotaHTTP.get(url, headers: headers) else {
            return QuotaFetchResult(note: language.t("Codex usage fetch failed", "Codex 用量读取失败"))
        }
        if status == 401 || status == 403 {
            return QuotaFetchResult(note: language.t("Codex needs re-login", "Codex 需要重新登录"), authFailed: true)
        }
        guard (200..<300).contains(status) else {
            return QuotaFetchResult(note: language.t("Codex usage error: HTTP \(status)", "Codex 用量接口错误 HTTP \(status)"))
        }
        let windows = Self.parse(body)
        if windows.isEmpty {
            return body.isEmpty
                ? QuotaFetchResult(note: language.t("No Codex quota data yet", "Codex 暂无额度数据"))
                : QuotaFetchResult(note: language.t("Codex quota data malformed (API fields may have changed)", "Codex 额度数据异常（接口字段可能已变更）"), schemaFailed: true)
        }
        return QuotaFetchResult(windows: windows)
    }

    public static func parse(_ data: Data) -> [QuotaWindow] {
        guard let response = try? JSONDecoder().decode(CodexUsageResponse.self, from: data),
              let rl = response.rateLimit else { return [] }
        return [rl.primaryWindow, rl.secondaryWindow].compactMap { window -> QuotaWindow? in
            guard let window, let usedPercent = window.usedPercent else { return nil }
            let remaining = max(0, min(1, 1 - usedPercent / 100))
            return QuotaWindow(provider: .codex,
                               label: codexLabel(seconds: window.limitWindowSeconds),
                               remaining: remaining,
                               resetAt: window.resetAt.map { Date(timeIntervalSince1970: TimeInterval($0)) })
        }
    }

    private static func codexLabel(seconds: Int?) -> String {
        switch seconds {
        case 18_000:  return "5h"
        case 604_800: return "7d"
        case .some(let v): return "\(v / 3600)h"
        case nil: return "?"
        }
    }

    private func readCredential(now: Date, language: AppLanguage) -> UsageCredential {
        // File is the macOS default for Codex; try it first (no keychain at all).
        if FileManager.default.fileExists(atPath: authURL.path),
           let data = try? Data(contentsOf: authURL) {
            let c = CredentialParser.parseCodexCredentials(data: data, now: now, language: language)
            if c.token != nil { return c }
        }
        // Fallback: keychain item via the Apple-signed `security` CLI (silent).
        if let data = reader.genericPassword(service: Self.service) {
            let c = CredentialParser.parseCodexCredentials(data: data, now: now, language: language)
            if c.token != nil { return c }
        }
        return UsageCredential(token: nil, status: .notFound)
    }
}

// MARK: - Response shapes

private struct ClaudeUsageResponse: Decodable {
    let fiveHour: ClaudeUsageTier?
    let sevenDay: ClaudeUsageTier?
    let sevenDayOpus: ClaudeUsageTier?
    let sevenDaySonnet: ClaudeUsageTier?
    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
    }
}

private struct ClaudeUsageTier: Decodable {
    let utilization: Double
    let resetsAt: String?
    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

private struct CodexUsageResponse: Decodable {
    let rateLimit: CodexRateLimit?
    enum CodingKeys: String, CodingKey { case rateLimit = "rate_limit" }
}

private struct CodexRateLimit: Decodable {
    let primaryWindow: CodexWindow?
    let secondaryWindow: CodexWindow?
    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

private struct CodexWindow: Decodable {
    let usedPercent: Double?
    let resetAt: Int?
    let limitWindowSeconds: Int?
    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case resetAt = "reset_at"
        case limitWindowSeconds = "limit_window_seconds"
    }
}
