import Foundation
import Security

/// Saves, lists, and switches between named Claude accounts.
///
/// A Claude login lives in two places: the OAuth blob in the login keychain
/// (`Claude Code-credentials`) and the identity fields in `~/.claude.json`
/// (`oauthAccount` + `userID`). A profile captures both together so a switch is
/// a single atomic swap. Profiles are themselves stored in the keychain, one
/// generic-password item per name under the service `ClaudeBar-account`, so the
/// refresh tokens never touch disk in the clear.
///
/// Switching rewrites the live keychain item and patches `~/.claude.json`. Any
/// `claude` session started afterward uses the new account immediately; sessions
/// already running keep the token they cached in memory until they restart (or
/// you run `/login` inside them) — nothing here can reach into a live process.
enum AccountStore {
    /// Service namespace for our saved profiles. The profile name is the item's
    /// account attribute, so listing is a single scoped query.
    private static let profileService = "ClaudeBar-account"
    /// The live item Claude Code itself reads on startup.
    private static let liveService = "Claude Code-credentials"

    private static var claudeJSONURL: URL {
        URL(fileURLWithPath: NSString(string: "~/.claude.json").expandingTildeInPath)
    }

    // MARK: - Model

    /// Everything needed to restore one login. Data fields encode as base64 in
    /// the stored JSON; `email`/`plan` are denormalized for cheap menu display.
    private struct Profile: Codable {
        var credentials: Data        // raw bytes of the "Claude Code-credentials" item
        var oauthAccount: Data       // JSON of the ~/.claude.json oauthAccount object
        var userID: String?
        var email: String?
        var plan: String?
    }

    /// Lightweight row for the menu.
    struct Listed {
        let name: String
        let email: String?
        let plan: String?
        let userID: String?
    }

    /// Non-secret display fields, mirrored into the item's `kSecAttrGeneric`
    /// attribute. Listing reads these *without* decrypting anything: pulling the
    /// secret data for every match in one query (`kSecReturnData` +
    /// `kSecMatchLimitAll`) is rejected with errSecParam on macOS, and even a
    /// per-item decrypt would prompt while the menu is being built. `userID`
    /// lets the menu recognise the active account without a keychain read.
    private struct Meta: Codable {
        var email: String?
        var plan: String?
        var userID: String?
    }

