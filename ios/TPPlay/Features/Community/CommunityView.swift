import SwiftUI
import UIKit

struct CommunityView: View {
    @StateObject private var store = CommunityStore()
    @StateObject private var oauth = CommunityOAuthSession()
    @State private var destination: CommunityDestination?
    @State private var threadPost: CommunityPost?

    var body: some View {
        ZStack {
            feedView
                .allowsHitTesting(destination == nil && threadPost == nil)

            if let destination {
                destinationView(destination)
                    .zIndex(1)
            }

            if let threadPost {
                CommunityThreadView(root: threadPost, store: store) {
                    self.threadPost = nil
                }
                .zIndex(2)
            }
        }
        .background(TPPlayTheme.canvas)
        .task(id: "\(sessionTaskID)|\(store.selectedFeedID)") {
            if oauth.isAuthenticated {
                await loadCommunity()
            } else if case .disconnected = oauth.state {
                store.clearRemoteContent()
            }
        }
    }

    private var feedView: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                header
                feedRail
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 10)
            .background(TPPlayTheme.canvas)
            .overlay(alignment: .bottom) { Rectangle().fill(TPPlayTheme.border).frame(height: 1) }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    CommunityAccountStrip(session: oauth) { destination = .profile }

                    if store.isLoading {
                        CommunityLoadingPanel()
                    } else if let error = store.loadError {
                        CommunityLoadErrorPanel(message: error) {
                            Task { await loadCommunity() }
                        }
                    } else if oauth.isAuthenticated && store.posts.isEmpty {
                        CommunityEmptyPanel(title: "NO POSTS", detail: "THIS FEED IS CURRENTLY EMPTY.")
                    } else {
                        ForEach(store.posts(for: store.selectedFeedID)) { post in
                            CommunityPostCard(post: post, store: store) {
                                threadPost = post
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 24)
            }
            .refreshable { await loadCommunity() }
        }
        .background(TPPlayTheme.canvas)
    }

    @ViewBuilder
    private func destinationView(_ destination: CommunityDestination) -> some View {
        switch destination {
        case .search:
            CommunitySearchView(store: store) { self.destination = nil }
        case .profile:
            CommunityProfileView(store: store, session: oauth) { self.destination = nil }
        case .compose:
            CommunityComposerView(store: store, session: oauth) { self.destination = nil }
        }
    }

    private func loadCommunity() async {
        guard oauth.isAuthenticated, let did = oauth.connectedDID else {
            store.clearRemoteContent()
            return
        }
        store.activateCache(for: did)
        let requestedFeedID = store.selectedFeedID
        store.beginLoading()
        do {
            async let profile = oauth.fetchProfile()
            async let feeds = oauth.fetchSavedFeeds()
            async let posts = oauth.fetchTimeline(feedID: requestedFeedID)
            let result = try await (profile, feeds, posts)
            store.apply(profile: result.0, feeds: result.1, posts: result.2, for: requestedFeedID)
        } catch {
            if Task.isCancelled || Self.isCancellation(error) {
                store.cancelLoading()
            } else {
                store.failLoading(error.localizedDescription.uppercased())
            }
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return error.localizedDescription.localizedCaseInsensitiveContains("cancelled")
    }

    private var sessionTaskID: String {
        switch oauth.state {
        case .restoring: "restoring"
        case .authorizing: "authorizing"
        case .disconnected: "disconnected"
        case .failed: "failed"
        case .connected(_, let did): did
        }
    }

    private var header: some View {
        TPPageHeader("COMMUNITY // FEED") {
            CommunitySquareButton(symbol: "person.crop.square", label: "Profile") { destination = .profile }
            CommunitySquareButton(symbol: "magnifyingglass", label: "Search") { destination = .search }
            CommunitySquareButton(symbol: "square.and.pencil", label: "Compose", active: true) {
                destination = oauth.isAuthenticated ? .compose : .profile
            }
        }
    }

    private var feedRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.addedFeeds) { feed in
                    Button(feed.name) { store.selectedFeedID = feed.id }
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 38)
                        .buttonStyle(AcidButtonStyle(active: store.selectedFeedID == feed.id))
                }
                Button { destination = .search } label: {
                    Image(systemName: "plus").frame(width: 40, height: 38)
                }
                .buttonStyle(AcidButtonStyle())
                .accessibilityLabel("Find feeds")
            }
        }
    }
}

