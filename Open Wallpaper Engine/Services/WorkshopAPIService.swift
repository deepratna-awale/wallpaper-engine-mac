import Foundation

struct WorkshopItem: Identifiable, Codable {
    let id: String
    let title: String
    let previewURL: String?
    let tags: [String]
    let subscriptions: Int
    let fileSize: Int
    let creatorAppId: Int?
    let creatorId: String?
    let description: String?
    let votesUp: Int
    let votesDown: Int

    var previewImageURL: URL? {
        guard let urlString = previewURL else { return nil }
        return URL(string: urlString)
    }
}

final class WorkshopMetadataStore {
    static let shared = WorkshopMetadataStore()

    private let storageKey = "WorkshopMetadataById"
    private var metadata: [String: WorkshopItem]
    private let lock = NSLock()

    private init() {
        guard let data = Self.storedData(forKey: storageKey),
              let saved = try? JSONDecoder().decode([String: WorkshopItem].self, from: data) else {
            metadata = [:]
            return
        }
        metadata = saved
    }

    func item(for workshopId: String) -> WorkshopItem? {
        lock.lock()
        defer { lock.unlock() }
        return metadata[workshopId]
    }

    func save(_ item: WorkshopItem) {
        lock.lock()
        defer { lock.unlock() }
        metadata[item.id] = item
        if let data = try? JSONEncoder().encode(metadata) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private static func storedData(forKey key: String) -> Data? {
        if let data = UserDefaults.standard.data(forKey: key) { return data }
        return UserDefaults.standard.string(forKey: key)?.data(using: .utf8)
    }
}

final class SteamPlayerStore {
    static let shared = SteamPlayerStore()

    private let storageKey = "SteamPlayersById"
    private var players: [String: SteamPlayer]
    private let lock = NSLock()

    private init() {
        guard let data = Self.storedData(forKey: storageKey),
              let saved = try? JSONDecoder().decode([String: SteamPlayer].self, from: data) else {
            players = [:]
            return
        }
        players = saved
    }

    func player(for steamId: String) -> SteamPlayer? {
        lock.lock()
        defer { lock.unlock() }
        return players[steamId]
    }

    func save(_ player: SteamPlayer) {
        lock.lock()
        defer { lock.unlock() }
        players[player.steamId] = player
        if let data = try? JSONEncoder().encode(players) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private static func storedData(forKey key: String) -> Data? {
        if let data = UserDefaults.standard.data(forKey: key) { return data }
        return UserDefaults.standard.string(forKey: key)?.data(using: .utf8)
    }
}

struct SteamPlayer: Codable {
    let steamId: String
    let personaName: String
    let avatarURL: URL?

    enum CodingKeys: String, CodingKey {
        case steamId = "steamid"
        case personaName = "personaname"
        case avatarURL = "avatarfull"
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
        sortOrder: WorkshopSortOrder = .trending,
        page: Int = 1,
        perPage: Int = 20
    ) async throws -> [WorkshopItem] {
        // Use ISteamRemoteStorage/GetPublishedFileDetails for specific IDs
        // Use the public search endpoint for browsing
        var components = URLComponents(string: "https://api.steampowered.com/IPublishedFileService/QueryFiles/v1/")!

        let hasSearchText = !query.isEmpty
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "query_type", value: "\(sortOrder.queryTypeForSearch(hasText: hasSearchText))"),
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "numperpage", value: "\(perPage)"),
            URLQueryItem(name: "appid", value: "\(Self.wallpaperEngineAppId)"),
            URLQueryItem(name: "match_all_tags", value: "false"),
            URLQueryItem(name: "return_tags", value: "true"),
            URLQueryItem(name: "return_previews", value: "true"),
            URLQueryItem(name: "return_metadata", value: "true"),
            URLQueryItem(name: "return_short_description", value: "true"),
            URLQueryItem(name: "return_details", value: "true"),
        ]

        if !query.isEmpty {
            queryItems.append(URLQueryItem(name: "search_text", value: query))
        }

        for (index, tag) in tags.enumerated() {
            queryItems.append(URLQueryItem(name: "requiredtags[\(index)]", value: tag))
        }

