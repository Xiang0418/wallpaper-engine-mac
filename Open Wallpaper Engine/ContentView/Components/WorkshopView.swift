import SwiftUI
import ImageIO
import WebKit

struct WorkshopView: SubviewOfContentView {
    @ObservedObject var viewModel: ContentViewModel

    init(contentViewModel viewModel: ContentViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        VStack(spacing: 0) {
            if !viewModel.steamCmd.isInstalled {
                SteamCmdNotInstalledView(steamCmd: viewModel.steamCmd)
            } else if !viewModel.steamCmd.isLoggedIn {
                SteamLoginView(steamCmd: viewModel.steamCmd)
            } else {
                WorkshopBrowserView(viewModel: viewModel.workshopVM)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Steam Community (official account and subscription UI)

/// These URLs always use the account signed into the community web view, never
/// the potentially different SteamCMD download account.
private enum SteamCommunityNavigation {
    static let discover = URL(string: "https://steamcommunity.com/workshop/browse/?appid=431960")!
    static let subscriptions = URL(string: "https://steamcommunity.com/my/myworkshopfiles/?appid=431960&browsefilter=mysubscriptions")!

    static func isSteamURL(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return ["steamcommunity.com", "steampowered.com"].contains {
            host == $0 || host.hasSuffix("." + $0)
        }
    }

    static func workshopID(_ url: URL?) -> String? {
        guard let url, url.scheme == "https", url.host == "steamcommunity.com",
              ["/sharedfiles/filedetails", "/sharedfiles/filedetails/", "/workshop/filedetails", "/workshop/filedetails/"].contains(url.path),
              let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value,
              !id.isEmpty, id.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = UInt64(id), number > 0 else { return nil }
        return id
    }
}

@MainActor
private final class SteamCommunityBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    @Published var currentURL: URL?
    @Published var loading = false
    @Published var canGoBack = false
    @Published var error: String?
    private var observations: [NSKeyValueObservation] = []

    init(url: URL) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = SteamCommunitySession.store
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.currentURL = self.webView.url
                }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.loading = self.webView.isLoading
                }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.canGoBack = self.webView.canGoBack
                }
            }
        ]
        open(url)
    }

    func open(_ url: URL) {
        error = nil
        webView.load(URLRequest(url: url))
    }

    func reload() {
        error = nil
        if let url = currentURL { open(url) } else { open(SteamCommunityNavigation.discover) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if SteamCommunityNavigation.isSteamURL(url) {
            decisionHandler(.allow)
        } else {
            // User-clicked external links leave the authenticated browser.
            if action.navigationType == .linkActivated, ["https", "http"].contains(url.scheme ?? "") {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, let url = action.request.url {
            if SteamCommunityNavigation.isSteamURL(url) { open(url) }
            else if action.navigationType == .linkActivated, ["https", "http"].contains(url.scheme ?? "") {
                NSWorkspace.shared.open(url)
            }
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        error = String(localized: "Steam page stopped responding. Reload to continue.")
    }
    private func report(_ failure: Error) {
        guard (failure as NSError).code != NSURLErrorCancelled else { return }
        error = failure.localizedDescription
    }
}

private struct SteamCommunityWebView: NSViewRepresentable {
    let browser: SteamCommunityBrowser
    func makeNSView(context: Context) -> WKWebView { browser.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

private struct SteamSubscriptionLoginView: View {
    @StateObject private var browser: SteamCommunityBrowser

    init(initialURL: URL) {
        _browser = StateObject(wrappedValue: SteamCommunityBrowser(url: initialURL))
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Label(browser.currentURL?.host ?? "steamcommunity.com", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary)
                if browser.loading { ProgressView().controlSize(.small) }
                Spacer()
                Button("Reload") { browser.reload() }
            }.padding(.horizontal)
            Text("Sign in to Steam Community, then press Subscribe again.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            if let error = browser.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .padding(.horizontal)
            }
            SteamCommunityWebView(browser: browser)
        }
    }
}

// MARK: - steamcmd Not Installed

private struct SteamCmdNotInstalledView: View {
    @ObservedObject var steamCmd: SteamCmdService
    @State private var isCopied = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("steamcmd Not Found")
                .font(.title2)
                .bold()

            Text("Steam Workshop requires steamcmd to download wallpapers.\nInstall it with Homebrew:")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            HStack {
                Text("brew install steamcmd")
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install steamcmd", forType: .string)
                    isCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { isCopied = false }
                } label: {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
            }

            Divider().frame(width: 200)

            Text("Or locate an existing steamcmd binary:")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button("Browse...") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                panel.message = "Select the steamcmd executable"
                if panel.runModal() == .OK, let url = panel.url {
                    steamCmd.setCustomPath(url.path)
                }
            }
            .buttonStyle(.bordered)

            if let error = steamCmd.pathError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button("Re-detect") {
                steamCmd.detectSteamCmd()
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(40)
    }
}

// MARK: - Steam Login

private struct SteamLoginView: View {
    var showsAPIKey = true
    @ObservedObject var steamCmd: SteamCmdService
    @State private var username = ""
    @State private var password = ""
    @State private var guardCode = ""
    @State private var showGuardCode = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.badge.key")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("Steam Login")
                .font(.title2)
                .bold()

            Text("Log in with your Steam account to browse and download wallpapers.\nYou must own Wallpaper Engine on Steam.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .font(.callout)

            VStack(spacing: 10) {
                TextField("Steam Username", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)

                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)

                if showGuardCode {
                    TextField("Steam Guard Code", text: $guardCode)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }

                if let error = steamCmd.loginError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)

                    if error.contains("Steam Guard") && !showGuardCode {
                        Button("Enter Steam Guard Code") {
                            showGuardCode = true
                        }
                        .buttonStyle(.link)
                    }
                }

                HStack(spacing: 12) {
                    Button("Log In") {
                        steamCmd.login(
                            username: username,
                            password: password,
                            guardCode: showGuardCode ? guardCode : nil
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(username.isEmpty || password.isEmpty || steamCmd.isLoggingIn)

                    if !username.isEmpty {
                        Button("Use Cached Session") {
                            steamCmd.loginWithCachedSession(username: username)
                        }
                        .buttonStyle(.bordered)
                        .disabled(steamCmd.isLoggingIn)
                    }
                }

                if steamCmd.isLoggingIn {
                    ProgressView()
                        .controlSize(.small)
                    Text("Authenticating with Steam...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // API Key section
            if showsAPIKey {
                VStack(spacing: 6) {
                    Divider().padding(.vertical, 8)
                    Text("You'll also need a Steam Web API key to browse the Workshop.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    APIKeyInputView {}
                }
            }
        }
        .padding(40)
    }
}

// MARK: - Workshop Browser

private struct WorkshopBrowserView: View {
    @ObservedObject var viewModel: WorkshopViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            WorkshopFiltersView(viewModel: viewModel).frame(width: 240)
            Divider()
        VStack(spacing: 8) {

            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search wallpapers...", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        viewModel.currentPage = 1
                        Task { await viewModel.search() }
                    }
                if !viewModel.searchText.isEmpty {
                    Button {
                        viewModel.searchText = ""
                        viewModel.currentPage = 1
                        Task { await viewModel.search() }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Picker("Sort", selection: $viewModel.sortOrder) {
                    ForEach(WorkshopSortOrder.allCases) { order in
                        Text(order.displayName).tag(order)
                    }
                }
                .frame(width: 160)
                .onChange(of: viewModel.sortOrder) { _ in
                    viewModel.currentPage = 1
                    Task { await viewModel.search() }
                }
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            .padding(.horizontal)

            if let error = viewModel.errorMessage, !viewModel.items.isEmpty {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }
            // Results
            if viewModel.isLoading && viewModel.items.isEmpty {
                Spacer()
                ProgressView("Searching Workshop...")
                Spacer()
            } else if let error = viewModel.errorMessage, viewModel.items.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text(error)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    APIKeyInputView {
                        Task { await viewModel.search() }
                    }
                }
                Spacer()
            } else if viewModel.items.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No matching wallpapers")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("Try removing a filter or changing your search text.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)

                    if WorkshopAPIService.loadAPIKey().isEmpty {
                        Divider().frame(width: 300).padding(.vertical, 4)
                        Text("A Steam Web API key is required to browse.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        APIKeyInputView {
                            Task { await viewModel.search() }
                        }
                    }
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 300))], spacing: 12) {
                        ForEach(viewModel.items) { item in
                            WorkshopItemCard(item: item, viewModel: viewModel)
                        }
                    }
                    .padding()

                    if viewModel.hasMore {
                        Button("Load More") {
                            Task { await viewModel.loadMore() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.isLoading)
                        .padding(.bottom)
                    }
                }
            }
        }
        }
        .task {
            if viewModel.items.isEmpty {
                await viewModel.search()
            }
        }
    }

}

