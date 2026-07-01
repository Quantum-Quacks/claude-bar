import Foundation
import Security

struct UsageWindow {
    var utilization: Double
    var resetsAt: Date?

    /// Percentage to show now. Past the reset boundary the real utilization is
    /// back to zero, which covers the gap between a reset and the next poll.
    func effectivePercentage(at now: Date) -> Double {
        if let resetsAt, now >= resetsAt { return 0 }
        return min(max(utilization, 0), 100)
    }
}

struct Usage {
    var fiveHour: UsageWindow?
    var sevenDay: UsageWindow?
    var plan: String?      // subscription tier from the token, e.g. "max"
    var fetchedAt: Date
}

enum UsageError: Error {
    case noToken          // not logged in, or this app lacks keychain access
    case unauthorized     // token expired/invalid
    case rateLimited      // 429 — back off
    case transport        // network/parse failure
}

/// Reads Claude Code usage straight from the endpoint the official client uses
/// (`/usage`, and the VSCode/Cursor extension's own usage display). Same OAuth
/// token from the login keychain, same first-party endpoint — nothing here that
/// the editor isn't already doing.
enum UsageClient {
    /// Sent as `claude-code/<version>`; the endpoint throttles generic agents.
    static let clientVersion = "2.1.168"

    /// Usage for the currently-active login (the live keychain token). Reads the
    /// keychain on every call — prefer caching the token (see liveCredentials).
    static func fetch() async -> Result<Usage, UsageError> {
        guard let creds = liveCredentials() else { return .failure(.noToken) }
        return await usage(accessToken: creds.token, plan: creds.plan)
    }

    /// Usage for an explicit access token — used to show each saved account's
    /// numbers without making it the active login. `plan` is the tier to label
    /// the result with (the endpoint doesn't echo it back).
    static func usage(accessToken: String, plan: String?) async -> Result<Usage, UsageError> {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 10
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/\(clientVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else { return .failure(.transport) }

        switch http.statusCode {
        case 200: break
        case 401, 403: return .failure(.unauthorized)
        case 429: return .failure(.rateLimited)
        default: return .failure(.transport)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .failure(.transport) }
        return .success(Usage(
            fiveHour: window(from: json["five_hour"]),
            sevenDay: window(from: json["seven_day"]),
            plan: plan,
            fetchedAt: Date()))
    }

    // MARK: - OAuth refresh

    /// Public OAuth client id Claude Code itself uses; the token endpoint accepts
    /// it for the refresh_token grant.
    private static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    struct RefreshedTokens {
        let accessToken: String
        let refreshToken: String?   // nil when the server didn't rotate it
        let expiresAt: Date
    }

    enum RefreshError: Error {
        case revoked      // invalid_grant — the refresh token was spent or revoked
        case transport
        case parse
    }

    /// Exchange a refresh token for a fresh access token. Rotation means the old
    /// refresh token is spent on success, so the caller MUST persist the result
    /// immediately or it strands the account.
    static func refresh(refreshToken: String) async -> Result<RefreshedTokens, RefreshError> {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/oauth/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("claude-code/\(clientVersion)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": oauthClientID,
        ])

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else { return .failure(.transport) }

        switch http.statusCode {
        case 200: break
        case 400, 401: return .failure(.revoked)
        default: return .failure(.transport)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty
        else { return .failure(.parse) }
        let lifetime = (json["expires_in"] as? Double) ?? 8 * 3600
        return .success(RefreshedTokens(
            accessToken: access,
            refreshToken: json["refresh_token"] as? String,
            expiresAt: Date().addingTimeInterval(lifetime)))
    }

    // MARK: - Keychain

    /// The Claude Code login token (tier + expiry), stored as a generic password
    /// under service "Claude Code-credentials". Reading another app's item
    /// prompts for consent on first launch ("Always Allow" makes it stick, now
    /// that the app is stably signed); falls back to ~/.claude/.credentials.json
    /// (headless/Linux-style installs). Callers should cache the returned token
    /// until `expiresAt` rather than re-reading every poll — each read is a
    /// potential keychain prompt.
    static func liveCredentials() -> (token: String, plan: String?, expiresAt: Date?)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data, let creds = credentials(from: data) {
            return creds
        }
        let fileURL = URL(fileURLWithPath:
            NSString(string: "~/.claude/.credentials.json").expandingTildeInPath)
        if let data = try? Data(contentsOf: fileURL), let creds = credentials(from: data) {
            return creds
        }
        return nil
    }

