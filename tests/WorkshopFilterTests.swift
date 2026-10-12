import Foundation
import Combine

@MainActor final class SteamCmdService: ObservableObject {
    enum DownloadState { case completed }
    @Published var downloadProgress: [String: DownloadState] = [:]
    func downloadWorkshopItem(workshopId: String) {}
}

final class FilterFixtureAPI: WorkshopAPIService {
    var failNextPage = false
    override func searchItems(query: String = "", tags: [String] = [], excludedTags: [String] = [],
                              sortOrder: WorkshopSortOrder = .trending, page: Int = 1, perPage: Int = 20) async throws -> [WorkshopItem] {
        if query == "slow" { try await Task.sleep(nanoseconds: 100_000_000) }
        if page == 2 && failNextPage { failNextPage = false; throw URLError(.notConnectedToInternet) }
        return (0..<20).map { WorkshopItem(id: "\(query)-\(page)-\($0)", title: query, previewURL: nil,
            tags: tags, subscriptions: 0, fileSize: 0, creatorAppId: 431960, description: nil) }
    }
}

@main struct WorkshopFilterTests {
    @MainActor static func main() async throws {
        let api = FilterFixtureAPI()
        let vm = WorkshopViewModel(steamCmd: SteamCmdService(), api: api)
        vm.toggleTag("Mature")
        precondition(vm.selectedTags == ["Mature"])
        vm.toggleTag("Scene"); vm.toggleTag("Video")
        precondition(!vm.selectedTags.contains("Scene") && vm.selectedTags.contains("Video"))
        vm.toggleTag("1920 x 1080"); vm.toggleTag("Ultrawide 3440 x 1440")
        precondition(!vm.selectedTags.contains("1920 x 1080"))
        vm.toggleTag("Anime"); vm.toggleExcludedTag("Anime")
        precondition(!vm.selectedTags.contains("Anime") && vm.excludedTags == ["Anime"])
        vm.toggleTag("Anime")
        precondition(vm.selectedTags.contains("Anime") && vm.excludedTags.isEmpty)
        vm.toggleTag("Audio responsive"); vm.toggleTag("Customizable")
        precondition(vm.selectedTags.contains("Audio responsive") && vm.selectedTags.contains("Customizable"))
        vm.clearFilters(); precondition(vm.filterCount == 0)
        vm.resetFilters(); precondition(vm.selectedTags == ["Everyone"] && vm.excludedTags.isEmpty)
        precondition(WorkshopViewModel.resolutionTags.count == 25)

        let url = try WorkshopAPIService.searchURL(query: "rain & night", tags: ["Everyone", "Ultrawide 3440 x 1440"],
            excludedTags: ["Anime", "HDR"], sortOrder: .trending, page: 2, perPage: 20, apiKey: "fixture")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        for (key, value) in [("match_all_tags", "true"), ("requiredtags[1]", "Ultrawide 3440 x 1440"),
                             ("excludedtags[0]", "Anime"), ("excludedtags[1]", "HDR"), ("page", "2"),
                             ("search_text", "rain & night"), ("query_type", "12")] {
            precondition(query.contains(URLQueryItem(name: key, value: value)), key)
        }
        vm.searchText = "slow"
        let old = Task { await vm.search() }
        try await Task.sleep(nanoseconds: 10_000_000)
        vm.searchText = "fast"
        await vm.search(); await old.value
        precondition(vm.items.allSatisfy { $0.title == "fast" } && !vm.isLoading)
        vm.searchText = "unsubmitted draft"
        api.failNextPage = true
        await vm.loadMore()
        precondition(vm.currentPage == 1 && vm.items.count == 20 && vm.errorMessage != nil)
        await vm.loadMore()
        precondition(vm.currentPage == 2 && vm.items.count == 40 && vm.errorMessage == nil && vm.items.allSatisfy { $0.title == "fast" })
        print("PASS: filter combinations, exclusion conflicts, reset, API encoding, stale results, pagination retry")
    }
}
