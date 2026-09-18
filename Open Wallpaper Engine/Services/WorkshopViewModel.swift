import Foundation
import SwiftUI
import Combine

class WorkshopViewModel: ObservableObject {
    @Published var items: [WorkshopItem] = []
    @Published var searchText = ""
    @Published var authorId: String?
    @Published var sortOrder: WorkshopSortOrder = .trending
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var currentPage = 1
    @Published var selectedTags: [String] = ["Everyone"]
    @AppStorage("WorkshopHideDownloaded") var hideDownloaded = false
    @Published private(set) var hasNextPage = false
    @Published var selectedItemIds = Set<String>()
    @Published var isBatchDownloadConfirming = false
    private var selectedItems: [String: WorkshopItem] = [:]

    @Published private(set) var itemsPerPage = 21

    let steamCmd: SteamCmdService
    private let api = WorkshopAPIService()
    private var cancellable: AnyCancellable?
    private var downloadedIndexCancellable: AnyCancellable?
    private var cachedPages: [Int: [WorkshopItem]] = [:]
    private var cachedSearchKey = ""
    private var selectionAnchorId: String?

    static let contentRatingTags = ["Everyone", "Questionable", "Mature"]

    static let typeTags = ["Scene", "Video", "Web", "Application"]

    static let genreTags = [
        "Abstract", "Animal", "Anime", "Cartoon", "CGI",
        "Cyberpunk", "Fantasy", "Game", "Girls", "Guys",
        "Landscape", "Medieval", "Memes", "MMD", "Music",
        "Nature", "Pixel Art", "Relaxing", "Retro", "Sci-Fi",
        "Sports", "Technology", "Television", "Vehicle",
    ]

    static let resolutionTags = [
        "1920 x 1080", "2560 x 1440", "3840 x 2160",
        "3440 x 1440", "1440 x 2560",
    ]

