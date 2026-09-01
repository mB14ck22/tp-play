import Foundation

struct FeedSource: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var url: URL
    var title: String
    var addedAt: Date
    var lastFetchedAt: Date?
    var lastError: String?
}

struct FeedArticle: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let sourceID: UUID
    let sourceTitle: String
    let title: String
    let summary: String
    let link: URL
    let publishedAt: Date?
    let imageURL: URL?
    let fetchedAt: Date
}

struct FeedSyncEvent: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let date: Date
    let sourceTitle: String
    let succeeded: Bool
    let message: String
}

@MainActor
final class NewsStore: ObservableObject {
    @Published private(set) var sources: [FeedSource] = []
    @Published private(set) var articles: [FeedArticle] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshMessage: String?
    @Published private(set) var syncEvents: [FeedSyncEvent] = []

    private let snapshotURL: URL?

    init() {
        snapshotURL = Self.makeSnapshotURL()
        loadSnapshot()
    }

    func addSource(address: String) async throws {
        let url = try Self.normalizedURL(from: address)
        guard !sources.contains(where: { $0.url.absoluteString.caseInsensitiveCompare(url.absoluteString) == .orderedSame }) else {
            throw FeedError.message("THIS SOURCE IS ALREADY CONNECTED.")
        }

        let payload = try await FeedLoader.load(from: url)
        let now = Date()
        let source = FeedSource(
            id: UUID(),
            url: url,
            title: payload.title.nonempty ?? url.host ?? "UNTITLED SOURCE",
            addedAt: now,
            lastFetchedAt: now,
            lastError: nil
        )
        sources.append(source)
        merge(payload.items, from: source, fetchedAt: now)
        recordSync(source: source.title, succeeded: true, message: "SOURCE CONNECTED")
        refreshMessage = "CONNECTED // \(source.title.uppercased())"
        saveSnapshot()
    }

    func removeSource(_ source: FeedSource) {
        sources.removeAll { $0.id == source.id }
        articles.removeAll { $0.sourceID == source.id }
        saveSnapshot()
    }

    func refreshAll() async {
        guard !isRefreshing else { return }
        guard !sources.isEmpty else {
            refreshMessage = "NO SOURCES CONNECTED."
            return
        }

        isRefreshing = true
        refreshMessage = nil
        var successCount = 0

        for sourceID in sources.map(\.id) {
            guard let index = sources.firstIndex(where: { $0.id == sourceID }) else { continue }
            let source = sources[index]
            do {
                let payload = try await FeedLoader.load(from: source.url)
                let now = Date()
                sources[index].title = payload.title.nonempty ?? source.title
                sources[index].lastFetchedAt = now
                sources[index].lastError = nil
                merge(payload.items, from: sources[index], fetchedAt: now)
                recordSync(source: sources[index].title, succeeded: true, message: "SYNC COMPLETE // \(payload.items.count) ITEMS")
                successCount += 1
            } catch {
                let message = error.localizedDescription.uppercased()
                sources[index].lastError = message
                recordSync(source: source.title, succeeded: false, message: message)
            }
        }

        isRefreshing = false
        let failedCount = sources.count - successCount
        refreshMessage = failedCount == 0
            ? "SYNC COMPLETE // \(successCount) SOURCES"
            : "SYNC PARTIAL // \(successCount) OK // \(failedCount) FAILED"
        saveSnapshot()
    }

    private func merge(_ items: [ParsedFeedItem], from source: FeedSource, fetchedAt: Date) {
        let incoming = items.compactMap { item -> FeedArticle? in
            guard let link = item.link else { return nil }
            let identity = item.identifier.nonempty ?? link.absoluteString
            return FeedArticle(
                id: "\(source.id.uuidString)|\(identity)",
                sourceID: source.id,
                sourceTitle: source.title,
                title: item.title.nonempty ?? "UNTITLED TRANSMISSION",
                summary: item.summary.cleanedFeedText,
                link: link,
                publishedAt: item.publishedAt,
                imageURL: item.imageURL,
                fetchedAt: fetchedAt
            )
        }

        var indexed = Dictionary(uniqueKeysWithValues: articles.map { ($0.id, $0) })
        incoming.forEach { indexed[$0.id] = $0 }
        articles = indexed.values
            .sorted { ($0.publishedAt ?? $0.fetchedAt) > ($1.publishedAt ?? $1.fetchedAt) }
            .prefix(500)
            .map { $0 }
    }

