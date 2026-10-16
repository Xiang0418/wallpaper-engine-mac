import Foundation
import WebKit
import Combine

struct WorkshopItem: Identifiable, Codable {
    let id: String
    let title: String
    let previewURL: String?
    let tags: [String]
    let subscriptions: Int
    let fileSize: Int
    let creatorAppId: Int?
    let description: String?

    var previewImageURL: URL? {
        guard let urlString = previewURL else { return nil }
        return URL(string: urlString)
    }
}

enum WorkshopSortOrder: Int, CaseIterable, Identifiable {
    case trending = 0
    case mostRecent = 1
    case mostPopular = 2
    case mostSubscribed = 3

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .trending: return "Trending"
        case .mostRecent: return "Most Recent"
        case .mostPopular: return "Most Popular"
        case .mostSubscribed: return "Most Subscribed"
        }
    }

    var queryType: Int {
        switch self {
        case .trending: return 3      // RankedByTrend
        case .mostRecent: return 1     // RankedByPublicationDate
        case .mostPopular: return 0    // RankedByVote
        case .mostSubscribed: return 9 // RankedByTotalUniqueSubscriptions
        }
    }

    /// When search_text is provided, Steam requires query_type=12 (RankedByTextSearch)
    func queryTypeForSearch(hasText: Bool) -> Int {
        hasText ? 12 : queryType
    }
}

class WorkshopAPIService {
    static let wallpaperEngineAppId = 431960

    /// Search workshop items using the public Steam API.
    /// GetPublishedFileDetails doesn't require an API key for basic queries.
    func searchItems(
        query: String = "",
        tags: [String] = [],
        excludedTags: [String] = [],
        sortOrder: WorkshopSortOrder = .trending,
        page: Int = 1,
        perPage: Int = 20
    ) async throws -> [WorkshopItem] {
        let url = try Self.searchURL(query: query, tags: tags, excludedTags: excludedTags,
                                     sortOrder: sortOrder, page: page, perPage: perPage, apiKey: Self.loadAPIKey())

        let started = ProcessInfo.processInfo.systemUptime
        defer { NSLog("[WorkshopPerformance] search seconds=%.3f", ProcessInfo.processInfo.systemUptime - started) }
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WorkshopAPIError.requestFailed
        }

        if httpResponse.statusCode == 403 {
            throw WorkshopAPIError.invalidAPIKey
        }

        guard httpResponse.statusCode == 200 else {
            throw WorkshopAPIError.httpError(httpResponse.statusCode)
        }