private struct CommunityLoadingPanel: View {
    var body: some View {
        HStack(spacing: 12) {
            TPTerminalActivityGlyph()
            Text("LOADING BLUESKY FEED")
        }
        .font(.system(size: 10, weight: .black, design: .monospaced))
        .foregroundStyle(TPPlayTheme.secondaryText)
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .background(TPPlayTheme.surface)
        .overlay { Rectangle().stroke(TPPlayTheme.border, lineWidth: 1) }
    }
}

private struct CommunityLoadErrorPanel: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(message)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(TPPlayTheme.danger)
            Button("RETRY", action: retry)
                .frame(width: 86, height: 38)
                .buttonStyle(AcidButtonStyle(active: true))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TPPlayTheme.surface)
        .overlay { Rectangle().stroke(TPPlayTheme.danger, lineWidth: 1) }
    }
}

private struct CommunityEmptyPanel: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).foregroundStyle(TPPlayTheme.primaryText)
            Text(detail).foregroundStyle(TPPlayTheme.secondaryText)
        }
        .font(.system(size: 10, weight: .bold, design: .monospaced))
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .background(TPPlayTheme.surface)
        .overlay { Rectangle().stroke(TPPlayTheme.border, lineWidth: 1) }
    }
}

private struct CommunityAccountStrip: View {
    @ObservedObject var session: CommunityOAuthSession
    let openAccount: () -> Void

    var body: some View {
        switch session.state {
        case .disconnected:
            accountButton(title: "BLUESKY ACCOUNT", detail: "CONNECT TO POST", active: true)
        case .restoring:
            HStack(spacing: 10) {
                TPTerminalActivityGlyph()
                Text("RESTORING BLUESKY SESSION")
            }
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(TPPlayTheme.secondaryText)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(TPPlayTheme.surface)
            .overlay { Rectangle().stroke(TPPlayTheme.border, lineWidth: 1) }
        case .authorizing:
            accountButton(title: "BLUESKY AUTHORIZATION", detail: "WAITING FOR APPROVAL", active: false)
        case .connected(let handle, _):
            accountButton(title: "@\(handle)", detail: "CONNECTED", active: false)
        case .failed:
            accountButton(title: "BLUESKY ACCOUNT", detail: "AUTHORIZATION NEEDS ATTENTION", active: true)
        }
    }

    private func accountButton(title: String, detail: String, active: Bool) -> some View {
        Button(action: openAccount) {
            HStack(spacing: 10) {
                Rectangle()
                    .fill(active ? TPPlayTheme.accent : TPPlayTheme.violet)
                    .frame(width: 8, height: 8)
                Text(title)
                    .foregroundStyle(TPPlayTheme.primaryText)
                    .lineLimit(1)
                Spacer()
                Text(detail)
                    .foregroundStyle(active ? TPPlayTheme.accent : TPPlayTheme.secondaryText)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
            }
            .font(.system(size: 9, weight: .black, design: .monospaced))
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(TPPlayTheme.surface)
            .overlay { Rectangle().stroke(TPPlayTheme.border, lineWidth: 1) }
        }
        .buttonStyle(CommunityPressStyle())
    }
}

private enum CommunityDestination: String, Identifiable {
    case search, profile, compose
    var id: String { rawValue }
}

private struct CommunityPostCard: View {
    let post: CommunityPost
    @ObservedObject var store: CommunityStore
    let openThread: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Button(action: openThread) {
                    authorLine
                        .contentShape(Rectangle())
                }
                .buttonStyle(CommunityPressStyle())

                CommunityRichText(post: post, openThread: openThread)

