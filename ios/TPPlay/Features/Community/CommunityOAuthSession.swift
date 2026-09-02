import AuthenticationServices
import AtprotoClient
import AtprotoOAuth
import AtprotoTypes
import Foundation
import GermConvenience
import OAuth4Swift
import OSLog
import Security
import UIKit

@MainActor
final class CommunityOAuthSession: ObservableObject {
    enum State: Equatable {
        case disconnected
        case restoring
        case authorizing
        case connected(handle: String, did: String)
        case failed(String)
    }

    @Published private(set) var state: State = .restoring

    private let logger = Logger(subsystem: "com.mb14ck22.tpplay", category: "BlueskyOAuth")
    private let keychain = CommunityOAuthKeychain()
    private let webAuthenticator: CommunityWebAuthenticator
    private let client: AtprotoOAuthClient
    private var agent: AtprotoOAuthAgent?
    private var storedSession: StoredCommunityOAuthSession?
    private var saveTask: Task<Void, Never>?

    init() {
        let webAuthenticator = CommunityWebAuthenticator()
        self.webAuthenticator = webAuthenticator
        let clientInfo = OAuth.ClientInfo(
            clientId: "https://mb14ck22.github.io/tp-play/oauth-client-metadata.json",
            scopes: [
                "atproto",
                "transition:generic",
            ],
            redirectURI: URL(string: "io.github.mb14ck22:/oauth/callback")!
        )
        let resolver = TPPlayAtprotoResolver()
        client = AtprotoOAuthClient(
            clientInfo: clientInfo,
            resolver: resolver,
            authFetcher: URLSession.manualRedirect(),
            userAuthenticator: { url, callbackScheme in
                try await webAuthenticator.authenticate(
                    url: url,
                    callbackScheme: callbackScheme
                )
            }
        )

        Task { await restore() }
    }

    var isAuthenticated: Bool {
        if case .connected = state { return true }
        return false
    }

    var connectedHandle: String? {
        if case .connected(let handle, _) = state { return handle }
        return nil
    }

    var connectedDID: String? {
        if case .connected(_, let did) = state { return did }
        return nil
    }

    func signIn(handle rawHandle: String) {
        guard state != .authorizing else { return }
        let normalized = rawHandle
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingPrefix("@")
            .lowercased()

        state = .authorizing
        logger.info("Starting Bluesky authorization for a validated handle")
        Task {
            do {
                let handle = try Atproto.Handle(string: normalized)
                let (sessionArchive, did) = try await client.authorize(identity: .handle(handle))
                let archive = AtprotoOAuthAgent.Archive(did: did.rawValue, session: sessionArchive)
                let stored = StoredCommunityOAuthSession(handle: normalized, archive: archive)
                try keychain.save(stored)
                try activate(stored)
                logger.info("Bluesky authorization completed and session was stored")
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                logger.info("Bluesky authorization was cancelled by the user")
                state = .disconnected
            } catch {
                logger.error("Bluesky authorization failed: \(String(reflecting: error), privacy: .public)")
                state = .failed(Self.message(for: error))
            }
        }
    }

    func retry() {
        state = .disconnected
    }

    func publishPost(text rawText: String) async throws {
        guard let agent, isAuthenticated else {
            throw CommunityOAuthActionError.notAuthenticated
        }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CommunityOAuthActionError.emptyPost }
        guard text.count <= 300 else { throw CommunityOAuthActionError.postTooLong }

