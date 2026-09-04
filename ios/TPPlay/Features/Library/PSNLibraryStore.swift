import Foundation
import OSLog
import Security

@MainActor
final class PSNLibraryStore: ObservableObject {
    static let shared = PSNLibraryStore()
    private static let profileRefreshInterval: TimeInterval = 120
    private static let presenceLog = Logger(subsystem: "com.mb14ck22.tpplay", category: "PSNPresence")

    @Published private(set) var profile: PSNProfilePreview?
    @Published private(set) var games: [TrophyGamePreview] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isProfileRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastSyncDate: Date?

    private var cache = PSNLibraryCache.empty
    private let credentialStore = PSNLibraryKeychain()
    private let cacheURL: URL

    var isSignedIn: Bool {
        do { return try credentialStore.load()?.clientID == PSNLibraryAuth.clientID }
        catch { return false }
    }
    var signedInOnlineID: String? {
        guard let credential = try? credentialStore.load(), credential.clientID == PSNLibraryAuth.clientID else { return nil }
        return credential.onlineID
    }
    var syncStatus: String {
        guard let lastSyncDate else { return isLoading ? "PSN SYNC // ACTIVE" : "PSN SYNC // READY" }
        return "PSN SYNC // \(lastSyncDate.formatted(.relative(presentation: .named)))"
    }