        let apiKey = Self.loadAPIKey()
        guard !apiKey.isEmpty else {
            throw WorkshopAPIError.noAPIKey
        }
        queryItems.append(URLQueryItem(name: "key", value: apiKey))

        components.queryItems = queryItems

        guard let url = components.url else {
            throw WorkshopAPIError.invalidURL
        }

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

        let items = try parseQueryResponse(data)
        items.forEach { WorkshopMetadataStore.shared.save($0) }
        return items
    }

    /// Get details for specific workshop items by their IDs.
    func getItemDetails(workshopIds: [String]) async throws -> [WorkshopItem] {
        let url = URL(string: "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        var bodyParts = [
            "itemcount=\(workshopIds.count)",
            "includetags=true",
            "includevotes=true",
            "includeshortdescription=true"
        ]
        for (index, id) in workshopIds.enumerated() {
            bodyParts.append("publishedfileids[\(index)]=\(id)")
        }
        request.httpBody = bodyParts.joined(separator: "&").data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw WorkshopAPIError.requestFailed
        }

        let items = try parseFileDetailsResponse(data)
        items.forEach { WorkshopMetadataStore.shared.save($0) }
        return items
    }

    func getAuthorWorkshopItems(steamId: String) async throws -> [WorkshopItem] {
        var components = URLComponents(string: "https://steamcommunity.com/profiles/\(steamId)/myworkshopfiles/")!
        components.queryItems = [
            URLQueryItem(name: "appid", value: "\(Self.wallpaperEngineAppId)"),
            URLQueryItem(name: "numperpage", value: "30")
        ]
        guard let url = components.url else { throw WorkshopAPIError.invalidURL }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            throw WorkshopAPIError.requestFailed
        }
        let pattern = #"sharedfiles/filedetails/\?id=(\d+)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var ids: [String] = []
        for match in regex.matches(in: html, range: range) {
            guard let idRange = Range(match.range(at: 1), in: html) else { continue }
            let id = String(html[idRange])
            if !ids.contains(id) { ids.append(id) }
        }
        return try await getItemDetails(workshopIds: ids)
    }

    func getPlayerSummary(steamId: String) async throws -> SteamPlayer? {
        let apiKey = Self.loadAPIKey()
        guard !apiKey.isEmpty else { throw WorkshopAPIError.noAPIKey }

        var components = URLComponents(string: "https://api.steampowered.com/ISteamUser/GetPlayerSummaries/v2/")!
        components.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "steamids", value: steamId)
        ]
        guard let url = components.url else { throw WorkshopAPIError.invalidURL }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw WorkshopAPIError.requestFailed
        }

        struct PlayerResponse: Decodable {
            struct Response: Decodable { let players: [SteamPlayer] }
            let response: Response
        }
        let player = try JSONDecoder().decode(PlayerResponse.self, from: data).response.players.first
        if let player {
            SteamPlayerStore.shared.save(player)
        }
        return player
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
        let tags = parseTags(from: dict["tags"])
        let subscriptions = dict["subscriptions"] as? Int ?? dict["lifetime_subscriptions"] as? Int ?? 0
        let fileSize = dict["file_size"] as? Int ?? 0
        let creatorAppId = dict["creator_app_id"] as? Int
        let creatorId = dict["creator"] as? String
        let description = dict["short_description"] as? String ?? dict["description"] as? String
        let votesUp = dict["votes_up"] as? Int ?? 0
        let votesDown = dict["votes_down"] as? Int ?? 0

        return WorkshopItem(
            id: publishedFileId,
            title: title,
            previewURL: previewURL,
            tags: tags,
            subscriptions: subscriptions,
            fileSize: fileSize,
            creatorAppId: creatorAppId,
            creatorId: creatorId,
            description: description,
            votesUp: votesUp,
            votesDown: votesDown
        )
    }

    private func parseTags(from value: Any?) -> [String] {
        let rawTags: [String]
        if let tagObjects = value as? [[String: Any]] {
            rawTags = tagObjects.compactMap { $0["tag"] as? String }
        } else if let tagStrings = value as? [String] {
            rawTags = tagStrings
        } else {
            rawTags = []
        }

        return Array(Set(rawTags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
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