        _ = try await agent.createRecord(
            TPPlayBlueskyPost(text: text),
            validate: true
        )
    }

    func fetchProfile() async throws -> CommunityProfile {
        guard let agent, isAuthenticated else {
            throw CommunityOAuthActionError.notAuthenticated
        }
        let profile = try await agent.authBskyProfile(for: agent.authenticatedDID)
        let result = CommunityProfile(
            did: profile.did.rawValue,
            handle: profile.handle.rawValue,
            displayName: profile.displayName ?? profile.handle.rawValue,
            bio: profile.description ?? "",
            avatarURL: profile.avatar,
            bannerURL: profile.banner,
            followersCount: profile.followersCount ?? 0,
            followsCount: profile.followsCount ?? 0,
            postsCount: profile.postsCount ?? 0
        )
        logger.info("Loaded Bluesky profile for the authenticated DID")
        return result
    }

    func fetchTimeline(feedID: String) async throws -> [CommunityPost] {
        guard let agent, isAuthenticated else {
            throw CommunityOAuthActionError.notAuthenticated
        }
        let output: TPPlayFeedOutput
        if feedID == "following" {
            output = try await agent.call(
                TPPlayGetTimeline.self,
                parameters: .init(limit: 50),
                proxy: try .bskyAppView
            )
        } else {
            output = try await agent.call(
                TPPlayGetFeed.self,
                parameters: .init(feed: feedID, limit: 50),
                proxy: try .bskyAppView
            )
        }
        let posts = output.feed.compactMap(Self.communityPost(from:))
        logger.info("Loaded \(posts.count, privacy: .public) Bluesky posts")
        return posts
    }

    func fetchSavedFeeds() async throws -> [CommunityFeed] {
        guard let agent, isAuthenticated else {
            throw CommunityOAuthActionError.notAuthenticated
        }
        let preferences = try await agent.call(
            TPPlayGetPreferences.self,
            parameters: .init(),
            proxy: try .bskyAppView
        )

        var orderedURIs: [String] = []
        for preference in preferences.preferences {
            if preference.type == "app.bsky.actor.defs#savedFeedsPrefV2" {
                orderedURIs.append(contentsOf: (preference.items ?? []).filter { $0.type == "feed" }.map(\.value))
            } else if preference.type == "app.bsky.actor.defs#savedFeedsPref" {
                orderedURIs.append(contentsOf: preference.pinned ?? [])
                orderedURIs.append(contentsOf: preference.saved ?? [])
            }
        }
        var seen = Set<String>()
        orderedURIs = orderedURIs.filter { seen.insert($0).inserted }
        guard !orderedURIs.isEmpty else { return [] }

        let generators = try await agent.call(
            TPPlayGetFeedGenerators.self,
            parameters: .init(feeds: Array(orderedURIs.prefix(100))),
            proxy: try .bskyAppView
        )
        let byURI = generators.feeds.reduce(into: [String: TPPlayFeedGeneratorsOutput.Generator]()) {
            $0[$1.uri] = $1
        }
        let feeds: [CommunityFeed] = orderedURIs.compactMap { uri -> CommunityFeed? in
            guard let feed = byURI[uri] else { return nil }
            return CommunityFeed(
                id: feed.uri,
                name: feed.displayName.uppercased(),
                description: feed.description ?? "",
                creator: "@\(feed.creator.handle)",
                isAdded: true
            )
        }
        logger.info("Loaded \(feeds.count, privacy: .public) saved Bluesky feeds")
        return feeds
    }

    func disconnect() {
        saveTask?.cancel()
        saveTask = nil
        agent = nil
        storedSession = nil
        do {
            try keychain.delete()
            state = .disconnected
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    private func restore() async {
        do {
            guard let stored = try keychain.load() else {
                state = .disconnected
                return
            }
            try activate(stored)
        } catch {
            try? keychain.delete()
            state = .failed("SAVED SESSION COULD NOT BE RESTORED. SIGN IN AGAIN.")
        }
    }

    private func activate(_ stored: StoredCommunityOAuthSession) throws {
        saveTask?.cancel()
        let (restoredAgent, saveStream) = try client.restore(archive: stored.archive)
        agent = restoredAgent
        storedSession = stored
        state = .connected(handle: stored.handle, did: restoredAgent.authenticatedDID.rawValue)

        saveTask = Task { [weak self] in
            for await tokenState in saveStream {
                guard !Task.isCancelled, let self else { return }
                guard let tokenState else {
                    self.disconnect()
                    return
                }
                guard var updated = self.storedSession else { continue }
                updated.archive.session?.tokenState = tokenState
                self.storedSession = updated
                do {
                    try self.keychain.save(updated)
                } catch {
                    self.state = .failed("REFRESHED SESSION COULD NOT BE SAVED SECURELY.")
                }
            }
        }
    }

    private static func message(for error: Error) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "BLUESKY AUTHORIZATION FAILED." : message.uppercased()
    }

    private static func communityPost(from item: TPPlayFeedItem) -> CommunityPost? {
        guard let text = item.post.record.text else { return nil }
        let handle = item.post.author.handle
        let displayName = item.post.author.displayName ?? handle
        let initials = displayName
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .uppercased()

        return CommunityPost(
            id: item.post.uri,
            author: CommunityAuthor(
                id: item.post.author.did,
                displayName: displayName,
                handle: handle,
                initials: initials.isEmpty ? String(handle.prefix(2)).uppercased() : initials,
                avatarURL: item.post.author.avatar
            ),
            text: text,
            timestamp: relativeTimestamp(item.post.record.createdAt ?? item.post.indexedAt),
            replyCount: item.post.replyCount ?? 0,
            repostCount: item.post.repostCount ?? 0,
            likeCount: item.post.likeCount ?? 0,
            isLiked: item.post.viewer?.like != nil,
            isReposted: item.post.viewer?.repost != nil,
            links: (item.post.record.facets ?? []).compactMap(Self.communityLink(from:))
        )
    }

    private static func communityLink(from facet: TPPlayFeedItem.Facet) -> CommunityPostLink? {
        for feature in facet.features {
            let url: URL?
            switch feature.type {
            case "app.bsky.richtext.facet#link":
                url = feature.uri.flatMap(URL.init(string:))
            case "app.bsky.richtext.facet#mention":
                url = feature.did.flatMap { URL(string: "https://bsky.app/profile/\($0)") }
            case "app.bsky.richtext.facet#tag":
                guard let tag = feature.tag,
                      let encoded = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
                    url = nil
                    break
                }
                url = URL(string: "https://bsky.app/hashtag/\(encoded)")
            default:
                url = nil
            }
            if let url {
                return CommunityPostLink(
                    byteStart: facet.index.byteStart,
                    byteEnd: facet.index.byteEnd,
                    url: url
                )
            }
        }
        return nil
    }

    private static func relativeTimestamp(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        guard let date else { return "" }
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "NOW" }
        if seconds < 3_600 { return "\(seconds / 60)M" }
        if seconds < 86_400 { return "\(seconds / 3_600)H" }
        return "\(seconds / 86_400)D"
    }
}