    private func loadSnapshot() {
        guard let snapshotURL,
              let data = try? Data(contentsOf: snapshotURL),
              let snapshot = try? JSONDecoder().decode(NewsSnapshot.self, from: data) else { return }
        sources = snapshot.sources
        articles = snapshot.articles
        syncEvents = snapshot.syncEvents ?? []
    }

    private func saveSnapshot() {
        guard let snapshotURL,
              let data = try? JSONEncoder().encode(NewsSnapshot(sources: sources, articles: articles, syncEvents: syncEvents)) else { return }
        try? data.write(to: snapshotURL, options: .atomic)
    }

    private func recordSync(source: String, succeeded: Bool, message: String) {
        syncEvents.insert(FeedSyncEvent(id: UUID(), date: Date(), sourceTitle: source, succeeded: succeeded, message: message), at: 0)
        syncEvents = Array(syncEvents.prefix(50))
    }

    private static func makeSnapshotURL() -> URL? {
        guard let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let appDirectory = directory.appendingPathComponent("TPPlay", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        return appDirectory.appendingPathComponent("news.json")
    }

    private static func normalizedURL(from input: String) throws -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              ["https", "http"].contains(scheme),
              components.host != nil,
              let url = components.url else {
            throw FeedError.message("ENTER A VALID HTTP OR HTTPS FEED URL.")
        }
        return url
    }
}

private struct NewsSnapshot: Codable {
    let sources: [FeedSource]
    let articles: [FeedArticle]
    let syncEvents: [FeedSyncEvent]?
}

struct ParsedFeedItem: Sendable {
    var identifier = ""
    var title = ""
    var summary = ""
    var link: URL?
    var publishedAt: Date?
    var imageURL: URL?
}

struct FeedPayload: Sendable {
    var title: String
    var items: [ParsedFeedItem]
}

