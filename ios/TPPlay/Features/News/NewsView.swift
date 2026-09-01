import SwiftUI
import WebKit

struct NewsView: View {
    @StateObject private var store = NewsStore()
    @State private var selectedSourceID: UUID?
    @State private var showingSources = false
    @State private var didRequestInitialRefresh = false
    @State private var openArticle: FeedArticle?

    private var visibleArticles: [FeedArticle] {
        guard let selectedSourceID else { return store.articles }
        return store.articles.filter { $0.sourceID == selectedSourceID }
    }

    var body: some View {
        ZStack {
            TPPlayTheme.canvas.ignoresSafeArea()
            if let openArticle {
                ArticleBrowserView(article: openArticle) { self.openArticle = nil }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        header
                        sourceRail
                        statusLine
                        content
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
                .refreshable { await store.refreshAll() }
            }
        }
        .fullScreenCover(isPresented: $showingSources) {
            FeedSourcesView(store: store)
        }
        .task {
            guard !didRequestInitialRefresh, !store.sources.isEmpty else { return }
            didRequestInitialRefresh = true
            await store.refreshAll()
        }
        .onChange(of: store.sources) { _, sources in
            if let selectedSourceID, !sources.contains(where: { $0.id == selectedSourceID }) {
                self.selectedSourceID = nil
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("NEWS // FEED")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(TPPlayTheme.accent)
                Text("INDEPENDENT SIGNALS")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(0.7)
                    .foregroundStyle(TPPlayTheme.secondaryText)
            }
            Spacer()
            Button {
                Task { await store.refreshAll() }
            } label: {
                Group {
                    if store.isRefreshing { ProgressView().tint(TPPlayTheme.primaryText) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .font(.system(size: 14, weight: .black))
                .frame(width: 42, height: 42)
            }
            .buttonStyle(AcidButtonStyle())
            .disabled(store.isRefreshing || store.sources.isEmpty)

            Button { showingSources = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .black))
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(AcidButtonStyle(active: true))
            .accessibilityLabel("Manage feed sources")
        }
    }

    private var sourceRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                sourceButton("ALL // \(store.articles.count)", id: nil)
                ForEach(store.sources) { source in
                    sourceButton(source.title.uppercased(), id: source.id)
                }
            }
        }
    }

    private func sourceButton(_ title: String, id: UUID?) -> some View {
        Button(title) { selectedSourceID = id }
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minHeight: 38)
            .buttonStyle(AcidButtonStyle(active: selectedSourceID == id))
    }

    @ViewBuilder private var statusLine: some View {
        if let message = store.refreshMessage {
            Text("// \(message)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.7)
                .foregroundStyle(message.contains("FAILED") ? TPPlayTheme.danger : TPPlayTheme.secondaryText)
        }
    }

    @ViewBuilder private var content: some View {
        if store.sources.isEmpty {
            NewsEmptyState(
                title: "NO SIGNAL SOURCES",
                message: "ADD AN RSS, ATOM OR JSON FEED TO BEGIN.",
                actionTitle: "ADD SOURCE >",
                action: { showingSources = true }
            )
        } else if visibleArticles.isEmpty && store.isRefreshing {
            NewsEmptyState(title: "SCANNING SOURCES", message: "WAITING FOR THE FIRST TRANSMISSION.", actionTitle: nil, action: nil)
        } else if visibleArticles.isEmpty {
            NewsEmptyState(title: "NO ARTICLES RECEIVED", message: "REFRESH THIS CHANNEL OR CHECK THE SOURCE STATUS.", actionTitle: "MANAGE SOURCES >", action: { showingSources = true })
        } else {
            ForEach(visibleArticles) { article in
                NewsArticleCard(article: article) { openArticle = article }
            }
        }
    }
}