@MainActor
private final class CommunityWebAuthenticator: NSObject,
    ASWebAuthenticationPresentationContextProviding
{
    private var session: ASWebAuthenticationSession?
    private weak var presentationWindow: UIWindow?

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        guard session == nil else { throw CommunityWebAuthenticationError.alreadyRunning }
        guard let window = Self.activeWindow else {
            throw CommunityWebAuthenticationError.noPresentationWindow
        }
        presentationWindow = window

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { [weak self] callbackURL, error in
                Task { @MainActor in
                    self?.session = nil
                    self?.presentationWindow = nil
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let callbackURL {
                        continuation.resume(returning: callbackURL)
                    } else {
                        continuation.resume(throwing: CommunityWebAuthenticationError.missingCallback)
                    }
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session

            if !session.start() {
                self.session = nil
                self.presentationWindow = nil
                continuation.resume(throwing: CommunityWebAuthenticationError.couldNotStart)
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        presentationWindow ?? Self.activeWindow ?? UIWindow()
    }

    private static var activeWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }
}

private enum CommunityWebAuthenticationError: LocalizedError {
    case alreadyRunning
    case noPresentationWindow
    case missingCallback
    case couldNotStart

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: "A BLUESKY AUTHORIZATION IS ALREADY OPEN."
        case .noPresentationWindow: "TP PLAY COULD NOT OPEN THE BLUESKY LOGIN WINDOW."
        case .missingCallback: "BLUESKY DID NOT RETURN AN AUTHORIZATION CALLBACK."
        case .couldNotStart: "THE BLUESKY LOGIN WINDOW COULD NOT START."
        }
    }
}

private enum TPPlayGetTimeline: Atproto.XRPC.Request {
    struct Id: Atproto.XRPC.EndpointId {
        static var nsid: Atproto.NSID { .init(string: "app.bsky.feed.getTimeline") }
        init() {}
    }

    static var outputEncoding: HTTPContentType { .json }
    static var badRequestErrors: Set<String> { defaultErrors }
    typealias Output = TPPlayFeedOutput

    struct Parameters: QueryParametrizable {
        let limit: Int
        func asQueryItems() -> [URLQueryItem] {
            [.init(name: "limit", value: String(limit))]
        }
    }
}