                if let mediaLabel = post.mediaLabel {
                    CommunityMediaBlock(label: mediaLabel, altText: post.altText)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle().fill(TPPlayTheme.border).frame(height: 1)
            actionBar
        }
        .background(TPPlayTheme.surface)
        .overlay { Rectangle().stroke(TPPlayTheme.violet, lineWidth: 1) }
    }

    private var authorLine: some View {
        HStack(spacing: 10) {
            CommunityAvatar(author: post.author, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(post.author.displayName)
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .foregroundStyle(TPPlayTheme.primaryText)
                    .lineLimit(1)
                Text("@\(post.author.handle)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(TPPlayTheme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(post.timestamp)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(TPPlayTheme.tertiaryText)
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(TPPlayTheme.secondaryText)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 0) {
            CommunityPostAction(symbol: "bubble.left", count: post.replyCount, active: false, action: openThread)
            CommunityPostAction(symbol: "arrow.2.squarepath", count: post.repostCount, active: post.isReposted) { store.toggleRepost(post) }
            CommunityPostAction(symbol: post.isLiked ? "heart.fill" : "heart", count: post.likeCount, active: post.isLiked) { store.toggleLike(post) }
            ShareLink(item: post.text) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(TPPlayTheme.secondaryText)
        }
    }
}

private struct CommunityPostAction: View {
    let symbol: String
    let count: Int
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                if count > 0 { Text("\(count)") }
            }
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(active ? TPPlayTheme.accent : TPPlayTheme.secondaryText)
            .frame(maxWidth: .infinity, minHeight: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(CommunityPressStyle())
    }
}

private struct CommunityMediaBlock: View {
    let label: String
    let altText: String?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            TPPlayTheme.surfaceRaised
            VStack(spacing: 10) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 30, weight: .black))
                    .foregroundStyle(TPPlayTheme.violet)
                Text(label)
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(TPPlayTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if altText != nil {
                Text("ALT")
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .foregroundStyle(TPPlayTheme.onAccent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(TPPlayTheme.accent)
                    .padding(8)
            }
        }
        .frame(height: 154)
        .overlay { Rectangle().stroke(TPPlayTheme.border, lineWidth: 1) }
        .accessibilityLabel(altText ?? label)
    }
}

private struct CommunitySearchView: View {
    @ObservedObject var store: CommunityStore
    let onClose: () -> Void
    @State private var query = ""
    @State private var tab: SearchTab = .posts
    @State private var managingFeeds = false

    private var filteredPosts: [CommunityPost] {
        guard !query.isEmpty else { return store.posts }
        return store.posts.filter {
            $0.text.localizedCaseInsensitiveContains(query) ||
            $0.author.displayName.localizedCaseInsensitiveContains(query) ||
            $0.author.handle.localizedCaseInsensitiveContains(query)
        }
    }

    private var people: [CommunityAuthor] {
        var seen = Set<String>()
        return store.posts.map(\.author).filter { seen.insert($0.id).inserted }.filter {
            query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query) || $0.handle.localizedCaseInsensitiveContains(query)
        }
    }

    private var feeds: [CommunityFeed] {
        store.feeds.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.description.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                CommunityScreenHeader(title: "COMMUNITY // SEARCH", dismiss: onClose)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 0) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(TPPlayTheme.secondaryText)
                            .frame(width: 42)
                        TextField("SEARCH POSTS, PEOPLE, FEEDS", text: $query)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(TPPlayTheme.primaryText)
                        if !query.isEmpty {
                            Button { query = "" } label: {
                                Image(systemName: "xmark").frame(width: 42, height: 44)
                            }
                            .foregroundStyle(TPPlayTheme.secondaryText)
                        }
                    }
                    .frame(height: 46)
                    .background(TPPlayTheme.surface)
                    .overlay { Rectangle().stroke(TPPlayTheme.violet, lineWidth: 1) }

                    HStack(spacing: 8) {
                        ForEach(SearchTab.allCases) { item in
                            Button(item.rawValue) { tab = item }
                                .frame(maxWidth: .infinity, minHeight: 38)
                                .buttonStyle(AcidButtonStyle(active: tab == item))
                        }
                    }

                        searchResults
                    }
                    .padding(20)
                }
            }
            .background(TPPlayTheme.canvas.ignoresSafeArea())
            .allowsHitTesting(!managingFeeds)
            .communityEdgeSwipeDismiss(onClose)

            if managingFeeds {
                CommunityFeedManagerView(store: store) { managingFeeds = false }
                    .zIndex(1)
            }
        }
        .background(TPPlayTheme.canvas.ignoresSafeArea())
    }

    @ViewBuilder private var searchResults: some View {
        switch tab {
        case .posts:
            ForEach(filteredPosts) { CommunityPostCard(post: $0, store: store, openThread: {}) }
        case .people:
            ForEach(people) { CommunityPersonRow(author: $0) }
        case .feeds:
            Button("MANAGE ADDED FEEDS >") { managingFeeds = true }
                .frame(maxWidth: .infinity, minHeight: 44)
                .buttonStyle(AcidButtonStyle())
            ForEach(feeds) { CommunityFeedRow(feed: $0, store: store) }
        }
    }
}