private struct NewsArticleCard: View {
    let article: FeedArticle
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                articleImage
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(article.sourceTitle.uppercased())
                            .foregroundStyle(TPPlayTheme.accent)
                            .lineLimit(1)
                        Spacer(minLength: 12)
                        Text(timestamp)
                            .foregroundStyle(TPPlayTheme.tertiaryText)
                    }
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(0.7)

                    Text(article.title)
                        .font(.system(size: 17, weight: .black, design: .monospaced))
                        .foregroundStyle(TPPlayTheme.primaryText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if !article.summary.isEmpty {
                        Text(article.summary)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(TPPlayTheme.secondaryText)
                            .lineSpacing(3)
                            .lineLimit(4)
                            .multilineTextAlignment(.leading)
                    }

                    HStack {
                        Text("OPEN SOURCE")
                        Spacer()
                        Text(">")
                    }
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(0.7)
                    .foregroundStyle(TPPlayTheme.accent)
                    .padding(.top, 4)
                }
                .padding(14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TPPlayTheme.surface)
            .overlay { Rectangle().stroke(TPPlayTheme.violet, lineWidth: 1) }
        }
        .buttonStyle(NewsPressStyle())
        .accessibilityHint("Opens the article inside TP Play")
    }

    @ViewBuilder private var articleImage: some View {
        if let imageURL = article.imageURL {
            AsyncImage(url: imageURL) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 136)
                        .clipped()
                        .overlay(alignment: .bottom) { Rectangle().fill(TPPlayTheme.violet).frame(height: 1) }
                }
            }
        }
    }

    private var timestamp: String {
        guard let date = article.publishedAt else { return "NO TIMESTAMP" }
        if abs(date.timeIntervalSinceNow) < 604_800 {
            return date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)).uppercased()
        }
        return date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)).uppercased()
    }
}

private struct ArticleBrowserView: View {
    let article: FeedArticle
    let onClose: () -> Void
    @Environment(\.openURL) private var openURL
    @StateObject private var browser: ArticleBrowserModel

    init(article: FeedArticle, onClose: @escaping () -> Void) {
        self.article = article
        self.onClose = onClose
        _browser = StateObject(wrappedValue: ArticleBrowserModel(url: article.link))
    }

    var body: some View {
        VStack(spacing: 0) {
            browserToolbar

            ZStack {
                ArticleWebView(model: browser)

                if let errorMessage = browser.errorMessage {
                    VStack(spacing: 14) {
                        Text("SOURCE UNREACHABLE")
                            .font(.system(size: 15, weight: .black, design: .monospaced))
                            .foregroundStyle(TPPlayTheme.primaryText)
                        Text(errorMessage.uppercased())
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(TPPlayTheme.secondaryText)
                            .multilineTextAlignment(.center)
                        Button("RETRY >") { browser.reload() }
                            .frame(width: 132, height: 42)
                            .buttonStyle(AcidButtonStyle(active: true))
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(TPPlayTheme.canvas)
                    .overlay { Rectangle().stroke(TPPlayTheme.violet, lineWidth: 1) }
                    .padding(20)
                }
            }
            .overlay(alignment: .leading) {
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: 24)
                    .gesture(edgeBackGesture)
                    .accessibilityHidden(true)
            }
        }
        .padding(.top, windowTopSafeAreaInset)
        .background(TPPlayTheme.canvas)
        .ignoresSafeArea(edges: .top)
    }

    private var windowTopSafeAreaInset: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let foregroundScene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        let statusBarHeight = foregroundScene?.statusBarManager?.statusBarFrame.height ?? 0
        let windowInset = foregroundScene?.windows.map(\.safeAreaInsets.top).max() ?? 0
        return max(max(statusBarHeight, windowInset), 44)
    }

    private var browserToolbar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                toolbarButton(label: "NEWS", symbol: "chevron.left", fill: .accent, action: onClose)

                VStack(alignment: .leading, spacing: 2) {
                    Text(browser.isLoading ? "LOADING SOURCE" : "SOURCE ONLINE")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(browser.errorMessage == nil ? TPPlayTheme.accent : TPPlayTheme.danger)
                    Text((browser.currentURL ?? article.link).host?.uppercased() ?? "EXTERNAL SOURCE")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(TPPlayTheme.secondaryText)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

                toolbarButton(label: "EXT", symbol: "arrow.up.right", fill: .violet) {
                    openURL(browser.currentURL ?? article.link)
                }
                .accessibilityLabel("Open in external browser")
            }
            .frame(height: 48)
            .background(TPPlayTheme.canvas)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(TPPlayTheme.violet.opacity(0.35))
                    Rectangle()
                        .fill(TPPlayTheme.accent)
                        .frame(width: geometry.size.width * browser.visibleProgress)
                }
            }
            .frame(height: 2)
            .opacity(browser.isLoading ? 1 : 0)
        }
        .background(TPPlayTheme.canvas)
    }

    private func toolbarButton(
        label: String,
        symbol: String,
        fill: BrowserToolbarFill,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .black))
                Text(label)
                    .font(.system(size: 8, weight: .black, design: .monospaced))
            }
            .frame(width: 60, height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(BrowserToolbarButtonStyle(fill: fill))
    }

    private var edgeBackGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onEnded { value in
                guard value.translation.width > 48,
                      abs(value.translation.height) < value.translation.width else { return }
                if browser.canGoBack {
                    browser.goBack()
                } else {
                    onClose()
                }
            }
    }
}