    static let loginURL: URL = {
        var components = URLComponents(string: PSNLibraryAuth.authorizeURL.absoluteString)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: PSNLibraryAuth.clientID),
            URLQueryItem(name: "redirect_uri", value: PSNLibraryAuth.redirectURI),
            URLQueryItem(name: "scope", value: PSNLibraryAuth.scopes),
            URLQueryItem(name: "token_format", value: "jwt"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "access_type", value: "offline"),
        ]
        return components.url!
    }()
    static let loginCallbackScheme = "com.scee.psxandroid.scecompcall"

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = base.appendingPathComponent("TPPlay", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cacheURL = directory.appendingPathComponent("psn-library-v1.json")
        if let data = try? Data(contentsOf: cacheURL),
           let saved = try? JSONDecoder.psn.decode(PSNLibraryCache.self, from: data) {
            cache = saved
            apply(saved)
        }
    }

    func signIn(from redirectText: String) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            guard let components = URLComponents(string: redirectText.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
                  !code.isEmpty else {
                throw PSNLibraryError.message("The pasted URL does not contain a PSN sign-in code.")
            }
            let credential = try await exchange(code: code)
            try credentialStore.save(credential)
            let sameAccount = cache.profile?.onlineID.caseInsensitiveCompare(credential.onlineID) == .orderedSame
            try await performSync(forceFull: !sameAccount || cache.games.isEmpty, credential: credential)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshProfile(force: Bool = false) async {
        guard isSignedIn, !isLoading, !isProfileRefreshing else { return }
        if !force,
           let refreshedAt = cache.lastProfileRefreshDate,
           Date().timeIntervalSince(refreshedAt) < Self.profileRefreshInterval {
            return
        }
        isProfileRefreshing = true
        errorMessage = nil
        defer { isProfileRefreshing = false }
        do {
            let credential = try await validCredential()
            let profileData = try? await requestJSON(
                absoluteURL: URL(string: "https://m.np.playstation.com/api/userProfile/v1/internal/users/\(credential.accountID)/profiles")!,
                token: credential.accessToken
            )
            let presence = await requestBasicPresence(accountID: credential.accountID, token: credential.accessToken)
            let localizedPresenceTitle = await requestLocalizedPresenceTitle(presence, token: credential.accessToken)
            let legacy = try? await requestJSON(
                absoluteURL: legacyProfileURL(onlineID: credential.onlineID),
                token: credential.accessToken
            )
            guard profileData != nil || presence != nil || legacy != nil else {
                throw PSNLibraryError.message("PSN profile status is temporarily unavailable.")
            }
            let refreshed = await makeProfile(
                summary: nil,
                profile: profileData,
                presence: presence,
                localizedPresenceTitle: localizedPresenceTitle,
                legacy: legacy,
                fallbackOnlineID: credential.onlineID,
                cached: cache.profile
            )
            cache = PSNLibraryCache(
                profile: refreshed,
                games: cache.games,
                lastSyncDate: cache.lastSyncDate,
                lastProfileRefreshDate: Date()
            )
            try persistCache()
            apply(cache)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sync(forceFull: Bool = false) async {
        guard !isLoading, !isProfileRefreshing else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let credential = try await validCredential()
            try await performSync(forceFull: forceFull, credential: credential)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOut() {
        do {
            try credentialStore.delete()
            cache = .empty
            profile = nil
            games = []
            lastSyncDate = nil
            errorMessage = nil
            try? FileManager.default.removeItem(at: cacheURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func performSync(forceFull: Bool, credential: PSNLibraryCredential) async throws {
        let summary = try await requestJSON(path: "/v1/users/me/trophySummary", token: credential.accessToken)
        let profileData = try? await requestJSON(
            absoluteURL: URL(string: "https://m.np.playstation.com/api/userProfile/v1/internal/users/\(credential.accountID)/profiles")!,
            token: credential.accessToken
        )
        let presence = await requestBasicPresence(accountID: credential.accountID, token: credential.accessToken)
        let localizedPresenceTitle = await requestLocalizedPresenceTitle(presence, token: credential.accessToken)
        let titles = try await fetchAllTitles(token: credential.accessToken)
        let previous = Dictionary(uniqueKeysWithValues: cache.games.map { ($0.communicationID, $0) })
        var syncedGames: [PSNCachedGame] = []

        for title in titles {
            let id = title.string("npCommunicationId")
            guard !id.isEmpty else { continue }
            let updated = title.string("lastUpdatedDateTime")
            if !forceFull, let saved = previous[id], saved.lastUpdated == updated, !saved.groups.isEmpty {
                syncedGames.append(saved)
            } else {
                do {
                    syncedGames.append(try await fetchGame(title: title, token: credential.accessToken))
                } catch {
                    // A single legacy/private title must not discard the rest of a full archive sync.
                    syncedGames.append(previous[id] ?? summaryOnlyGame(title))
                }
            }
        }

        let legacy = try? await requestJSON(
            absoluteURL: legacyProfileURL(onlineID: credential.onlineID),
            token: credential.accessToken
        )
        let newProfile = await makeProfile(summary: summary, profile: profileData, presence: presence, localizedPresenceTitle: localizedPresenceTitle, legacy: legacy, fallbackOnlineID: credential.onlineID, cached: cache.profile)
        cache = PSNLibraryCache(
            profile: newProfile,
            games: syncedGames,
            lastSyncDate: Date(),
            lastProfileRefreshDate: Date()
        )
        try persistCache()
        apply(cache)
    }

    private func validCredential() async throws -> PSNLibraryCredential {
        guard var credential = try credentialStore.load(), credential.clientID == PSNLibraryAuth.clientID else {
            throw PSNLibraryError.message("Sign in to PSN from Home first.")
        }
        if credential.expiresAt <= Date().addingTimeInterval(60) {
            credential = try await refresh(credential)
            try credentialStore.save(credential)
        }
        return credential
    }

    private func persistCache() throws {
        let data = try JSONEncoder.psn.encode(cache)
        try data.write(to: cacheURL, options: .atomic)
    }

    private func fetchAllTitles(token: String) async throws -> [[String: Any]] {
        var result: [[String: Any]] = []
        var offset = 0
        let limit = 100
        while true {
            let json = try await requestJSON(path: "/v1/users/me/trophyTitles?limit=\(limit)&offset=\(offset)", token: token)
            let page = json.array("trophyTitles")
            result.append(contentsOf: page)
            let total = json.int("totalItemCount")
            offset += page.count
            if page.isEmpty || offset >= total { break }
        }
        return result
    }

    private func fetchGame(title: [String: Any], token: String) async throws -> PSNCachedGame {
        let communicationID = title.string("npCommunicationId")
        let service = title.string("npServiceName").isEmpty
            ? (title.string("trophyTitlePlatform").contains("PS5") ? "trophy2" : "trophy")
            : title.string("npServiceName")
        let query = "?npServiceName=\(service)&limit=500"
        let groups = try await requestJSON(path: "/v1/npCommunicationIds/\(communicationID)/trophyGroups\(query)", token: token).array("trophyGroups")
        let definitions = try await requestJSON(path: "/v1/npCommunicationIds/\(communicationID)/trophyGroups/all/trophies\(query)", token: token).array("trophies")
        let earned = try await requestJSON(path: "/v1/users/me/npCommunicationIds/\(communicationID)/trophyGroups/all/trophies\(query)", token: token).array("trophies")
        let earnedByID = Dictionary(uniqueKeysWithValues: earned.map { ($0.int("trophyId"), $0) })
        let trophies = definitions.map { definition -> PSNCachedTrophy in
            let status = earnedByID[definition.int("trophyId")] ?? [:]
            return PSNCachedTrophy(
                trophyID: definition.int("trophyId"),
                groupID: definition.string("trophyGroupId"),
                name: definition.string("trophyName"),
                detail: definition.string("trophyDetail"),
                type: TrophyTypePreview(rawValue: definition.string("trophyType")) ?? .bronze,
                iconURL: definition.string("trophyIconUrl"),
                earnedRate: status.double("trophyEarnedRate"),
                isEarned: status.bool("earned"),
                earnedDate: status.string("earnedDateTime")
            )
        }
        let cachedGroups = groups.map { group -> PSNCachedGroup in
            let id = group.string("trophyGroupId")
            return PSNCachedGroup(
                groupID: id,
                name: group.string("trophyGroupName").nilIfEmpty ?? (id == "default" ? "Base Game" : "DLC \(id)"),
                iconURL: group.string("trophyGroupIconUrl"),
                trophies: trophies.filter { $0.groupID == id }
            )
        }
        return PSNCachedGame(
            communicationID: communicationID,
            name: title.string("trophyTitleName"),
            platform: title.string("trophyTitlePlatform"),
            iconURL: title.string("trophyTitleIconUrl"),
            lastUpdated: title.string("lastUpdatedDateTime"),
            defined: .init(json: title.dictionary("definedTrophies")),
            earned: .init(json: title.dictionary("earnedTrophies")),
            groups: cachedGroups
        )
    }

    private func summaryOnlyGame(_ title: [String: Any]) -> PSNCachedGame {
        PSNCachedGame(
            communicationID: title.string("npCommunicationId"),
            name: title.string("trophyTitleName"),
            platform: title.string("trophyTitlePlatform"),
            iconURL: title.string("trophyTitleIconUrl"),
            lastUpdated: title.string("lastUpdatedDateTime"),
            defined: .init(json: title.dictionary("definedTrophies")),
            earned: .init(json: title.dictionary("earnedTrophies")),
            groups: []
        )
    }

    private func exchange(code: String) async throws -> PSNLibraryCredential {
        let json = try await tokenRequest(items: [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "client_id", value: PSNLibraryAuth.clientID),
            URLQueryItem(name: "client_secret", value: PSNLibraryAuth.clientSecret),
            URLQueryItem(name: "redirect_uri", value: PSNLibraryAuth.redirectURI),
            URLQueryItem(name: "scope", value: PSNLibraryAuth.scopes),
            URLQueryItem(name: "token_format", value: "jwt"),
        ])
        let access = json.string("access_token")
        let refresh = json.string("refresh_token")
        guard !access.isEmpty, !refresh.isEmpty else { throw PSNLibraryError.message("Sony did not return reusable PSN credentials.") }
        let account = try await accountIdentity(accessToken: access)
        return PSNLibraryCredential(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(json.double("expires_in")),
            accountID: account.accountID,
            onlineID: account.onlineID,
            clientID: PSNLibraryAuth.clientID
        )
    }

    private func refresh(_ credential: PSNLibraryCredential) async throws -> PSNLibraryCredential {
        let json = try await tokenRequest(items: [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: credential.refreshToken),
            URLQueryItem(name: "client_id", value: PSNLibraryAuth.clientID),
            URLQueryItem(name: "client_secret", value: PSNLibraryAuth.clientSecret),
            URLQueryItem(name: "redirect_uri", value: PSNLibraryAuth.redirectURI),
            URLQueryItem(name: "scope", value: PSNLibraryAuth.scopes),
            URLQueryItem(name: "token_format", value: "jwt"),
        ])
        let access = json.string("access_token")
        guard !access.isEmpty else { throw PSNLibraryError.message("The PSN session expired. Sign in again.") }
        return PSNLibraryCredential(
            accessToken: access,
            refreshToken: json.string("refresh_token").nilIfEmpty ?? credential.refreshToken,
            expiresAt: Date().addingTimeInterval(json.double("expires_in")),
            accountID: credential.accountID,
            onlineID: credential.onlineID,
            clientID: PSNLibraryAuth.clientID
        )
    }

    private func tokenRequest(items: [URLQueryItem]) async throws -> [String: Any] {
        var body = URLComponents()
        body.queryItems = items
        var request = URLRequest(url: PSNLibraryAuth.tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(PSNLibraryAuth.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)
        return try await sendJSON(request)
    }

    private func accountIdentity(accessToken: String) async throws -> (accountID: String, onlineID: String) {
        guard let encoded = accessToken.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/token/\(encoded)") else {
            throw PSNLibraryError.message("Sony returned an invalid access token.")
        }
        var request = URLRequest(url: url)
        let basic = Data("\(PSNLibraryAuth.clientID):\(PSNLibraryAuth.clientSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        let json = try await sendJSON(request)
        let accountID = json.string("user_id")
        let onlineID = json.string("online_id")
        guard !accountID.isEmpty else { throw PSNLibraryError.message("Sony did not return the PSN account ID.") }
        return (accountID, onlineID.isEmpty ? "PSN PLAYER" : onlineID)
    }

    private func requestJSON(path: String, token: String) async throws -> [String: Any] {
        try await requestJSON(absoluteURL: URL(string: "https://m.np.playstation.com/api/trophy\(path)")!, token: token)
    }

    private func requestJSON(absoluteURL: URL, token: String) async throws -> [String: Any] {
        var request = URLRequest(url: absoluteURL)
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.psnAcceptLanguage, forHTTPHeaderField: "Accept-Language")
        return try await sendJSON(request)
    }

    private static var psnAcceptLanguage: String {
        let localization = Bundle.main.preferredLocalizations.first
            ?? Bundle.main.developmentLocalization
            ?? "en"
        let normalized = localization.replacingOccurrences(of: "_", with: "-").lowercased()
        if normalized.hasPrefix("zh-hans") || normalized == "zh-cn" { return "zh-CN" }
        if normalized.hasPrefix("zh-hant") || normalized == "zh-tw" || normalized == "zh-hk" { return "zh-TW" }
        if normalized.hasPrefix("ja") { return "ja-JP" }
        if normalized.hasPrefix("ko") { return "ko-KR" }
        if normalized.hasPrefix("fr") { return "fr-FR" }
        if normalized.hasPrefix("de") { return "de-DE" }
        if normalized.hasPrefix("es") { return "es-ES" }
        return "en-US"
    }

    private static var psnCatalogCountry: String {
        switch psnAcceptLanguage {
        case "zh-CN": return "CN"
        case "zh-TW": return "TW"
        case "ja-JP": return "JP"
        case "ko-KR": return "KR"
        case "fr-FR": return "FR"
        case "de-DE": return "DE"
        case "es-ES": return "ES"
        default: return "US"
        }
    }

    private func sendJSON(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PSNLibraryError.message("PSN returned an invalid response.") }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw PSNLibraryError.message("The PSN session expired (HTTP 401). Sign in again.") }
            if http.statusCode == 403 { throw PSNLibraryError.message("The PSN session does not permit this request (HTTP 403).") }
            throw PSNLibraryError.message("PSN request failed (HTTP \(http.statusCode)).")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PSNLibraryError.message("PSN returned unreadable data.")
        }
        return json
    }

    private func requestJSONArray(absoluteURL: URL, token: String) async throws -> [[String: Any]] {
        var request = URLRequest(url: absoluteURL)
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.psnAcceptLanguage, forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PSNLibraryError.message("PSN returned an invalid response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PSNLibraryError.message("PSN catalog request failed (HTTP \(http.statusCode)).")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw PSNLibraryError.message("PSN catalog returned unreadable data.")
        }
        return json
    }

    private func legacyProfileURL(onlineID: String) -> URL {
        let fields = "npId,onlineId,accountId,avatarUrls,aboutMe,trophySummary(@default,level,progress,earnedTrophies),personalDetail(@default,profilePictureUrls),primaryOnlineStatus,presences(@default,@titleInfo,platform,lastOnlineDate)"
        var components = URLComponents(string: "https://us-prof.np.community.playstation.net/userProfile/v1/users/\(onlineID)/profile2")!
        components.queryItems = [URLQueryItem(name: "fields", value: fields)]
        return components.url!
    }

    private func basicPresenceURL(accountID: String) -> URL {
        var components = URLComponents(string: "https://m.np.playstation.com/api/userProfile/v2/internal/users/\(accountID)/basicPresences")!
        components.queryItems = [
            URLQueryItem(name: "type", value: "primary"),
            URLQueryItem(name: "platforms", value: "PS4,PS5,MOBILE_APP,PSPC"),
            URLQueryItem(name: "withOwnGameTitleInfo", value: "true"),
        ]
        return components.url!
    }

    private func requestBasicPresence(accountID: String, token: String) async -> [String: Any]? {
        do {
            let response = try await requestJSON(
                absoluteURL: basicPresenceURL(accountID: accountID),
                token: token
            )
            Self.presenceLog.info("response topKeys=\(response.keys.sorted().joined(separator: ","), privacy: .public)")
            return response
        } catch {
            Self.presenceLog.error("request failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func requestLocalizedPresenceTitle(_ presence: [String: Any]?, token: String) async -> String? {
        guard let game = presence?.dictionary("basicPresence").array("gameTitleInfoList").first else {
            return nil
        }
        let fallback = game.string("titleName").nilIfEmpty
        guard let titleID = game.string("npTitleId").nilIfEmpty else { return fallback }
        var components = URLComponents(string: "https://m.np.playstation.com/api/catalog/v2/titles/\(titleID)/concepts")!
        components.queryItems = [
            URLQueryItem(name: "age", value: "99"),
            URLQueryItem(name: "country", value: Self.psnCatalogCountry),
            URLQueryItem(name: "language", value: Self.psnAcceptLanguage),
        ]
        do {
            let concepts = try await requestJSONArray(absoluteURL: components.url!, token: token)
            let localized = concepts.first?.string("name").nilIfEmpty
            Self.presenceLog.info(
                "title language=\(Self.psnAcceptLanguage, privacy: .public) id=\(titleID, privacy: .public) raw=\(fallback ?? "nil", privacy: .public) localized=\(localized ?? "nil", privacy: .public)"
            )
            return localized ?? fallback
        } catch {
            Self.presenceLog.error("localized title failed: \(error.localizedDescription, privacy: .public)")
            return fallback
        }
    }

    private func makeProfile(summary: [String: Any]?, profile: [String: Any]?, presence: [String: Any]?, localizedPresenceTitle: String?, legacy: [String: Any]?, fallbackOnlineID: String, cached: PSNCachedProfile?) async -> PSNCachedProfile {
        let trophies = summary?.dictionary("earnedTrophies") ?? [:]
        let legacyProfile = legacy?.dictionary("profile") ?? [:]
        let personal = legacyProfile.dictionary("personalDetail")
        let realName = [personal.string("firstName"), personal.string("lastName")].filter { !$0.isEmpty }.joined(separator: " ")
        let avatars = profile?.array("avatars") ?? legacyProfile.array("avatarUrls")
        let avatar = avatars.last?.string("url").nilIfEmpty
            ?? avatars.last?.string("avatarUrl").nilIfEmpty
            ?? personal.array("profilePictureUrls").last?.string("profilePictureUrl")
            ?? ""
        let presences = legacyProfile.array("presences")
        let activePresence = presences.first {
            $0.string("onlineStatus").lowercased() != "offline"
                && !$0.dictionary("titleInfo").string("titleName").isEmpty
        }
        let basicPresence = presence?.dictionary("basicPresence") ?? [:]
        let primaryPlatform = basicPresence.dictionary("primaryPlatformInfo")
        let modernGame = basicPresence.array("gameTitleInfoList").first
        let onlineStatus = primaryPlatform.string("onlineStatus").nilIfEmpty
            ?? basicPresence.string("onlineStatus").nilIfEmpty
            ?? (basicPresence.string("availability") == "availableToPlay" ? "online" : nil)
            ?? legacyProfile.string("primaryOnlineStatus").nilIfEmpty
            ?? activePresence?.string("onlineStatus").nilIfEmpty
        Self.presenceLog.info(
            "parsed modern=\(primaryPlatform.string("onlineStatus"), privacy: .public) availability=\(basicPresence.string("availability"), privacy: .public) games=\(basicPresence.array("gameTitleInfoList").count) legacy=\(legacyProfile.string("primaryOnlineStatus"), privacy: .public) final=\(onlineStatus ?? "nil", privacy: .public)"
        )
        let avatarData = await downloadAvatar(from: avatar)
            ?? (cached?.avatarURL == avatar ? cached?.avatarData : nil)
        return PSNCachedProfile(
            onlineID: profile?.string("onlineId").nilIfEmpty ?? legacyProfile.string("onlineId").nilIfEmpty ?? fallbackOnlineID,
            realName: realName,
            bio: profile?.string("aboutMe").nilIfEmpty ?? legacyProfile.string("aboutMe").nilIfEmpty ?? "PLAYSTATION NETWORK",
            onlineStatus: onlineStatus,
            currentGame: localizedPresenceTitle
                ?? modernGame?.string("titleName").nilIfEmpty
                ?? activePresence?.dictionary("titleInfo").string("titleName").nilIfEmpty,
            avatarURL: avatar,
            avatarData: avatarData,
            level: summary?.int("trophyLevel") ?? cached?.level ?? 0,
            levelProgress: summary?.double("progress") ?? cached?.levelProgress ?? 0,
            platinum: summary == nil ? cached?.platinum ?? 0 : trophies.int("platinum"),
            gold: summary == nil ? cached?.gold ?? 0 : trophies.int("gold"),
            silver: summary == nil ? cached?.silver ?? 0 : trophies.int("silver"),
            bronze: summary == nil ? cached?.bronze ?? 0 : trophies.int("bronze")
        )
    }

    private func downloadAvatar(from source: String) async -> Data? {
        guard let url = URL(string: source), !source.isEmpty else { return nil }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadRevalidatingCacheData
        request.timeoutInterval = 20
        request.setValue(PSNLibraryAuth.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("image/png,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !data.isEmpty else { return nil }
        return data
    }

    private func apply(_ cache: PSNLibraryCache) {
        profile = cache.profile.map(PSNProfilePreview.init)
        games = cache.games.map(TrophyGamePreview.init)
        lastSyncDate = cache.lastSyncDate
    }
}

private enum PSNLibraryAuth {
    static let authorizeURL = URL(string: "https://ca.account.sony.com/api/authz/v3/oauth/authorize")!
    static let tokenURL = URL(string: "https://ca.account.sony.com/api/authz/v3/oauth/token")!
    static let clientID = "09515159-7237-4370-9b40-3806e67c0891"
    static let clientSecret = "ucPjka5tntB2KqsP"
    static let redirectURI = "com.scee.psxandroid.scecompcall://redirect"
    static let scopes = "psn:mobile.v2.core psn:clientapp"
    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
    static func makeDUID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return "0000000700410080" + bytes.map { String(format: "%02x", $0) }.joined()
    }
}

private struct PSNLibraryCredential: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let accountID: String
    let onlineID: String
    let clientID: String?
}

private struct PSNLibraryKeychain {
    private let service = "com.mb14ck22.tpplay.psn-library"
    private let account = "primary"
    func load() throws -> PSNLibraryCredential? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw PSNLibraryError.keychain(status) }
        return try JSONDecoder.psn.decode(PSNLibraryCredential.self, from: data)
    }
    func save(_ value: PSNLibraryCredential) throws {
        let data = try JSONEncoder.psn.encode(value)
        let key: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        let update = SecItemUpdate(key as CFDictionary, [kSecValueData: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw PSNLibraryError.keychain(update) }
        var insert = key
        insert[kSecValueData] = data
        insert[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw PSNLibraryError.keychain(status) }
    }
    func delete() throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PSNLibraryError.keychain(status) }
    }
}

