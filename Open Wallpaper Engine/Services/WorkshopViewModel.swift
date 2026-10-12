import Foundation
import SwiftUI
import Combine

@MainActor
class WorkshopViewModel: ObservableObject {
    @Published var items: [WorkshopItem] = []
    @Published var searchText = ""
    @Published var sortOrder: WorkshopSortOrder = .trending
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var currentPage = 1
    @Published var selectedTags: [String] = ["Everyone"]

    @Published var excludedTags: [String] = []
    @Published var hasMore = true
    private var requestGeneration = UUID()
    private var activeSearch: (text: String, tags: [String], excluded: [String], sort: WorkshopSortOrder)?

    let steamCmd: SteamCmdService
    private let api: WorkshopAPIService
    private var cancellable: AnyCancellable?

    static let contentRatingTags = ["Everyone", "Questionable", "Mature"]

    static let typeTags = ["Scene", "Video", "Web", "Application"]

    static let genreTags = [
        "Abstract", "Animal", "Anime", "Cartoon", "CGI",
        "Cyberpunk", "Fantasy", "Game", "Girls", "Guys",
        "Landscape", "Medieval", "Memes", "MMD", "Music",
        "Nature", "Pixel art", "Relaxing", "Retro", "Sci-Fi",
        "Sports", "Technology", "Television", "Vehicle", "Unspecified",
    ]

    static let resolutionTags = [
        "Standard Definition", "1280 x 720", "1366 x 768", "1920 x 1080", "2560 x 1440", "3840 x 2160",
        "Ultrawide Standard Definition", "Ultrawide 2560 x 1080", "Ultrawide 3440 x 1440",
        "Dual Standard Definition", "Dual 3840 x 1080", "Dual 5120 x 1440", "Dual 7680 x 2160",
        "Triple Standard Definition", "Triple 4096 x 768", "Triple 5760 x 1080", "Triple 7680 x 1440", "Triple 11520 x 2160",
        "Portrait Standard Definition", "Portrait 720 x 1280", "Portrait 1080 x 1920", "Portrait 1440 x 2560", "Portrait 2160 x 3840",
        "Other resolution", "Dynamic resolution",
    ]
    static let featureTags = ["Approved", "Audio responsive", "3D", "Customizable", "Puppet Warp", "HDR",
                              "Media Integration", "User Shortcut", "Video Texture", "Asset Pack"]
    static let categoryTags = ["Wallpaper", "Preset", "Asset"]
    static let exclusiveGroups = [contentRatingTags, typeTags, resolutionTags, categoryTags]

    var filterCount: Int { selectedTags.count + excludedTags.count }

    init(steamCmd: SteamCmdService, api: WorkshopAPIService = WorkshopAPIService()) {
        self.api = api
        self.steamCmd = steamCmd
        // Forward steamCmd changes (e.g. downloadProgress) to trigger view updates
        self.cancellable = steamCmd.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func search() async {
        let generation = UUID()
        requestGeneration = generation
        let criteria = (text: searchText, tags: selectedTags, excluded: excludedTags, sort: sortOrder)
        activeSearch = criteria
        currentPage = 1
        items = []
        isLoading = true
        hasMore = true
        errorMessage = nil
        do {
            let results = try await api.searchItems(query: criteria.text, tags: criteria.tags,
                excludedTags: criteria.excluded, sortOrder: criteria.sort, page: 1)
            guard generation == requestGeneration else { return }
            items = results
            hasMore = results.count == 20
        } catch {
            guard generation == requestGeneration else { return }
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func loadMore() async {
        guard !isLoading, hasMore, let criteria = activeSearch else { return }
        let generation = requestGeneration
        let page = currentPage + 1
        isLoading = true
        errorMessage = nil
        do {
            let results = try await api.searchItems(query: criteria.text, tags: criteria.tags,
                excludedTags: criteria.excluded, sortOrder: criteria.sort, page: page)
            guard generation == requestGeneration else { return }
            let existing = Set(items.map(\.id))
            items.append(contentsOf: results.filter { !existing.contains($0.id) })
            currentPage = page
            hasMore = results.count == 20
        } catch {
            guard generation == requestGeneration else { return }
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func download(item: WorkshopItem) {
        steamCmd.downloadWorkshopItem(workshopId: item.id)
    }

    func downloadState(for item: WorkshopItem) -> SteamCmdService.DownloadState? {
        steamCmd.downloadProgress[item.id]
    }

    func toggleTag(_ tag: String) {
        if selectedTags.contains(tag) {
            selectedTags.removeAll { $0 == tag }
        } else {
            if let group = Self.exclusiveGroups.first(where: { $0.contains(tag) }) {
                selectedTags.removeAll { group.contains($0) }
            }
            excludedTags.removeAll { $0 == tag }
            selectedTags.append(tag)
        }
        currentPage = 1
    }

    func toggleExcludedTag(_ tag: String) {
        selectedTags.removeAll { $0 == tag }
        if excludedTags.contains(tag) { excludedTags.removeAll { $0 == tag } }
        else { excludedTags.append(tag) }
        currentPage = 1
    }

    func clearFilters() {
        selectedTags = []
        excludedTags = []
        currentPage = 1
    }

    func resetFilters() {
        selectedTags = ["Everyone"]
        excludedTags = []
        currentPage = 1
    }
}