private enum TPPlayGetFeed: Atproto.XRPC.Request {
    struct Id: Atproto.XRPC.EndpointId {
        static var nsid: Atproto.NSID { .init(string: "app.bsky.feed.getFeed") }
        init() {}
    }

    static var outputEncoding: HTTPContentType { .json }
    static var badRequestErrors: Set<String> { defaultErrors.union(["UnknownFeed"]) }
    typealias Output = TPPlayFeedOutput

    struct Parameters: QueryParametrizable {
        let feed: String
        let limit: Int
        func asQueryItems() -> [URLQueryItem] {
            [
                .init(name: "feed", value: feed),
                .init(name: "limit", value: String(limit)),
            ]
        }
    }
}

private struct TPPlayFeedOutput: Decodable, Sendable {
    let cursor: String?
    let feed: [TPPlayFeedItem]
}

private struct TPPlayFeedItem: Decodable, Sendable {
    let post: Post

    struct Post: Decodable, Sendable {
        let uri: String
        let author: Author
        let record: Record
        let replyCount: Int?
        let repostCount: Int?
        let likeCount: Int?
        let indexedAt: String
        let viewer: Viewer?
    }

    struct Author: Decodable, Sendable {
        let did: String
        let handle: String
        let displayName: String?
        let avatar: URL?
    }

    struct Record: Decodable, Sendable {
        let text: String?
        let createdAt: String?
        let facets: [Facet]?
    }

    struct Facet: Decodable, Sendable {
        let index: ByteSlice
        let features: [Feature]
    }

    struct ByteSlice: Decodable, Sendable {
        let byteStart: Int
        let byteEnd: Int
    }

    struct Feature: Decodable, Sendable {
        let type: String
        let uri: String?
        let did: String?
        let tag: String?

        enum CodingKeys: String, CodingKey {
            case type = "$type"
            case uri
            case did
            case tag
        }
    }

    struct Viewer: Decodable, Sendable {
        let repost: String?
        let like: String?
    }
}

private enum TPPlayGetPreferences: Atproto.XRPC.Request {
    struct Id: Atproto.XRPC.EndpointId {
        static var nsid: Atproto.NSID { .init(string: "app.bsky.actor.getPreferences") }
        init() {}
    }

    static var outputEncoding: HTTPContentType { .json }
    static var badRequestErrors: Set<String> { defaultErrors }
    typealias Parameters = Atproto.XRPC.EmptyParameters
    typealias Output = TPPlayPreferencesOutput
}

private struct TPPlayPreferencesOutput: Decodable, Sendable {
    let preferences: [Preference]

    struct Preference: Decodable, Sendable {
        let type: String?
        let items: [SavedFeed]?
        let pinned: [String]?
        let saved: [String]?

        enum CodingKeys: String, CodingKey {
            case type = "$type"
            case items
            case pinned
            case saved
        }
    }

    struct SavedFeed: Decodable, Sendable {
        let type: String
        let value: String
        let pinned: Bool
    }
}

private enum TPPlayGetFeedGenerators: Atproto.XRPC.Request {
    struct Id: Atproto.XRPC.EndpointId {
        static var nsid: Atproto.NSID { .init(string: "app.bsky.feed.getFeedGenerators") }
        init() {}
    }

    static var outputEncoding: HTTPContentType { .json }
    static var badRequestErrors: Set<String> { defaultErrors }
    typealias Output = TPPlayFeedGeneratorsOutput

    struct Parameters: QueryParametrizable {
        let feeds: [String]
        func asQueryItems() -> [URLQueryItem] {
            feeds.map { .init(name: "feeds", value: $0) }
        }
    }
}

private struct TPPlayFeedGeneratorsOutput: Decodable, Sendable {
    let feeds: [Generator]

    struct Generator: Decodable, Sendable {
        let uri: String
        let creator: Creator
        let displayName: String
        let description: String?
        let avatar: URL?
    }

    struct Creator: Decodable, Sendable {
        let did: String
        let handle: String
        let displayName: String?
        let avatar: URL?
    }
}

private struct TPPlayBlueskyPost: Atproto.Record {
    struct Collection: Atproto.RecordType {
        static var nsid: Atproto.NSID { .init(string: "app.bsky.feed.post") }
        init() {}
    }

    typealias Key = Atproto.TID

    private(set) var nsid = Collection()
    let text: String
    let createdAt: LexiconString.Datetime