    init(steamCmd: SteamCmdService) {
        self.steamCmd = steamCmd
        // Forward steamCmd changes (e.g. downloadProgress) to trigger view updates
        self.cancellable = steamCmd.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        self.downloadedIndexCancellable = DownloadedWallpaperIndex.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.cachedPages.removeAll()
                if self?.hideDownloaded == true {
                    Task { await self?.search() }
                }
                self?.objectWillChange.send()
            }
        }
    }

    @MainActor
    func search() async {
        isLoading = true
        errorMessage = nil
        if let authorId {
            do {
                items = try await api.getAuthorWorkshopItems(steamId: authorId)
                preloadThumbnails(items)
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
            return
        }
        let searchKey = "\(searchText)|\(sortOrder.rawValue)|\(selectedTags.sorted().joined(separator: ","))|\(hideDownloaded)"

        if cachedSearchKey != searchKey {
            cachedPages.removeAll()
            cachedSearchKey = searchKey
        }

        do {
            let results = try await pageItems(for: currentPage)
            items = results
            preloadThumbnails(results)
            await preloadAdjacentPages(for: currentPage, searchKey: searchKey)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func download(item: WorkshopItem) {
        steamCmd.downloadWorkshopItem(
            workshopId: item.id,
            title: item.title,
            previewURL: item.previewImageURL,
            creatorId: item.creatorId,
            subscriptions: item.subscriptions,
            fileSize: item.fileSize
        )
    }

    func showAuthor(_ steamId: String) {
        authorId = steamId
        searchText = ""
        currentPage = 1
        cachedPages.removeAll()
        Task { @MainActor in await search() }
    }

    func clearAuthorFilter() {
        authorId = nil
        currentPage = 1
        cachedPages.removeAll()
        Task { @MainActor in await search() }
    }

    func downloadSelectedItems() {
        for item in selectedItems.values {
            download(item: item)
        }
        clearSelection()
    }

    func preview(item: WorkshopItem) {
        steamCmd.previewWorkshopItem(workshopId: item.id)
    }

    func downloadState(for item: WorkshopItem) -> SteamCmdService.DownloadState? {
        if isDownloaded(item) {
            return .completed
        }
        return steamCmd.downloadProgress[item.id]
    }

    var visibleItems: [WorkshopItem] {
        hideDownloaded ? items.filter { !isDownloaded($0) } : items
    }

    func isDownloaded(_ item: WorkshopItem) -> Bool {
        DownloadedWallpaperIndex.shared.contains(item.id)
    }

    func isPreviewLoading(_ item: WorkshopItem) -> Bool {
        steamCmd.previewProgress.contains(item.id)
    }

    func toggleTag(_ tag: String) {
        if selectedTags.contains(tag) {
            selectedTags.removeAll { $0 == tag }
        } else {
            selectedTags.append(tag)
        }
        currentPage = 1
    }

    func resetFilters() {
        selectedTags = ["Everyone"]
        currentPage = 1
    }

    @MainActor
    func updateItemsPerPage(for size: CGSize, itemSize: CGFloat) async {
        let spacing: CGFloat = 13
        let columns = max(1, Int((size.width + spacing) / (itemSize + spacing)))
        let rows = max(1, Int((size.height + spacing) / (itemSize + spacing)))
        let pageSize = columns * rows
        guard itemsPerPage != pageSize else { return }
        itemsPerPage = pageSize
        currentPage = 1
        cachedPages.removeAll()
        await search()
    }

    func selectItem(_ item: WorkshopItem) {
        let modifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isAdditive = modifiers.contains(.control) || modifiers.contains(.command)

        if modifiers.contains(.shift), !isAdditive,
           let anchorId = selectionAnchorId,
           let start = items.firstIndex(where: { $0.id == anchorId }),
           let end = items.firstIndex(where: { $0.id == item.id }) {
            let rangeItems = items[min(start, end)...max(start, end)]
            selectedItemIds = Set(rangeItems.map(\.id))
            selectedItems = Dictionary(uniqueKeysWithValues: rangeItems.map { ($0.id, $0) })
        } else if isAdditive {
            if selectedItemIds.contains(item.id) {
                selectedItemIds.remove(item.id)
                selectedItems.removeValue(forKey: item.id)
            } else {
                selectedItemIds.insert(item.id)
                selectedItems[item.id] = item
            }
            selectionAnchorId = item.id
        } else {
            selectedItemIds = [item.id]
            selectedItems = [item.id: item]
            selectionAnchorId = item.id
        }
    }

    func clearSelection() {
        selectedItemIds.removeAll()
        selectedItems.removeAll()
        selectionAnchorId = nil
    }

    @MainActor
    private func pageItems(for page: Int) async throws -> [WorkshopItem] {
        if let cachedItems = cachedPages[page] {
            return cachedItems
        }

        let results = try await displayedPageItems(for: page)
        cachedPages[page] = results
        return results
    }

    @MainActor
    private func displayedPageItems(for displayedPage: Int) async throws -> [WorkshopItem] {
        let sourcePageSize = 50
        var sourcePage = 1
        var skippedItems = (displayedPage - 1) * itemsPerPage
        var visibleItems: [WorkshopItem] = []

        while visibleItems.count < itemsPerPage {
            let sourceItems = try await api.searchItems(
                query: searchText,
                tags: selectedTags,
                sortOrder: sortOrder,
                page: sourcePage,
                perPage: sourcePageSize
            )
            guard !sourceItems.isEmpty else { break }

            for item in sourceItems where !hideDownloaded || !isDownloaded(item) {
                if skippedItems > 0 {
                    skippedItems -= 1
                } else {
                    visibleItems.append(item)
                    if visibleItems.count == itemsPerPage {
                        break
                    }
                }
            }

            guard sourceItems.count == sourcePageSize else { break }
            sourcePage += 1
        }

        return visibleItems
    }

    @MainActor
    private func preloadAdjacentPages(for page: Int, searchKey: String) async {
        let adjacentPages = [page - 1, page + 1].filter { $0 > 0 }
        for adjacentPage in adjacentPages {
            do {
                let adjacentItems = try await pageItems(for: adjacentPage)
                guard cachedSearchKey == searchKey, currentPage == page else { return }
                preloadThumbnails(adjacentItems)
                if adjacentPage == page + 1 {
                    hasNextPage = adjacentItems.count == itemsPerPage
                }
            } catch {
                guard cachedSearchKey == searchKey, currentPage == page else { return }
                if adjacentPage == page + 1 {
                    hasNextPage = false
                }
            }
        }
    }

    private func preloadThumbnails(_ items: [WorkshopItem]) {
        for item in items {
            guard let url = item.previewImageURL else { continue }
            URLSession.shared.dataTask(with: url).resume()
        }
    }
}