private enum SearchTab: String, CaseIterable, Identifiable {
    case posts = "POSTS", people = "PEOPLE", feeds = "FEEDS"
    var id: String { rawValue }
}

private struct CommunityFeedRow: View {
    let feed: CommunityFeed
    @ObservedObject var store: CommunityStore

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                TPPlayTheme.surfaceRaised
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(TPPlayTheme.accent)
            }
            .frame(width: 46, height: 46)
            .overlay { Rectangle().stroke(TPPlayTheme.border, lineWidth: 1) }

            VStack(alignment: .leading, spacing: 5) {
                Text(feed.name)
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .foregroundStyle(TPPlayTheme.primaryText)
                Text(feed.description)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(TPPlayTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(feed.creator.uppercased())
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(TPPlayTheme.tertiaryText)
            }
            Spacer(minLength: 8)
            Button(feed.isAdded ? "ADDED" : "+ ADD") { store.toggleFeed(feed) }
                .frame(width: 74, height: 38)
                .buttonStyle(AcidButtonStyle(active: feed.isAdded))
                .disabled(feed.isFixed)
        }
        .padding(12)
        .background(TPPlayTheme.surface)
        .overlay { Rectangle().stroke(TPPlayTheme.border, lineWidth: 1) }
    }
}

private struct CommunityFeedManagerView: View {
    @ObservedObject var store: CommunityStore
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            CommunityScreenHeader(title: "COMMUNITY // FEEDS", dismiss: onClose)
            List {
                Section {
                    ForEach(store.addedFeeds.filter { $0.isFixed }) { feed in
                        feedItem(feed, fixed: true)
                    }
                }
                Section {
                    ForEach(store.addedFeeds.filter { !$0.isFixed }) { feed in
                        feedItem(feed, fixed: false)
                    }
                    .onMove(perform: store.moveAddedFeeds)
                }
            }
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
        }
        .background(TPPlayTheme.canvas.ignoresSafeArea())
        .communityEdgeSwipeDismiss(onClose)
    }

    private func feedItem(_ feed: CommunityFeed, fixed: Bool) -> some View {
        HStack {
            Image(systemName: fixed ? "lock.fill" : "line.3.horizontal")
                .foregroundStyle(fixed ? TPPlayTheme.tertiaryText : TPPlayTheme.accent)
            Text(feed.name)
                .font(.system(size: 12, weight: .black, design: .monospaced))
                .foregroundStyle(TPPlayTheme.primaryText)
            Spacer()
            if !fixed {
                Button("REMOVE") { store.toggleFeed(feed) }
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(TPPlayTheme.danger)
            }
        }
        .listRowBackground(TPPlayTheme.surface)
        .listRowSeparatorTint(TPPlayTheme.border)
    }
}

private struct CommunityPersonRow: View {
    let author: CommunityAuthor
    @State private var following: Bool

    init(author: CommunityAuthor) {
        self.author = author
        _following = State(initialValue: author.isFollowing)
    }