    init(text: String, createdAt: Date = .now) {
        self.text = text
        self.createdAt = .init(date: createdAt)
    }

    enum CodingKeys: String, CodingKey {
        case nsid = "$type"
        case text
        case createdAt
    }
}

private enum CommunityOAuthActionError: LocalizedError {
    case notAuthenticated
    case emptyPost
    case postTooLong

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: "CONNECT A BLUESKY ACCOUNT BEFORE POSTING."
        case .emptyPost: "WRITE SOMETHING BEFORE POSTING."
        case .postTooLong: "BLUESKY POSTS CAN CONTAIN UP TO 300 CHARACTERS."
        }
    }
}

private struct StoredCommunityOAuthSession: Codable, Sendable {
    let handle: String
    var archive: AtprotoOAuthAgent.Archive
}

private struct TPPlayAtprotoResolver: Atproto.Resolver {
    private struct HandleResponse: Decodable {
        let did: String
    }

    func resolve(handle: Atproto.Handle) async throws -> Atproto.DID? {
        var components = URLComponents(string: "https://bsky.social/xrpc/com.atproto.identity.resolveHandle")!
        components.queryItems = [URLQueryItem(name: "handle", value: handle.rawValue)]
        guard let url = components.url else { throw ResolverError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ResolverError.handleNotFound
        }
        return try Atproto.DID(string: JSONDecoder().decode(HandleResponse.self, from: data).did)
    }

    func resolve(did: Atproto.DID) async throws -> Atproto.DIDDocument? {
        let url: URL
        switch did.method {
        case .plc:
            guard did.identifier.count == 24,
                  did.identifier.allSatisfy({ $0.isLowercase || $0.isNumber }),
                  let resolvedURL = URL(string: "https://plc.directory/\(did.rawValue)") else {
                throw ResolverError.invalidDID
            }
            url = resolvedURL
        case .web:
            guard !did.identifier.contains(":"),
                  did.identifier.contains("."),
                  let resolvedURL = URL(string: "https://\(did.identifier)/.well-known/did.json") else {
                throw ResolverError.invalidDID
            }
            url = resolvedURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/did+ld+json, application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.manualRedirect().data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ResolverError.invalidResponse }
        if (300..<400).contains(http.statusCode) { throw ResolverError.redirectRefused }
        guard (200..<300).contains(http.statusCode) else { return nil }
        let document = try JSONDecoder().decode(Atproto.DIDDocument.self, from: data)
        guard document.id == did.rawValue else { throw ResolverError.invalidDID }
        return document
    }

    private enum ResolverError: LocalizedError {
        case invalidURL
        case handleNotFound
        case invalidDID
        case invalidResponse
        case redirectRefused

        var errorDescription: String? {
            switch self {
            case .invalidURL: "THE HANDLE RESOLUTION URL IS INVALID."
            case .handleNotFound: "THAT BLUESKY HANDLE COULD NOT BE RESOLVED."
            case .invalidDID: "THE ACCOUNT DID DOCUMENT IS INVALID."
            case .invalidResponse: "THE IDENTITY SERVER RETURNED AN INVALID RESPONSE."
            case .redirectRefused: "THE IDENTITY SERVER ATTEMPTED AN UNSAFE REDIRECT."
            }
        }
    }
}

private struct CommunityOAuthKeychain {
    private let service = "com.mb14ck22.tpplay.atproto-oauth"
    private let account = "primary"

    func load() throws -> StoredCommunityOAuthSession? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CommunityOAuthKeychainError(status: status)
        }
        return try JSONDecoder().decode(StoredCommunityOAuthSession.self, from: data)
    }

    func save(_ session: StoredCommunityOAuthSession) throws {
        let data = try JSONEncoder().encode(session)
        let key: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let attributes: [CFString: Any] = [kSecValueData: data]
        let updateStatus = SecItemUpdate(key as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CommunityOAuthKeychainError(status: updateStatus)
        }
        var insert = key
        insert[kSecValueData] = data
        insert[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CommunityOAuthKeychainError(status: addStatus)
        }
    }

    func delete() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CommunityOAuthKeychainError(status: status)
        }
    }
}

private struct CommunityOAuthKeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String? ?? "KEYCHAIN ERROR \(status)."
    }
}