    enum StoreError: LocalizedError {
        case noActiveCredentials
        case profileNotFound
        case nameTaken(String)
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .noActiveCredentials:
                return "No active Claude Code login was found to save. Sign in with Claude Code first."
            case .profileNotFound:
                return "That saved account no longer exists."
            case .nameTaken(let name):
                return "There's already a saved account named “\(name)”. Pick another name."
            case .keychain(let status):
                let msg = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
                return "Keychain error: \(msg)"
            }
        }
    }

    // MARK: - List

    static func list() -> [Listed] {
        // Attributes only — never request the secret data here. A query that asks
        // for data across all matches returns errSecParam on macOS, which would
        // make this silently return [] and hide every saved account.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: profileService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item -> Listed? in
            guard let name = item[kSecAttrAccount as String] as? String else { return nil }
            let meta = (item[kSecAttrGeneric as String] as? Data)
                .flatMap { try? JSONDecoder().decode(Meta.self, from: $0) }
            return Listed(name: name, email: meta?.email, plan: meta?.plan, userID: meta?.userID)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Save

    /// Snapshot the currently-active login under `name`, overwriting any profile
    /// with the same name.
    static func saveCurrent(as name: String) throws {
        guard let credentials = readLive() else { throw StoreError.noActiveCredentials }
        let identity = readIdentity()
        let planName = plan(from: credentials)
        let profile = Profile(
            credentials: credentials,
            oauthAccount: identity.oauthAccount ?? Data(),
            userID: identity.userID,
            email: identity.email,
            plan: planName)
        let data = try JSONEncoder().encode(profile)
        // Mirror the display fields into the (non-secret) generic attribute so
        // list() can show them — and recognise the active account — without
        // decrypting the profile.
        let meta = try? JSONEncoder().encode(
            Meta(email: identity.email, plan: planName, userID: identity.userID))
        try upsert(service: profileService, account: name, data: data, generic: meta)
    }

    // MARK: - Switch

    /// Make the saved profile `name` the active login.
    static func activate(_ name: String) throws {
        guard let data = read(service: profileService, account: name),
              let profile = try? JSONDecoder().decode(Profile.self, from: data)
        else { throw StoreError.profileNotFound }

        // 1) Live keychain — update by service only so the existing item (and the
        // access grant Claude Code relies on) is preserved, just with new data.
        try upsert(service: liveService, account: nil, data: profile.credentials)

        // 2) Identity in ~/.claude.json, read-modify-write so nothing else is lost.
        patchIdentity(oauthAccount: profile.oauthAccount, userID: profile.userID)
    }

    static func remove(_ name: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: profileService,
            kSecAttrAccount as String: name,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Rename a saved profile in place (changes only its account attribute, so
    /// the stored credentials and keychain access grant are preserved).
    static func rename(_ old: String, to new: String) throws {
        let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != old else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: profileService,
            kSecAttrAccount as String: old,
        ]
        let status = SecItemUpdate(
            query as CFDictionary, [kSecAttrAccount as String: trimmed] as CFDictionary)
        guard status != errSecDuplicateItem else {
            throw StoreError.nameTaken(trimmed)
        }
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
    }

    /// Email of the login currently active on disk, for marking the menu check.
    static func activeEmail() -> String? { readIdentity().email }

    /// User id of the active login (from ~/.claude.json — no keychain, no prompt).
    static func activeUserID() -> String? { readIdentity().userID }

    // MARK: - Token refresh

    /// A usable access token for the saved profile `name`. If the snapshot's
    /// access token has expired, refresh it via the OAuth refresh token and
    /// persist the rotated credentials back into the profile so the new refresh
    /// token is never lost. Returns nil if the profile is gone or the refresh
    /// token was revoked.
    ///
    /// Callers must NOT use this for the active account — refreshing a token
    /// chain Claude Code also holds would rotate it out from under a live
    /// session. The active account's usage comes from the live keychain instead.
    static func freshAccessToken(for name: String) async -> (token: String, plan: String?, expiresAt: Date?)? {
        guard let data = read(service: profileService, account: name),
              var profile = try? JSONDecoder().decode(Profile.self, from: data),
              let snap = oauth(from: profile.credentials)
        else { return nil }

        // Is this snapshot the active login? Match on email only — the
        // per-account identity. (userID in ~/.claude.json is per-machine, shared
        // across accounts, so it would mark every profile active.) Never refresh
        // the active account: that rotates the token Claude Code holds live. The
        // caller shows live usage for it anyway, so hand back the snapshot token.
        let identity = readIdentity()
        if let email = profile.email, email == identity.email {
            return (snap.accessToken, profile.plan, snap.expiresAt)
        }

        // Inactive and still valid (5-min margin)? Use it as-is — no rotation.
        if let expiresAt = snap.expiresAt, expiresAt.timeIntervalSinceNow > 300 {
            return (snap.accessToken, profile.plan, snap.expiresAt)
        }
        guard let refreshToken = snap.refreshToken else {
            return (snap.accessToken, profile.plan, snap.expiresAt)   // best effort
        }

        switch await UsageClient.refresh(refreshToken: refreshToken) {
        case .success(let tokens):
            let blob = rewriteOAuth(
                profile.credentials,
                accessToken: tokens.accessToken,
                refreshToken: tokens.refreshToken ?? refreshToken,
                expiresAt: tokens.expiresAt)
            profile.credentials = blob
            profile.plan = plan(from: blob)
            if let encoded = try? JSONEncoder().encode(profile) {
                let meta = try? JSONEncoder().encode(
                    Meta(email: profile.email, plan: profile.plan, userID: profile.userID))
                try? upsert(service: profileService, account: name, data: encoded, generic: meta)
            }
            return (tokens.accessToken, profile.plan, tokens.expiresAt)
        case .failure:
            return nil
        }
    }

    private static func oauth(from blob: Data)
        -> (accessToken: String, refreshToken: String?, expiresAt: Date?)? {
        guard let json = try? JSONSerialization.jsonObject(with: blob) as? [String: Any],
              let o = json["claudeAiOauth"] as? [String: Any],
              let access = o["accessToken"] as? String, !access.isEmpty
        else { return nil }
        let expiresAt = (o["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return (access, o["refreshToken"] as? String, expiresAt)
    }

    /// `blob` with the three OAuth fields replaced and every other field
    /// (scopes, subscriptionType, rateLimitTier) preserved.
    private static func rewriteOAuth(
        _ blob: Data, accessToken: String, refreshToken: String, expiresAt: Date) -> Data {
        guard var json = (try? JSONSerialization.jsonObject(with: blob)) as? [String: Any],
              var o = json["claudeAiOauth"] as? [String: Any]
        else { return blob }
        o["accessToken"] = accessToken
        o["refreshToken"] = refreshToken
        o["expiresAt"] = Int(expiresAt.timeIntervalSince1970 * 1000)
        json["claudeAiOauth"] = o
        return (try? JSONSerialization.data(withJSONObject: json)) ?? blob
    }

    // MARK: - Keychain helpers

    private static func readLive() -> Data? {
        read(service: liveService, account: nil)
    }

    private static func read(service: String, account: String?) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return data
    }

    private static func upsert(
        service: String, account: String?, data: Data, generic: Data? = nil) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account { query[kSecAttrAccount as String] = account }

        var attributes: [String: Any] = [kSecValueData as String: data]
        if let generic { attributes[kSecAttrGeneric as String] = generic }

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw StoreError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw StoreError.keychain(status)
        }
    }

    private static func plan(from credentials: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: credentials) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any]
        else { return nil }
        return oauth["subscriptionType"] as? String
    }

    // MARK: - ~/.claude.json identity

    private static func readIdentity() -> (oauthAccount: Data?, userID: String?, email: String?) {
        guard let data = try? Data(contentsOf: claudeJSONURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (nil, nil, nil) }
        let userID = json["userID"] as? String
        guard let account = json["oauthAccount"] as? [String: Any] else {
            return (nil, userID, nil)
        }
        let oauthData = try? JSONSerialization.data(withJSONObject: account)
        return (oauthData, userID, account["emailAddress"] as? String)
    }

    private static func patchIdentity(oauthAccount: Data, userID: String?) {
        guard let data = try? Data(contentsOf: claudeJSONURL),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        if !oauthAccount.isEmpty,
           let account = try? JSONSerialization.jsonObject(with: oauthAccount) {
            json["oauthAccount"] = account
        }
        if let userID { json["userID"] = userID }
        guard let out = try? JSONSerialization.data(
            withJSONObject: json, options: [.prettyPrinted, .withoutEscapingSlashes])
        else { return }
        // Atomic write: temp file + rename, so a crash mid-write can't truncate
        // the file Claude Code reads on every launch.
        try? out.write(to: claudeJSONURL, options: .atomic)
    }
}