private enum BrowserToolbarFill {
    case accent
    case violet
}

private struct BrowserToolbarButtonStyle: ButtonStyle {
    let fill: BrowserToolbarFill

    private var background: Color {
        fill == .accent ? TPPlayTheme.accent : TPPlayTheme.violet
    }

    private var foreground: Color {
        fill == .accent ? TPPlayTheme.onAccent : TPPlayTheme.primaryText
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foreground)
            .background(background)
            .overlay { Rectangle().stroke(background, lineWidth: 1) }
            .opacity(configuration.isPressed ? 0.62 : 1)
    }
}

private struct ArticleWebView: UIViewRepresentable {
    @ObservedObject var model: ArticleBrowserModel

    func makeUIView(context: Context) -> WKWebView { model.webView }
    func updateUIView(_ webView: WKWebView, context: Context) {}
}

@MainActor
private final class ArticleBrowserModel: NSObject, ObservableObject, WKNavigationDelegate {
    @Published private(set) var currentURL: URL?
    @Published private(set) var estimatedProgress = 0.0
    @Published private(set) var isLoading = true
    @Published private(set) var errorMessage: String?

    let webView: WKWebView
    private let initialURL: URL
    private var progressObservation: NSKeyValueObservation?

    var visibleProgress: Double {
        min(max(estimatedProgress, 0.04), 1)
    }

    var canGoBack: Bool { webView.canGoBack }

    init(url: URL) {
        initialURL = url
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        currentURL = url
        super.init()

        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        progressObservation = webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] webView, _ in
            Task { @MainActor in self?.estimatedProgress = webView.estimatedProgress }
        }
        load(url)
    }

    func reload() {
        errorMessage = nil
        if webView.url == nil {
            load(currentURL ?? initialURL)
        } else {
            webView.reload()
        }
    }

    func goBack() {
        guard webView.canGoBack else { return }
        webView.goBack()
    }

    private func load(_ url: URL) {
        webView.load(URLRequest(url: url, timeoutInterval: 30))
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        errorMessage = nil
        currentURL = webView.url ?? currentURL
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        estimatedProgress = 1
        currentURL = webView.url ?? currentURL
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        show(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        show(error)
    }

    private func show(_ error: Error) {
        isLoading = false
        errorMessage = error.localizedDescription
    }
}

private struct NewsEmptyState: View {
    let title: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 30, weight: .black))
                .foregroundStyle(TPPlayTheme.violet)
            Text(title)
                .font(.system(size: 16, weight: .black, design: .monospaced))
                .foregroundStyle(TPPlayTheme.primaryText)
            Text(message)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(TPPlayTheme.secondaryText)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
                    .buttonStyle(AcidButtonStyle(active: true))
            } else {
                ProgressView().tint(TPPlayTheme.accent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 36)
        .background(TPPlayTheme.surface)
        .overlay { Rectangle().stroke(TPPlayTheme.border, lineWidth: 1) }
    }
}

private struct NewsPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private struct FeedSourcesView: View {
    @ObservedObject var store: NewsStore
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var isAdding = false
    @State private var addError: String?
    @State private var pendingRemovalID: UUID?

    private var visibleSyncEvents: [FeedSyncEvent] {
        Array(store.syncEvents.prefix(12))
    }

