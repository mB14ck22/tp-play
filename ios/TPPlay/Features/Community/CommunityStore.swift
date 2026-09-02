import Foundation

struct CommunityFeed: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var description: String
    var creator: String
    var isFixed = false
    var isAdded = false
}

struct CommunityAuthor: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var displayName: String
    var handle: String
    var initials: String
    var avatarURL: URL?
    var isFollowing = false
}

struct CommunityPostLink: Codable, Hashable, Sendable {
    let byteStart: Int
    let byteEnd: Int
    let url: URL
}

struct CommunityPost: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var author: CommunityAuthor
    var text: String
    var timestamp: String
    var replyCount: Int
    var repostCount: Int
    var likeCount: Int
    var isLiked = false
    var isReposted = false
    var parentID: String?
    var mediaLabel: String?
    var altText: String?
    var links: [CommunityPostLink] = []
}

struct CommunityProfile: Codable, Equatable, Sendable {
    let did: String
    let handle: String
    let displayName: String
    let bio: String
    let avatarURL: URL?
    let bannerURL: URL?
    let followersCount: Int
    let followsCount: Int
    let postsCount: Int
}

@MainActor
final class CommunityStore: ObservableObject {
    @Published var selectedFeedID = "following" {
        didSet {
            posts = postsByFeed[selectedFeedID] ?? []
            persistCache()
        }
    }
    @Published var feeds: [CommunityFeed] = CommunityStore.defaultFeeds
    @Published var posts: [CommunityPost] = []
    @Published var profile: CommunityProfile?
    @Published var isLoading = false
    @Published var loadError: String?
    @Published var draft = ""
    @Published var draftAltText = ""

    private var activeDID: String?
    private var postsByFeed: [String: [CommunityPost]] = [:]

    private static let defaultFeeds: [CommunityFeed] = [
        CommunityFeed(id: "following", name: "FOLLOWING", description: "Posts from accounts you follow.", creator: "BLUESKY", isFixed: true, isAdded: true)
    ]

    private struct CacheSnapshot: Codable {
        let profile: CommunityProfile?
        let feeds: [CommunityFeed]
        let postsByFeed: [String: [CommunityPost]]
        let selectedFeedID: String
        let updatedAt: Date
    }

    let currentUser = CommunityAuthor(
        id: "current-user",
        displayName: "",
        handle: "",
        initials: "",
        avatarURL: nil,
        isFollowing: true
    )

    var profileAuthor: CommunityAuthor {
        guard let profile else { return currentUser }
        let initials = profile.displayName
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .uppercased()
        return CommunityAuthor(
            id: profile.did,
            displayName: profile.displayName,
            handle: profile.handle,
            initials: initials.isEmpty ? String(profile.handle.prefix(2)).uppercased() : initials,
            avatarURL: profile.avatarURL,
            isFollowing: true
        )
    }

    var addedFeeds: [CommunityFeed] { feeds.filter(\.isAdded) }

    func posts(for feedID: String) -> [CommunityPost] {
        postsByFeed[feedID] ?? []
    }

    func activateCache(for did: String) {
        guard activeDID != did else { return }

        activeDID = nil
        let key = cacheKey(for: did)
        if let data = UserDefaults.standard.data(forKey: key),
           let snapshot = try? JSONDecoder().decode(CacheSnapshot.self, from: data) {
            profile = snapshot.profile
            feeds = snapshot.feeds.isEmpty ? Self.defaultFeeds : snapshot.feeds
            postsByFeed = snapshot.postsByFeed
            selectedFeedID = feeds.contains(where: { $0.id == snapshot.selectedFeedID })
                ? snapshot.selectedFeedID
                : "following"
            posts = postsByFeed[selectedFeedID] ?? []
        } else {
            profile = nil
            feeds = Self.defaultFeeds
            postsByFeed = [:]
            selectedFeedID = "following"
            posts = []
        }
        activeDID = did
    }

    func beginLoading() {
        isLoading = posts.isEmpty
        loadError = nil
    }

    func apply(
        profile: CommunityProfile,
        feeds remoteFeeds: [CommunityFeed],
        posts remotePosts: [CommunityPost],
        for feedID: String
    ) {
        self.profile = profile
        feeds = [Self.defaultFeeds[0]] + remoteFeeds
        postsByFeed[feedID] = remotePosts
        if selectedFeedID == feedID { posts = remotePosts }
        isLoading = false
        loadError = nil
        if !feeds.contains(where: { $0.id == selectedFeedID }) {
            selectedFeedID = "following"
        }
        persistCache()
    }

    func apply(posts remotePosts: [CommunityPost], for feedID: String) {
        postsByFeed[feedID] = remotePosts
        if selectedFeedID == feedID { posts = remotePosts }
        isLoading = false
        loadError = nil
        persistCache()
    }

    func failLoading(_ message: String) {
        isLoading = false
        loadError = message
    }

    func cancelLoading() {
        isLoading = false
        loadError = nil
    }

    func clearRemoteContent() {
        activeDID = nil
        postsByFeed = [:]
        posts = []
        profile = nil
        feeds = Self.defaultFeeds
        selectedFeedID = "following"
        isLoading = false
        loadError = nil
    }

    func toggleLike(_ post: CommunityPost) {
        guard let index = posts.firstIndex(where: { $0.id == post.id }) else { return }
        posts[index].isLiked.toggle()
        posts[index].likeCount += posts[index].isLiked ? 1 : -1
        postsByFeed[selectedFeedID] = posts
        persistCache()
    }

    func toggleRepost(_ post: CommunityPost) {
        guard let index = posts.firstIndex(where: { $0.id == post.id }) else { return }
        posts[index].isReposted.toggle()
        posts[index].repostCount += posts[index].isReposted ? 1 : -1
        postsByFeed[selectedFeedID] = posts
        persistCache()
    }

    func publish(parentID: String? = nil, as handle: String? = nil) {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        var author = profileAuthor
        if let handle, !handle.isEmpty {
            author.handle = handle
        }
        posts.insert(
            CommunityPost(
                id: UUID().uuidString,
                author: author,
                text: body,
                timestamp: "NOW",
                replyCount: 0,
                repostCount: 0,
                likeCount: 0,
                parentID: parentID,
                altText: draftAltText.isEmpty ? nil : draftAltText
            ),
            at: 0
        )
        postsByFeed[selectedFeedID] = posts
        persistCache()
        draft = ""
        draftAltText = ""
    }

    func toggleFeed(_ feed: CommunityFeed) {
        guard let index = feeds.firstIndex(where: { $0.id == feed.id }), !feeds[index].isFixed else { return }
        feeds[index].isAdded.toggle()
        if selectedFeedID == feed.id, !feeds[index].isAdded { selectedFeedID = "following" }
        persistCache()
    }

    func moveAddedFeeds(from source: IndexSet, to destination: Int) {
        var movable = feeds.filter { $0.isAdded && !$0.isFixed }
        movable.move(fromOffsets: source, toOffset: destination)
        let other = feeds.filter { !$0.isAdded }
        feeds = [feeds.first(where: { $0.isFixed })].compactMap { $0 } + movable + other
        persistCache()
    }

    private func cacheKey(for did: String) -> String {
        "tpplay.community.cache.v1.\(did)"
    }

    private func persistCache() {
        guard let activeDID else { return }
        let snapshot = CacheSnapshot(
            profile: profile,
            feeds: feeds,
            postsByFeed: postsByFeed,
            selectedFeedID: selectedFeedID,
            updatedAt: .now
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey(for: activeDID))
    }
}