    var body: some View {
        HStack(spacing: 12) {
            CommunityAvatar(author: author, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(author.displayName)
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .foregroundStyle(TPPlayTheme.primaryText)
                Text("@\(author.handle)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(TPPlayTheme.secondaryText)
            }
            Spacer()
            Button(following ? "FOLLOWING" : "FOLLOW") { following.toggle() }
                .frame(width: 94, height: 38)
                .buttonStyle(AcidButtonStyle(active: following))
        }
        .padding(12)
        .background(TPPlayTheme.surface)
        .overlay { Rectangle().stroke(TPPlayTheme.border, lineWidth: 1) }
    }
}

private struct CommunityProfileView: View {
    @ObservedObject var store: CommunityStore
    @ObservedObject var session: CommunityOAuthSession
    let onClose: () -> Void
    @State private var matureContent = false
    @State private var notifications = true
    @State private var mutedWords = ""
    @State private var loginHandle = ""

    var body: some View {
        VStack(spacing: 0) {
            CommunityScreenHeader(title: "PROFILE // ACCOUNT", dismiss: onClose) {
                EmptyView()
            }
            ScrollView {
                if session.isAuthenticated {
                    connectedAccount
                } else {
                    disconnectedAccount
                }
            }
        }
        .background(TPPlayTheme.canvas.ignoresSafeArea())
        .communityEdgeSwipeDismiss(onClose)
    }

    private var connectedAccount: some View {
        VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        CommunityAvatar(author: store.profileAuthor, size: 68)
                        if let profile = store.profile {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(profile.displayName)
                                    .font(.system(size: 15, weight: .black, design: .monospaced))
                                    .foregroundStyle(TPPlayTheme.primaryText)
                                Text("@\(profile.handle)")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(TPPlayTheme.secondaryText)
                            }
                        }
                    }