private struct PSNLibraryCache: Codable {
    let profile: PSNCachedProfile?
    let games: [PSNCachedGame]
    let lastSyncDate: Date?
    let lastProfileRefreshDate: Date?
    static let empty = PSNLibraryCache(profile: nil, games: [], lastSyncDate: nil, lastProfileRefreshDate: nil)
}

private struct PSNCachedProfile: Codable {
    let onlineID: String; let realName: String; let bio: String; let onlineStatus: String?; let currentGame: String?; let avatarURL: String
    let avatarData: Data?
    let level: Int; let levelProgress: Double; let platinum: Int; let gold: Int; let silver: Int; let bronze: Int
}

private struct PSNCachedCounts: Codable {
    let platinum: Int; let gold: Int; let silver: Int; let bronze: Int
    init(json: [String: Any]) { platinum = json.int("platinum"); gold = json.int("gold"); silver = json.int("silver"); bronze = json.int("bronze") }
    var total: Int { platinum + gold + silver + bronze }
}

private struct PSNCachedGame: Codable {
    let communicationID: String; let name: String; let platform: String; let iconURL: String; let lastUpdated: String
    let defined: PSNCachedCounts; let earned: PSNCachedCounts; let groups: [PSNCachedGroup]
}

private struct PSNCachedGroup: Codable {
    let groupID: String; let name: String; let iconURL: String; let trophies: [PSNCachedTrophy]
}