        return try parseQueryResponse(data)
    }

    static func searchURL(query: String, tags: [String], excludedTags: [String], sortOrder: WorkshopSortOrder,
                          page: Int, perPage: Int, apiKey: String) throws -> URL {
        // Use ISteamRemoteStorage/GetPublishedFileDetails for specific IDs
        // Use the public search endpoint for browsing
        var components = URLComponents(string: "https://api.steampowered.com/IPublishedFileService/QueryFiles/v1/")!

        let hasSearchText = !query.isEmpty
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "query_type", value: "\(sortOrder.queryTypeForSearch(hasText: hasSearchText))"),
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "numperpage", value: "\(perPage)"),
            URLQueryItem(name: "appid", value: "\(Self.wallpaperEngineAppId)"),
            URLQueryItem(name: "return_tags", value: "true"),
            URLQueryItem(name: "return_previews", value: "true"),
            URLQueryItem(name: "return_metadata", value: "true"),
            URLQueryItem(name: "return_short_description", value: "true"),
        ]

        if !query.isEmpty {
            queryItems.append(URLQueryItem(name: "search_text", value: query))
        }

        for (index, tag) in tags.enumerated() {
            queryItems.append(URLQueryItem(name: "requiredtags[\(index)]", value: tag))
        }

        guard !apiKey.isEmpty else {
            throw WorkshopAPIError.noAPIKey
        }
        queryItems.append(URLQueryItem(name: "key", value: apiKey))

        queryItems.append(URLQueryItem(name: "match_all_tags", value: "true"))
        for (index, tag) in excludedTags.enumerated() {
            queryItems.append(URLQueryItem(name: "excludedtags[\(index)]", value: tag))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw WorkshopAPIError.invalidURL
        }

        return url
    }

    /// Get details for specific workshop items by their IDs.
    func getItemDetails(workshopIds: [String]) async throws -> [WorkshopItem] {
        let url = URL(string: "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        var bodyParts = ["itemcount=\(workshopIds.count)"]
        for (index, id) in workshopIds.enumerated() {
            bodyParts.append("publishedfileids[\(index)]=\(id)")
        }
        request.httpBody = bodyParts.joined(separator: "&").data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw WorkshopAPIError.requestFailed
        }

        return try parseFileDetailsResponse(data)
    }

    // MARK: - API Key

    private static let apiKeyDefault = "SteamWebAPIKey"

    static func loadAPIKey() -> String {
        UserDefaults.standard.string(forKey: apiKeyDefault) ?? ""
    }

    static func saveAPIKey(_ key: String) {
        UserDefaults.standard.set(key, forKey: apiKeyDefault)
    }

    // MARK: - Response Parsing

    private func parseQueryResponse(_ data: Data) throws -> [WorkshopItem] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = json["response"] as? [String: Any],
              let files = response["publishedfiledetails"] as? [[String: Any]]
        else {
            return []
        }

        return files.compactMap { parseFileDict($0) }
    }

    private func parseFileDetailsResponse(_ data: Data) throws -> [WorkshopItem] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = json["response"] as? [String: Any],
              let files = response["publishedfiledetails"] as? [[String: Any]]
        else {
            return []
        }

        return files.compactMap { parseFileDict($0) }
    }

    private func parseFileDict(_ dict: [String: Any]) -> WorkshopItem? {
        guard let publishedFileId = dict["publishedfileid"] as? String,
              let title = dict["title"] as? String
        else { return nil }

        let previewURL = dict["preview_url"] as? String
        let tags: [String] = (dict["tags"] as? [[String: Any]])?.compactMap { $0["tag"] as? String } ?? []
        let subscriptions = dict["subscriptions"] as? Int ?? dict["lifetime_subscriptions"] as? Int ?? 0
        let fileSize = dict["file_size"] as? Int ?? 0
        let creatorAppId = dict["creator_app_id"] as? Int
        let description = dict["short_description"] as? String ?? dict["description"] as? String

        return WorkshopItem(
            id: publishedFileId,
            title: title,
            previewURL: previewURL,
            tags: tags,
            subscriptions: subscriptions,
            fileSize: fileSize,
            creatorAppId: creatorAppId,
            description: description
        )
    }
}

enum WorkshopAPIError: LocalizedError {
    case invalidURL
    case requestFailed
    case noAPIKey
    case invalidAPIKey
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid API URL"
        case .requestFailed: return "API request failed — check your network connection"
        case .noAPIKey: return "Steam Web API key required.\nGet a free key at steamcommunity.com/dev/apikey\nthen enter it below."
        case .invalidAPIKey: return "Invalid API key.\nGet a valid key at steamcommunity.com/dev/apikey"
        case .httpError(let code): return "Steam API returned HTTP \(code)"
        }
    }
}

// MARK: - Authenticated Steam community subscriptions

/// The web login and native Subscribe buttons share one cookie store. Cookies
/// stay in WebKit and in a single ephemeral request; they are never logged.
@MainActor
enum SteamCommunitySession {
    static let store: WKWebsiteDataStore = {
        if #available(macOS 14.0, *) {
            return WKWebsiteDataStore(forIdentifier: UUID(uuidString: "3B7D2827-FC97-4F2D-90C2-773535C56A85")!)
        }
        return .default()
    }()
}

enum SteamSubscriptionError: LocalizedError {
    case signInRequired, invalidItem, invalidResponse, rejected(Int)
    var errorDescription: String? {
        switch self {
        case .signInRequired: return String(localized: "Sign in to Steam Community, then press Subscribe again.")
        case .invalidItem: return String(localized: "This item is not an available Wallpaper Engine wallpaper.")
        case .invalidResponse: return String(localized: "Steam did not confirm the subscription. Please try again.")
        case .rejected(let code):
            if code == 15 { return String(localized: "Steam denied permission to subscribe to this item.") }
            if code == 25 { return String(localized: "Your Steam subscription limit has been reached.") }
            return String(localized: "Steam could not subscribe to this item.") + " (\(code))"
        }
    }
}