                    CommunityFieldLabel("DISPLAY NAME")
                    CommunityReadOnlyField(store.profile?.displayName ?? "LOADING")
                    CommunityFieldLabel("HANDLE")
                    Text("@\(session.connectedHandle ?? store.currentUser.handle)")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(TPPlayTheme.secondaryText)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                        .background(TPPlayTheme.surface)
                        .overlay { Rectangle().stroke(TPPlayTheme.border, lineWidth: 1) }
                    CommunityFieldLabel("BIO")
                    Text(store.profile?.bio.isEmpty == false ? store.profile?.bio ?? "" : "NO BIO")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(store.profile?.bio.isEmpty == false ? TPPlayTheme.primaryText : TPPlayTheme.tertiaryText)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: 94)
                        .background(TPPlayTheme.surface)
                        .overlay { Rectangle().stroke(TPPlayTheme.border, lineWidth: 1) }

                    if let profile = store.profile {
                        HStack(spacing: 0) {
                            CommunityProfileMetric(value: profile.postsCount, label: "POSTS")
                            CommunityProfileMetric(value: profile.followsCount, label: "FOLLOWING")
                            CommunityProfileMetric(value: profile.followersCount, label: "FOLLOWERS")
                        }
                    }

                    CommunitySectionTitle("BLUESKY ACCOUNT")
                    CommunitySettingRow(title: "@\(session.connectedHandle ?? store.currentUser.handle)", detail: "CONNECTED", value: .constant(true))
                    if let did = session.connectedDID {
                        Text(did)
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundStyle(TPPlayTheme.tertiaryText)
                            .textSelection(.enabled)
                    }

                    CommunitySectionTitle("CONTENT & SAFETY")
                    CommunitySettingRow(title: "ADULT CONTENT", detail: "SHOW LABELED CONTENT", value: $matureContent)
                    CommunityTextSetting(title: "MUTED WORDS", value: $mutedWords, placeholder: "ADD WORDS OR TAGS")
                    CommunityLinkSetting(title: "BLOCKED ACCOUNTS", detail: "MANAGE >")

                    CommunitySectionTitle("NOTIFICATIONS")
                    CommunitySettingRow(title: "PUSH NOTIFICATIONS", detail: "MENTIONS, REPLIES, FOLLOWS", value: $notifications)

                    Button("DISCONNECT BLUESKY ACCOUNT") { session.disconnect() }
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .foregroundStyle(TPPlayTheme.danger)
                        .background(TPPlayTheme.surface)
                        .overlay { Rectangle().stroke(TPPlayTheme.danger, lineWidth: 1) }
                        .font(.system(size: 10, weight: .black, design: .monospaced))
        }
        .padding(20)
    }

    private var disconnectedAccount: some View {
        VStack(alignment: .leading, spacing: 16) {
            CommunitySectionTitle("BLUESKY ACCOUNT")
            CommunityFieldLabel("HANDLE")
            TextField("NAME.BSKY.SOCIAL", text: $loginHandle)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(AcidFieldStyle())

            switch session.state {
            case .authorizing, .restoring:
                HStack(spacing: 10) {
                    TPTerminalActivityGlyph(color: TPPlayTheme.onAccent)
                    Text(session.state == .restoring ? "RESTORING" : "WAITING FOR AUTHORIZATION")
                }
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundStyle(TPPlayTheme.onAccent)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(TPPlayTheme.accent)
            case .failed(let message):
                Text(message)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(TPPlayTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                Button("TRY AGAIN") { session.retry() }
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .buttonStyle(AcidButtonStyle())
            default:
                Button("CONTINUE WITH BLUESKY") { session.signIn(handle: loginHandle) }
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .buttonStyle(AcidButtonStyle(active: !loginHandle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    .disabled(loginHandle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Text("TP PLAY OPENS THE ACCOUNT PROVIDER IN A SECURE BROWSER. YOUR PASSWORD IS NEVER ENTERED IN THIS APP.")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(TPPlayTheme.tertiaryText)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }
}

private struct CommunityComposerView: View {
    @ObservedObject var store: CommunityStore
    @ObservedObject var session: CommunityOAuthSession
    let onClose: () -> Void
    @State private var isPosting = false
    @State private var postError: String?

    private var trimmedDraft: String {
        store.draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canPost: Bool {
        session.isAuthenticated && !isPosting && !trimmedDraft.isEmpty && store.draft.count <= 300
    }

    var body: some View {
        VStack(spacing: 0) {
            CommunityScreenHeader(title: "COMMUNITY // NEW POST", dismiss: onClose) {
                Button("POST") {
                    publish()
                }
                .frame(width: 68, height: 40)
                .buttonStyle(AcidButtonStyle(active: canPost))
                .disabled(!canPost)
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    CommunityAvatar(author: store.profileAuthor, size: 38)
                    Text("@\(session.connectedHandle ?? store.currentUser.handle)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(TPPlayTheme.secondaryText)
                    Spacer()
                    if isPosting {
                        TPTerminalActivityGlyph()
                    }
                }
                TextEditor(text: $store.draft)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(TPPlayTheme.primaryText)
                    .frame(minHeight: 210)
                    .padding(10)
                    .background(TPPlayTheme.surface)
                    .overlay { Rectangle().stroke(TPPlayTheme.violet, lineWidth: 1) }
                if let postError {
                    Text(postError)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(TPPlayTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text("TEXT POST")
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .foregroundStyle(TPPlayTheme.secondaryText)
                    Spacer()
                    Text("\(store.draft.count) / 300")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(store.draft.count > 300 ? TPPlayTheme.danger : TPPlayTheme.tertiaryText)
                }
                Spacer()
            }
            .padding(20)
        }
        .background(TPPlayTheme.canvas.ignoresSafeArea())
        .communityEdgeSwipeDismiss(onClose)
    }

    private func publish() {
        guard canPost else { return }
        isPosting = true
        postError = nil
        Task {
            do {
                try await session.publishPost(text: trimmedDraft)
                store.publish(as: session.connectedHandle)
                onClose()
            } catch {
                postError = error.localizedDescription.uppercased()
                isPosting = false
            }
        }
    }
}

private struct CommunityThreadView: View {
    let root: CommunityPost
    @ObservedObject var store: CommunityStore
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            CommunityScreenHeader(title: "COMMUNITY // THREAD", dismiss: onClose)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    CommunityPostCard(post: root, store: store, openThread: {})
                    ForEach(store.posts.filter { $0.parentID == root.id }) {
                        CommunityPostCard(post: $0, store: store, openThread: {})
                    }
                }
                .padding(20)
            }
            HStack(spacing: 10) {
                TextField("REPLY", text: $store.draft).textFieldStyle(AcidFieldStyle())
                Button("SEND") { store.publish(parentID: root.id) }
                    .frame(width: 72, height: 46)
                    .buttonStyle(AcidButtonStyle(active: !store.draft.isEmpty))
            }
            .padding(12)
            .background(TPPlayTheme.surface)
            .overlay(alignment: .top) { Rectangle().fill(TPPlayTheme.border).frame(height: 1) }
        }
        .background(TPPlayTheme.canvas.ignoresSafeArea())
        .communityEdgeSwipeDismiss(onClose)
    }
}

private struct CommunityRichText: UIViewRepresentable {
    let post: CommunityPost
    let openThread: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(openThread: openThread)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.isEditable = false
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.delegate = context.coordinator
        view.linkTextAttributes = [
            .foregroundColor: UIColor(TPPlayTheme.accent),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.didTapText(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        context.coordinator.textView = view
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.openThread = openThread
        view.attributedText = attributedText
        view.accessibilityLabel = post.text
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    private var attributedText: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        let output = NSMutableAttributedString(
            string: post.text,
            attributes: [
                .font: UIFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: UIColor(TPPlayTheme.primaryText),
                .paragraphStyle: paragraph,
            ]
        )
        let utf8 = post.text.utf8

        for link in post.links {
            guard link.byteStart >= 0,
                  link.byteEnd >= link.byteStart,
                  link.byteEnd <= utf8.count else { continue }
            let startUTF8 = utf8.index(utf8.startIndex, offsetBy: link.byteStart)
            let endUTF8 = utf8.index(utf8.startIndex, offsetBy: link.byteEnd)
            guard let start = String.Index(startUTF8, within: post.text),
                  let end = String.Index(endUTF8, within: post.text) else { continue }
            output.addAttribute(.link, value: link.url, range: NSRange(start..<end, in: post.text))
        }
        return output
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var openThread: () -> Void
        weak var textView: UITextView?

        init(openThread: @escaping () -> Void) {
            self.openThread = openThread
        }

        @objc func didTapText(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            openThread()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let textView else { return true }
            var point = touch.location(in: textView)
            point.x -= textView.textContainerInset.left
            point.y -= textView.textContainerInset.top
            let glyph = textView.layoutManager.glyphIndex(
                for: point,
                in: textView.textContainer,
                fractionOfDistanceThroughGlyph: nil
            )
            guard glyph < textView.layoutManager.numberOfGlyphs else { return true }
            let character = textView.layoutManager.characterIndexForGlyph(at: glyph)
            guard character < textView.attributedText.length else { return true }
            return textView.attributedText.attribute(.link, at: character, effectiveRange: nil) == nil
        }
    }
}

private struct CommunityEdgeSwipeDismiss: ViewModifier {
    let dismiss: () -> Void
    @State private var dragOffset: CGFloat = 0
    @State private var isCompleting = false

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            content
                .offset(x: dragOffset)
                .overlay(alignment: .leading) {
                    if !isCompleting {
                        Color.clear
                            .contentShape(Rectangle())
                            .frame(width: 28)
                            .gesture(edgeBackGesture(viewportWidth: geometry.size.width))
                            .accessibilityHidden(true)
                    }
                }
        }
    }

    private func edgeBackGesture(viewportWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard value.translation.width > 0,
                      abs(value.translation.height) < value.translation.width * 1.2 else { return }
                dragOffset = min(value.translation.width, viewportWidth)
            }
            .onEnded { value in
                let shouldClose = dragOffset > viewportWidth * 0.3
                    || value.predictedEndTranslation.width > viewportWidth * 0.55
                if shouldClose {
                    isCompleting = true
                    withAnimation(.easeOut(duration: 0.18)) {
                        dragOffset = viewportWidth
                    }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(180))
                        dismiss()
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.18)) {
                        dragOffset = 0
                    }
                }
            }
    }
}