private struct PSNCachedTrophy: Codable {
    let trophyID: Int; let groupID: String; let name: String; let detail: String; let type: TrophyTypePreview
    let iconURL: String; let earnedRate: Double; let isEarned: Bool; let earnedDate: String
}

private extension PSNProfilePreview {
    init(_ value: PSNCachedProfile) {
        let currentGame = value.currentGame?.caseInsensitiveCompare("OFFLINE") == .orderedSame ? nil : value.currentGame
        self.init(onlineID: value.onlineID, realName: value.realName, bio: value.bio, onlineStatus: value.onlineStatus, currentGame: currentGame, level: value.level, levelProgress: value.levelProgress / 100, platinum: value.platinum, gold: value.gold, silver: value.silver, bronze: value.bronze, avatarURL: URL(string: value.avatarURL), avatarData: value.avatarData)
    }
}

private extension TrophyGamePreview {
    init(_ value: PSNCachedGame) {
        let groups = value.groups.map(TrophyGroupPreview.init)
        self.init(
            name: value.name,
            platform: value.platform,
            earned: value.earned.total,
            total: value.defined.total,
            lastPlayed: PSNRelativeDate.format(value.lastUpdated),
            latestTrophy: groups.flatMap(\.trophies).first(where: \.isEarned)?.name ?? "--",
            archiveCode: String(value.communicationID.prefix(8)),
            breakdown: TrophyBreakdownPreview(platinum: (value.earned.platinum, value.defined.platinum), gold: (value.earned.gold, value.defined.gold), silver: (value.earned.silver, value.defined.silver), bronze: (value.earned.bronze, value.defined.bronze)),
            trophyGroups: groups,
            imageURL: URL(string: value.iconURL)
        )
    }
}