enum FeedLoader {
    static func load(from url: URL) async throws -> FeedPayload {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/rss+xml, application/atom+xml, application/feed+json, application/json, application/xml, text/xml;q=0.9, */*;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue("TPPlay/1.0 (iOS Feed Reader)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FeedError.message("SOURCE RETURNED HTTP \(http.statusCode).")
        }
        guard !data.isEmpty else { throw FeedError.message("SOURCE RETURNED NO DATA.") }

        let firstByte = data.first { byte in
            byte != 0x20 && byte != 0x0A && byte != 0x0D && byte != 0x09
        }
        if firstByte == Character("{").asciiValue {
            return try parseJSONFeed(data, baseURL: url)
        }
        return try parseXMLFeed(data, baseURL: url)
    }

    private static func parseJSONFeed(_ data: Data, baseURL: URL) throws -> FeedPayload {
        let decoder = JSONDecoder()
        let feed: JSONFeed
        do {
            feed = try decoder.decode(JSONFeed.self, from: data)
        } catch {
            throw FeedError.message("JSON FEED COULD NOT BE PARSED.")
        }

        let items = feed.items.compactMap { item -> ParsedFeedItem? in
            guard let link = resolvedURL(item.url ?? item.externalURL, relativeTo: baseURL) else { return nil }
            var parsed = ParsedFeedItem()
            parsed.identifier = item.id
            parsed.title = item.title ?? ""
            parsed.summary = item.summary ?? item.contentText ?? item.contentHTML ?? ""
            parsed.link = link
            parsed.publishedAt = FeedDateParser.parse(item.datePublished ?? item.dateModified)
            parsed.imageURL = resolvedURL(item.image ?? item.bannerImage, relativeTo: baseURL)
            return parsed
        }
        guard !items.isEmpty else { throw FeedError.message("NO READABLE ARTICLES WERE FOUND.") }
        return FeedPayload(title: feed.title ?? baseURL.host ?? "JSON FEED", items: items)
    }

    private static func parseXMLFeed(_ data: Data, baseURL: URL) throws -> FeedPayload {
        let delegate = XMLFeedParser(baseURL: baseURL)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            throw FeedError.message(parser.parserError?.localizedDescription.uppercased() ?? "XML FEED COULD NOT BE PARSED.")
        }
        guard !delegate.items.isEmpty else { throw FeedError.message("NO READABLE ARTICLES WERE FOUND.") }
        return FeedPayload(title: delegate.feedTitle.nonempty ?? baseURL.host ?? "XML FEED", items: delegate.items)
    }

    fileprivate static func resolvedURL(_ value: String?, relativeTo baseURL: URL) -> URL? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return URL(string: value, relativeTo: baseURL)?.absoluteURL
    }
}

private final class XMLFeedParser: NSObject, XMLParserDelegate {
    let baseURL: URL
    var feedTitle = ""
    var items: [ParsedFeedItem] = []

    private var currentItem: ParsedFeedItem?
    private var currentElement = ""
    private var currentText = ""

    init(baseURL: URL) { self.baseURL = baseURL }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = (qName ?? elementName).lowercased()
        currentElement = name
        currentText = ""
        if name == "item" || name == "entry" {
            currentItem = ParsedFeedItem()
        }

        guard currentItem != nil else { return }
        if name == "link", let href = attributeDict["href"], attributeDict["rel"] != "enclosure" {
            currentItem?.link = FeedLoader.resolvedURL(href, relativeTo: baseURL)
        }
        if (name.contains("thumbnail") || name.contains("content") || name == "enclosure"),
           let candidate = attributeDict["url"],
           name.contains("media") || attributeDict["type"]?.hasPrefix("image/") == true {
            currentItem?.imageURL = FeedLoader.resolvedURL(candidate, relativeTo: baseURL)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let string = String(data: CDATABlock, encoding: .utf8) { currentText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = (qName ?? elementName).lowercased()
        let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if name == "item" || name == "entry" {
            if let currentItem { items.append(currentItem) }
            currentItem = nil
            currentText = ""
            return
        }

        if currentItem != nil {
            switch name {
            case "title": currentItem?.title += value
            case "guid", "id": currentItem?.identifier = value
            case "link":
                if currentItem?.link == nil { currentItem?.link = FeedLoader.resolvedURL(value, relativeTo: baseURL) }
            case "description", "summary", "content", "content:encoded", "encoded":
                if value.count > (currentItem?.summary.count ?? 0) { currentItem?.summary = value }
            case "pubdate", "published", "updated", "date", "dc:date":
                currentItem?.publishedAt = FeedDateParser.parse(value)
            default: break
            }
        } else if name == "title", feedTitle.isEmpty {
            feedTitle = value
        }
        currentText = ""
    }
}

private struct JSONFeed: Decodable {
    let title: String?
    let items: [JSONFeedItem]
}

private struct JSONFeedItem: Decodable {
    let id: String
    let url: String?
    let externalURL: String?
    let title: String?
    let summary: String?
    let contentText: String?
    let contentHTML: String?
    let datePublished: String?
    let dateModified: String?
    let image: String?
    let bannerImage: String?

    enum CodingKeys: String, CodingKey {
        case id, url, title, summary, image
        case externalURL = "external_url"
        case contentText = "content_text"
        case contentHTML = "content_html"
        case datePublished = "date_published"
        case dateModified = "date_modified"
        case bannerImage = "banner_image"
    }
}

private enum FeedDateParser {
    static func parse(_ value: String?) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }

        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss Z", "yyyy-MM-dd HH:mm:ss Z"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}

enum FeedError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let message) = self { return message }
        return nil
    }
}

private extension String {
    var nonempty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var cleanedFeedText: String {
        var value = replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">"]
        entities.forEach { value = value.replacingOccurrences(of: $0.key, with: $0.value) }
        value = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