private extension View {
    func communityEdgeSwipeDismiss(_ dismiss: @escaping () -> Void) -> some View {
        modifier(CommunityEdgeSwipeDismiss(dismiss: dismiss))
    }
}

private struct CommunityScreenHeader<Actions: View>: View {
    let title: String
    let dismiss: () -> Void
    private let actions: Actions

    init(title: String, dismiss: @escaping () -> Void, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.dismiss = dismiss
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: dismiss) {
                Image(systemName: "chevron.left").frame(width: 42, height: 42)
            }
            .buttonStyle(AcidButtonStyle())
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(TPPlayTheme.accent)
                .lineLimit(1)
            Spacer()
            actions
        }
        .padding(.horizontal, 20)
        .frame(height: 64)
        .background(TPPlayTheme.canvas)
        .overlay(alignment: .bottom) { Rectangle().fill(TPPlayTheme.border).frame(height: 1) }
    }
}

private extension CommunityScreenHeader where Actions == EmptyView {
    init(title: String, dismiss: @escaping () -> Void) {
        self.init(title: title, dismiss: dismiss) { EmptyView() }
    }
}

private struct CommunitySquareButton: View {
    let symbol: String
    let label: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .black))
                .frame(width: 42, height: 42)
        }
        .buttonStyle(AcidButtonStyle(active: active))
        .accessibilityLabel(label)
    }
}