private extension TrophyGroupPreview {
    init(_ value: PSNCachedGroup) {
        let trophies = value.trophies.map(TrophyPreview.init)
        self.init(name: value.name, isBaseGame: value.groupID == "default", earned: trophies.filter(\.isEarned).count, total: trophies.count, trophies: trophies)
    }
}

private extension TrophyPreview {
    init(_ value: PSNCachedTrophy) {
        self.init(name: value.name, description: value.detail, rarity: value.earnedRate, type: value.type, isEarned: value.isEarned, earnedAt: PSNRelativeDate.format(value.earnedDate), imageURL: URL(string: value.iconURL))
    }
}

private enum PSNRelativeDate {
    static func format(_ source: String) -> String {
        guard !source.isEmpty, let date = ISO8601DateFormatter().date(from: source) else { return "--" }
        return date.formatted(.relative(presentation: .named))
    }
}

private enum PSNLibraryError: LocalizedError {
    case keychain(OSStatus)
    case message(String)
    var errorDescription: String? {
        switch self {
        case .keychain(let status): SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)."
        case .message(let message): message
        }
    }
}

private extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String { self[key] as? String ?? (self[key] as? NSNumber)?.stringValue ?? "" }
    func int(_ key: String) -> Int { self[key] as? Int ?? (self[key] as? NSNumber)?.intValue ?? Int(string(key)) ?? 0 }
    func double(_ key: String) -> Double { self[key] as? Double ?? (self[key] as? NSNumber)?.doubleValue ?? Double(string(key)) ?? 0 }
    func bool(_ key: String) -> Bool { self[key] as? Bool ?? (self[key] as? NSNumber)?.boolValue ?? false }
    func dictionary(_ key: String) -> [String: Any] { self[key] as? [String: Any] ?? [:] }
    func array(_ key: String) -> [[String: Any]] { self[key] as? [[String: Any]] ?? [] }
}

private extension Optional where Wrapped == [String: Any] {
    func string(_ key: String) -> String { self?[key] as? String ?? "" }
    func dictionary(_ key: String) -> [String: Any] { self?[key] as? [String: Any] ?? [:] }
    func array(_ key: String) -> [[String: Any]] { self?[key] as? [[String: Any]] ?? [] }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
private extension JSONEncoder { static var psn: JSONEncoder { let value = JSONEncoder(); value.dateEncodingStrategy = .iso8601; return value } }
private extension JSONDecoder { static var psn: JSONDecoder { let value = JSONDecoder(); value.dateDecodingStrategy = .iso8601; return value } }