private struct WorkshopFiltersView: View {
    @ObservedObject var viewModel: WorkshopViewModel
    @State private var genresExpanded = true
    @State private var featuresExpanded = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("Filters", systemImage: "line.3.horizontal.decrease.circle").font(.headline)
                    Spacer()
                    Text("\(viewModel.filterCount)").monospacedDigit().foregroundStyle(.secondary)
                }
                HStack {
                    Button("Clear All") { viewModel.clearFilters(); refresh() }
                        .disabled(viewModel.filterCount == 0)
                    Button("Reset") { viewModel.resetFilters(); refresh() }
                }.controlSize(.small)
                Text("Results must include every selected tag. Excluded tags are hidden.")
                    .font(.caption).foregroundStyle(.secondary)
                selection("Age Rating", tags: WorkshopViewModel.contentRatingTags)
                selection("Wallpaper Type", tags: WorkshopViewModel.typeTags)
                selection("Category", tags: WorkshopViewModel.categoryTags)
                selection("Resolution", tags: WorkshopViewModel.resolutionTags)
                Divider()
                DisclosureGroup("Features", isExpanded: $featuresExpanded) {
                    tagRows(WorkshopViewModel.featureTags)
                }
                DisclosureGroup("Genre", isExpanded: $genresExpanded) {
                    tagRows(WorkshopViewModel.genreTags)
                }
            }
            .padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func selection(_ title: LocalizedStringKey, tags: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Picker(title, selection: Binding(
                get: { viewModel.selectedTags.first(where: { tags.contains($0) }) ?? "" },
                set: { value in
                    viewModel.selectedTags.removeAll { tags.contains($0) }
                    if !value.isEmpty { viewModel.toggleTag(value) }
                    refresh()
                })) {
                    Text("Any").tag("")
                    ForEach(tags, id: \.self) { Text(LocalizedStringKey($0)).tag($0) }
                }
                .labelsHidden()
        }
    }

    private func tagRows(_ tags: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                HStack(spacing: 6) {
                    let included = viewModel.selectedTags.contains(tag)
                    let excluded = viewModel.excludedTags.contains(tag)
                    Button { viewModel.toggleTag(tag); refresh() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: included ? "checkmark.square.fill" : "square")
                            Text(LocalizedStringKey(tag)).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(included ? Color.accentColor : Color.primary)
                    .accessibilityValue(included ? Text("Included") : Text("Not included"))
                    Button { viewModel.toggleExcludedTag(tag); refresh() } label: {
                        Image(systemName: excluded ? "minus.circle.fill" : "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(excluded ? Color.red : Color.secondary)
                    .help(Text("Exclude") + Text(": ") + Text(LocalizedStringKey(tag)))
                    .accessibilityLabel(Text("Exclude") + Text(": ") + Text(LocalizedStringKey(tag)))
                    .accessibilityValue(excluded ? Text("Excluded") : Text("Not excluded"))
                }
                .font(.callout)
                .padding(.vertical, 3)
            }
        }.padding(.top, 8)
    }

    private func refresh() { Task { await viewModel.search() } }
}