private struct CommunityAvatar: View {
    let author: CommunityAuthor
    let size: CGFloat

    var body: some View {
        ZStack {
            TPPlayTheme.violet
            if let avatarURL = author.avatarURL {
                AsyncImage(url: avatarURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        initials
                    }
                }
            } else {
                initials
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .overlay { Rectangle().stroke(TPPlayTheme.accent, lineWidth: 1) }
        .accessibilityLabel(author.displayName)
    }

    private var initials: some View {
        Text(author.initials)
            .font(.system(size: size * 0.3, weight: .black, design: .monospaced))
            .foregroundStyle(TPPlayTheme.primaryText)
    }
}

private struct CommunityReadOnlyField: View {
    let value: String
    init(_ value: String) { self.value = value }

    var body: some View {
        Text(value)
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundStyle(TPPlayTheme.primaryText)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            .background(TPPlayTheme.surface)
            .overlay { Rectangle().stroke(TPPlayTheme.border, lineWidth: 1) }
    }
}

private struct CommunityProfileMetric: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value.formatted())
                .font(.system(size: 14, weight: .black, design: .monospaced))
                .foregroundStyle(TPPlayTheme.primaryText)
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(TPPlayTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, minHeight: 58)
        .background(TPPlayTheme.surface)
        .overlay { Rectangle().stroke(TPPlayTheme.border, lineWidth: 1) }
    }
}

private struct CommunitySettingRow: View {
    let title: String
    let detail: String
    @Binding var value: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).foregroundStyle(TPPlayTheme.primaryText)
                Text(detail).foregroundStyle(TPPlayTheme.tertiaryText)
            }
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            Spacer()
            Toggle("", isOn: $value).labelsHidden().tint(TPPlayTheme.accent)
        }
        .padding(12)
        .background(TPPlayTheme.surface)
        .overlay { Rectangle().stroke(TPPlayTheme.border, lineWidth: 1) }
    }
}

private struct CommunityTextSetting: View {
    let title: String
    @Binding var value: String
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CommunityFieldLabel(title)
            TextField(placeholder, text: $value).textFieldStyle(AcidFieldStyle())
        }
    }
}

private struct CommunityLinkSetting: View {
    let title: String
    let detail: String
    var body: some View {
        Button {} label: {
            HStack {
                Text(title)
                Spacer()
                Text(detail).foregroundStyle(TPPlayTheme.accent)
            }
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(TPPlayTheme.primaryText)
            .padding(12)
            .frame(minHeight: 46)
            .background(TPPlayTheme.surface)
            .overlay { Rectangle().stroke(TPPlayTheme.border, lineWidth: 1) }
        }
        .buttonStyle(CommunityPressStyle())
    }
}

private struct CommunityFieldLabel: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.system(size: 9, weight: .black, design: .monospaced))
            .tracking(0.8)
            .foregroundStyle(TPPlayTheme.secondaryText)
    }
}

private struct CommunitySectionTitle: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text("// \(title)")
            .font(.system(size: 10, weight: .black, design: .monospaced))
            .tracking(1)
            .foregroundStyle(TPPlayTheme.accent)
            .padding(.top, 8)
    }
}

private struct CommunityPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.62 : 1)
    }
}

#Preview { CommunityView() }