    private static func credentials(from data: Data) -> (token: String, plan: String?, expiresAt: Date?)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        let expiresAt = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return (token, oauth["subscriptionType"] as? String, expiresAt)
    }

    /// Reads the signed-in account email from Claude Code's ~/.claude.json (a
    /// plain file — no keychain access, no prompt).
    static func accountEmail() -> String? {
        let url = URL(fileURLWithPath:
            NSString(string: "~/.claude.json").expandingTildeInPath)
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = json["oauthAccount"] as? [String: Any],
              let email = account["emailAddress"] as? String, !email.isEmpty
        else { return nil }
        return email
    }

    // MARK: - Live-token cache (owned by this app → no prompt)

    /// Service for *our own* copy of the active login's token. Reading Claude
    /// Code's "Claude Code-credentials" item prompts (we don't own it); this
    /// item is created by claude-bar, so reading it never prompts. We bootstrap
    /// from the CLI item once, keep a copy here, and read the CLI item again
    /// only when this copy is missing or expired. The token is the same secret
    /// already in the login keychain — same security posture as saved profiles.
    private static let liveCacheService = "ClaudeBar-live-token-cache"

    /// Our cached copy for `email`, or nil if absent, for a different account,
    /// or unreadable. Never prompts.
    static func cachedLiveCredentials(forEmail email: String?)
        -> (token: String, plan: String?, expiresAt: Date?)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: liveCacheService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String, !token.isEmpty
        else { return nil }
        // Only serve the copy when we're sure it's the same login. If the active
        // email is known and doesn't match (or the copy is unlabelled), reject
        // and let the caller re-read the CLI item for the right account. A nil
        // active email means ~/.claude.json was caught mid-rewrite — serve the
        // copy anyway; a genuinely wrong token 401s and gets cleared.
        if let email, (json["email"] as? String) != email { return nil }
        let plan = json["plan"] as? String
        let expiresAt = (json["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
        return (token, plan, expiresAt)
    }

    /// Persist our copy so a restart doesn't re-read the CLI item (a prompt).
    static func storeLiveCredentials(
        token: String, plan: String?, expiresAt: Date?, email: String?) {
        var payload: [String: Any] = ["token": token]
        if let plan { payload["plan"] = plan }
        if let expiresAt { payload["expiresAt"] = expiresAt.timeIntervalSince1970 }
        if let email { payload["email"] = email }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: liveCacheService,
        ]
        let status = SecItemUpdate(
            query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    /// Drop our copy — on account switch or when the token is rejected.
    static func clearCachedLiveCredentials() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: liveCacheService,
        ] as CFDictionary)
    }

    // MARK: - Parsing

    private static func window(from value: Any?) -> UsageWindow? {
        guard let dict = value as? [String: Any],
              let utilization = dict["utilization"] as? Double
        else { return nil }
        return UsageWindow(utilization: utilization, resetsAt: date(from: dict["resets_at"]))
    }

    /// `resets_at` is ISO 8601 with fractional seconds (e.g.
    /// "2026-06-12T11:10:00.121609+00:00"); tolerate epoch numbers too.
    private static func date(from value: Any?) -> Date? {
        switch value {
        case let seconds as Double:
            return Date(timeIntervalSince1970: seconds > 1e12 ? seconds / 1000 : seconds)
        case let string as String:
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: string) { return date }
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: string)
        default:
            return nil
        }
    }
}