// MARK: - Workshop Item Card

private struct WorkshopItemCard: View {
    let item: WorkshopItem
    @ObservedObject private var subscriptions = SteamSubscriptionService.shared
    @State private var showsCommunity = false
    @State private var showsPreview = false
    @ObservedObject var viewModel: WorkshopViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Open the author-provided image without applying the wallpaper.
            Button { showsPreview = true } label: {
            WorkshopAnimatedThumbnail(url: item.previewImageURL)
            .frame(height: 120)
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .padding(7)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .padding(6)
                    .accessibilityHidden(true)
            }
            }
            .buttonStyle(.plain)
            .disabled(item.previewImageURL == nil)
            .accessibilityLabel(Text("Preview image"))
            .help(Text("Preview image"))
            .sheet(isPresented: $showsPreview) {
                WorkshopImagePreview(item: item)
            }


            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(2)

                HStack {
                    if !item.tags.isEmpty {
                        Text(item.tags.prefix(2).joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if item.subscriptions > 0 {
                        Label("\(formatCount(item.subscriptions))", systemImage: "heart")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                subscriptionButton
                    .sheet(isPresented: $showsCommunity) {
                        VStack {
                            HStack {
                                Text(item.title).font(.headline).lineLimit(1)
                                Spacer()
                                Button("Close") { showsCommunity = false }
                            }.padding()
                            SteamSubscriptionLoginView(initialURL: communityURL)
                        }.frame(minWidth: 900, minHeight: 650)
                    }
                // Download button
                downloadButton
            }
            .padding(8)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
    }

    private var communityURL: URL {
        let itemURL = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(item.id)")!
        guard subscriptions.states[item.id] == .signInRequired else { return itemURL }
        var login = URLComponents(string: "https://steamcommunity.com/login/home/")!
        login.queryItems = [URLQueryItem(name: "goto", value: itemURL.absoluteString)]
        return login.url!
    }

    @ViewBuilder
    private var subscriptionButton: some View {
        let state = subscriptions.states[item.id]
        Button {
            Task {
                await subscriptions.subscribe(id: item.id)
                if subscriptions.states[item.id] == .signInRequired { showsCommunity = true }
            }
        } label: {
            if state == .subscribing {
                HStack { ProgressView().controlSize(.mini); Text("Subscribing…") }
            } else {
                Label(state == .subscribed ? "Subscribed" : "Subscribe",
                      systemImage: state == .subscribed ? "checkmark.circle.fill" : "plus.circle")
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(state == .subscribing)
        if case .failed(let message) = state {
            Text(message).font(.caption2).foregroundStyle(.red)
        }
        if state == .signInRequired {
            Text("Sign in to Steam Community, then press Subscribe again.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var downloadButton: some View {
        let state = viewModel.downloadState(for: item)
        switch state {
        case .downloading(let status):
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        case .completed:
            Label("Downloaded", systemImage: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
        case .failed(let msg):
            VStack(alignment: .leading) {
                Label("Failed", systemImage: "xmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.red)
                Text(msg).font(.caption2).foregroundStyle(.secondary)
            }
        case .none:
            if viewModel.steamCmd.isLoggedIn {
                Button {
                    viewModel.download(item: item)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(viewModel.steamCmd.isDownloadingEngineAssets)
                .help(viewModel.steamCmd.isDownloadingEngineAssets ? String(localized: "Wait for the shared asset download to finish.") : "")
            } else {
                Text("Login to download")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .aspectRatio(16/9, contentMode: .fill)
    }

    private func formatCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}

// MARK: - API Key Input

private struct APIKeyInputView: View {
    @State private var apiKey = WorkshopAPIService.loadAPIKey()
    var onSave: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Steam Web API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                    .onSubmit { save() }

                Button("Save & Search") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack(spacing: 4) {
                Text("Get a free key at")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Link("steamcommunity.com/dev/apikey", destination: URL(string: "https://steamcommunity.com/dev/apikey")!)
                    .font(.caption)
            }
        }
    }

    private func save() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        WorkshopAPIService.saveAPIKey(trimmed)
        onSave()
    }
}


// Author-provided previews animate in visible cards and in the enlarged sheet.
private struct WorkshopImagePreview: View {
    let item: WorkshopItem
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: NSImage?
    @State private var animated = false
    @State private var playing = false
    @State private var failed = false
    @State private var attempt = 0

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(item.title).font(.headline).lineLimit(2)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if let image {
                    WorkshopPreviewImage(image: image, playing: animated && playing)
                        .accessibilityLabel(Text(item.title))
                } else if failed {
                    VStack(spacing: 12) {
                        Text("Preview could not be loaded.")
                        Button("Retry") { attempt += 1 }
                    }
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            HStack {
                Text(animated ? "Author’s animated preview" : "Author’s preview image")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if animated {
                    Button { playing.toggle() } label: {
                        Label(playing ? "Pause preview" : "Play preview", systemImage: playing ? "pause.fill" : "play.fill")
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 720, height: 520)
        .task(id: attempt) { await load() }
        .onChange(of: reduceMotion) { reduced in if reduced { playing = false } }
        .onDisappear { playing = false; image = nil }
    }

    @MainActor private func load() async {
        image = nil; failed = false; animated = false; playing = false
        do {
            guard let url = item.previewImageURL else { throw URLError(.badURL) }
            let data = try await WorkshopPreviewLoader.fetch(url)
            try Task.checkCancellation()
            let (decoded, isAnimated) = try WorkshopPreviewLoader.decode(data)
            animated = isAnimated
            image = decoded; playing = animated && !reduceMotion
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }
}

private enum WorkshopPreviewLoader {
    @MainActor static func decode(_ data: Data) throws -> (NSImage, Bool) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 8192, height <= 8192 else { throw URLError(.cannotDecodeContentData) }
            let frames = CGImageSourceGetCount(source)
            guard frames > 0, frames <= 500, Double(width)*Double(height)*Double(frames)*4 <= 128*1024*1024,
                  let decoded = NSImage(data: data) else { throw URLError(.dataLengthExceedsMaximum) }
            // NSImageView supplies GIF timing/disposal; do not replace its image on pause.
            let gif = CGImageSourceGetType(source) as String? == "com.compuserve.gif"
            let animated = gif && frames > 1
            if animated {
                (decoded.representations.first as? NSBitmapImageRep)?.setProperty(.loopCount, withValue: 0)
            }
        return (decoded, animated)
    }

    static func fetch(_ url: URL) async throws -> Data {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { throw URLError(.unsupportedURL) }
        let limit = 16 * 1024 * 1024
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 30)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              response.expectedContentLength <= limit else { throw URLError(.badServerResponse) }
        var data = Data(); data.reserveCapacity(256 * 1024)
        for try await byte in bytes {
            if data.count % 16384 == 0 { try Task.checkCancellation() }
            guard data.count < limit else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return data
    }
}

private struct WorkshopPreviewImage: NSViewRepresentable {
    let image: NSImage
    let playing: Bool
    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }
    func updateNSView(_ view: NSImageView, context: Context) {
        if view.image !== image { view.image = image }
        view.animates = playing
    }
    static func dismantleNSView(_ view: NSImageView, coordinator: ()) {
        view.animates = false; view.image = nil
    }
}


private struct WorkshopAnimatedThumbnail: View {
    let url: URL?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: NSImage?
    @State private var animated = false
    @State private var visible = false
    @State private var failed = false
    var body: some View {
        ZStack {
            Color(nsColor: .quaternaryLabelColor)
            if let image {
                WorkshopPreviewImage(image: image, playing: animated && visible && !reduceMotion)
            } else if failed {
                Image(systemName: "photo").foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .task(id: url) {
            image = nil; failed = false; animated = false
            guard let url else { failed = true; return }
            do {
                let data = try await WorkshopPreviewLoader.fetch(url)
                try Task.checkCancellation()
                let decoded = try WorkshopPreviewLoader.decode(data)
                image = decoded.0; animated = decoded.1
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
}