    var body: some View {
        ZStack {
            TPPlayTheme.canvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text("NEWS // SOURCES")
                            .font(.system(size: 13, weight: .black, design: .monospaced))
                            .tracking(1)
                            .foregroundStyle(TPPlayTheme.accent)
                        Spacer()
                        Button("X") { dismiss() }
                            .frame(width: 42, height: 42)
                            .buttonStyle(AcidButtonStyle())
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("CONNECT RSS // ATOM // JSON FEED")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .tracking(0.7)
                            .foregroundStyle(TPPlayTheme.secondaryText)
                        TextField("HTTPS://EXAMPLE.COM/FEED", text: $address)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textFieldStyle(AcidFieldStyle())
                            .submitLabel(.go)
                            .onSubmit { addSource() }
                        Button { addSource() } label: {
                            HStack {
                                if isAdding { ProgressView().tint(TPPlayTheme.onAccent) }
                                Text(isAdding ? "VALIDATING SOURCE..." : "CONNECT SOURCE >")
                            }
                            .frame(maxWidth: .infinity, minHeight: 46)
                        }
                        .buttonStyle(AcidButtonStyle(active: true))
                        .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAdding)
                        if let addError {
                            Text("ERROR // \(addError)")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(TPPlayTheme.danger)
                        }
                    }
                    .padding(14)
                    .background(TPPlayTheme.surface)
                    .overlay { Rectangle().stroke(TPPlayTheme.violet, lineWidth: 1) }

                    HStack {
                        Text("// CONNECTED SOURCES")
                        Spacer()
                        Text("\(store.sources.count)")
                    }
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(TPPlayTheme.accent)

                    if store.sources.isEmpty {
                        Text("NO SOURCES SAVED ON THIS DEVICE.")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(TPPlayTheme.secondaryText)
                            .frame(maxWidth: .infinity, minHeight: 96)
                            .overlay { Rectangle().stroke(TPPlayTheme.border, lineWidth: 1) }
                    } else {
                        ForEach(store.sources) { source in sourceRow(source) }
                    }

                    if !store.syncEvents.isEmpty {
                        HStack {
                            Text("// SYNC LOG")
                            Spacer()
                            Text("LAST \(min(store.syncEvents.count, 12))")
                        }
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(TPPlayTheme.accent)

                        VStack(spacing: 0) {
                            ForEach(visibleSyncEvents) { event in
                                syncEventRow(event)
                                if event.id != visibleSyncEvents.last?.id {
                                    Rectangle().fill(TPPlayTheme.border).frame(height: 1)
                                }
                            }
                        }
                        .background(TPPlayTheme.surface)
                        .overlay { Rectangle().stroke(TPPlayTheme.border, lineWidth: 1) }
                    }
                }
                .padding(20)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func syncEventRow(_ event: FeedSyncEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(event.succeeded ? TPPlayTheme.accent : TPPlayTheme.danger)
                .frame(width: 7, height: 7)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(event.sourceTitle.uppercased())
                        .foregroundStyle(TPPlayTheme.primaryText)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(event.date.formatted(date: .omitted, time: .shortened).uppercased())
                        .foregroundStyle(TPPlayTheme.tertiaryText)
                }
                Text(event.message)
                    .foregroundStyle(event.succeeded ? TPPlayTheme.secondaryText : TPPlayTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 8, weight: .bold, design: .monospaced))
        }
        .padding(12)
    }

    private func sourceRow(_ source: FeedSource) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(source.title.uppercased())
                        .font(.system(size: 12, weight: .black, design: .monospaced))
                        .foregroundStyle(TPPlayTheme.primaryText)
                    Text(source.url.absoluteString)
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(TPPlayTheme.secondaryText)
                        .lineLimit(2)
                    if let error = source.lastError {
                        Text("LAST ERROR // \(error)")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(TPPlayTheme.danger)
                    }
                }
                Spacer()
                Rectangle()
                    .fill(source.lastError == nil ? TPPlayTheme.accent : TPPlayTheme.danger)
                    .frame(width: 7, height: 7)
                    .padding(.top, 4)
            }

            if pendingRemovalID == source.id {
                HStack(spacing: 8) {
                    Button("CANCEL") { pendingRemovalID = nil }
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .buttonStyle(AcidButtonStyle())
                    Button("REMOVE") {
                        store.removeSource(source)
                        pendingRemovalID = nil
                    }
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .buttonStyle(AcidButtonStyle(active: true))
                }
            } else {
                Button("DISCONNECT SOURCE") { pendingRemovalID = source.id }
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .buttonStyle(AcidButtonStyle())
            }
        }
        .padding(14)
        .background(TPPlayTheme.surface)
        .overlay { Rectangle().stroke(TPPlayTheme.border, lineWidth: 1) }
    }

    private func addSource() {
        guard !isAdding else { return }
        isAdding = true
        addError = nil
        Task {
            do {
                try await store.addSource(address: address)
                address = ""
            } catch {
                addError = error.localizedDescription.uppercased()
            }
            isAdding = false
        }
    }
}

#Preview { NewsView() }