struct SteamSubscriptionRequest {
    static func communityCookies(_ cookies: [HTTPCookie], now: Date = Date()) -> [HTTPCookie] {
        cookies.filter {
            ["steamcommunity.com", ".steamcommunity.com"].contains($0.domain.lowercased()) &&
            ($0.expiresDate == nil || $0.expiresDate! > now) &&
            ($0.path == "/" || $0.path == "/sharedfiles/subscribe" || "/sharedfiles/subscribe".hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/"))
        }
    }

    static func make(id: String, cookies: [HTTPCookie]) throws -> URLRequest {
        guard !id.isEmpty, id.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = UInt64(id), number > 0 else { throw SteamSubscriptionError.invalidItem }
        let cookies = communityCookies(cookies)
        guard cookies.contains(where: { $0.name == "steamLoginSecure" && !$0.value.isEmpty }),
              let csrf = cookies.first(where: { $0.name == "sessionid" && !$0.value.isEmpty }) else {
            throw SteamSubscriptionError.signInRequired
        }
        var request = URLRequest(url: URL(string: "https://steamcommunity.com/sharedfiles/subscribe")!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("https://steamcommunity.com", forHTTPHeaderField: "Origin")
        request.setValue("https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)", forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) { request.setValue(value, forHTTPHeaderField: name) }
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "appid", value: "431960"),
                           URLQueryItem(name: "sessionid", value: csrf.value), URLQueryItem(name: "include_dependencies", value: "false")]
        request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        return request
    }

    static func validate(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw SteamSubscriptionError.invalidResponse }
        if [301, 302, 303, 307, 308, 401, 403].contains(http.statusCode) { throw SteamSubscriptionError.signInRequired }
        struct Result: Decodable { let success: Int }
        guard http.statusCode == 200,
              let result = try? JSONDecoder().decode(Result.self, from: data).success else {
            throw SteamSubscriptionError.invalidResponse
        }
        if result == 21 { throw SteamSubscriptionError.signInRequired }
        guard result == 1 else { throw SteamSubscriptionError.rejected(result) }
    }
}

private final class SteamSubscriptionRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward account cookies through a redirect or interpret login HTML as success.
        completionHandler(nil)
    }
}

@MainActor
final class SteamSubscriptionService: NSObject, ObservableObject, WKHTTPCookieStoreObserver {
    static let shared = SteamSubscriptionService()
    enum State: Equatable { case subscribing, subscribed, signInRequired, failed(String) }
    @Published private(set) var states: [String: State] = [:]
    private var accountCookie: String?
    private let cookieStore = SteamCommunitySession.store.httpCookieStore

    override init() {
        super.init()
        cookieStore.add(self)
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { await refreshAccount() }
    }

    @discardableResult private func refreshAccount() async -> [HTTPCookie] {
        let cookies = SteamSubscriptionRequest.communityCookies(await cookieStore.allCookies())
        let account = cookies.first(where: { $0.name == "steamLoginSecure" })?.value
        if accountCookie != account {
            accountCookie = account
            states = [:]
        }
        return cookies
    }

    func subscribe(id: String) async {
        guard states[id] != .subscribing else { return }
        let cookies = await refreshAccount()
        guard states[id] != .subscribing else { return }
        let account = accountCookie
        states[id] = .subscribing
        do {
            let request = try SteamSubscriptionRequest.make(id: id, cookies: cookies)
            let details = try await WorkshopAPIService().getItemDetails(workshopIds: [id])
            guard details.contains(where: { $0.id == id && $0.creatorAppId == WorkshopAPIService.wallpaperEngineAppId }) else {
                throw SteamSubscriptionError.invalidItem
            }
            // Recheck before writing if a sign-out/account switch happened while loading details.
            await refreshAccount()
            guard accountCookie == account else { return }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            let session = URLSession(configuration: configuration, delegate: SteamSubscriptionRedirectGuard(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(for: request)
            try SteamSubscriptionRequest.validate(data: data, response: response)
            await refreshAccount()
            guard accountCookie == account else { return }
            states[id] = .subscribed
        } catch {
            await refreshAccount()
            guard accountCookie == account else { return }
            if case SteamSubscriptionError.signInRequired = error { states[id] = .signInRequired }
            else { states[id] = .failed(error.localizedDescription) }
        }
    }
}
