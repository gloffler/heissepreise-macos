import Foundation
import Observation
import PriceCore

/// A pinned search: query text + all filters + sort order.
struct PinnedSearch: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var text: String
    var filters: FilterState
    var sort: ResultOrder
    var createdAt = Date()
    /// Products whose price changed after this moment count as "neu".
    var lastViewed = Date()
}

/// A product on the watchlist, remembered by its stable store key.
struct WatchItem: Codable, Identifiable, Hashable {
    var key: ProductKey
    var name: String
    var addedAt = Date()
    var centsAtAdd: Int32
    var lastViewed = Date()
    var id: ProductKey { key }
}

/// Persists pinned searches and the watchlist as JSON in Application Support.
@MainActor
@Observable
final class LibraryStore {
    private(set) var pinned: [PinnedSearch] = []
    private(set) var watchlist: [WatchItem] = []
    private(set) var watchedKeys: Set<ProductKey> = []

    private struct Snapshot: Codable {
        var pinned: [PinnedSearch]
        var watchlist: [WatchItem]
    }

    private let fileURL: URL

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HeissePreise", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("library.json")
        if let data = try? Data(contentsOf: fileURL),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            pinned = snapshot.pinned
            watchlist = snapshot.watchlist
        }
        watchedKeys = Set(watchlist.map(\.key))
    }

    private func save() {
        watchedKeys = Set(watchlist.map(\.key))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(Snapshot(pinned: pinned, watchlist: watchlist)) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: Pinned searches

    func pin(name: String, text: String, filters: FilterState, sort: ResultOrder) {
        pinned.append(PinnedSearch(name: name, text: text, filters: filters, sort: sort))
        save()
    }

    func rename(_ id: PinnedSearch.ID, to name: String) {
        guard let i = pinned.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        pinned[i].name = name
        save()
    }

    func remove(_ id: PinnedSearch.ID) {
        pinned.removeAll { $0.id == id }
        save()
    }

    func markViewed(_ id: PinnedSearch.ID) {
        guard let i = pinned.firstIndex(where: { $0.id == id }) else { return }
        pinned[i].lastViewed = Date()
        save()
    }

    func movePinned(from source: IndexSet, to destination: Int) {
        pinned.move(fromOffsets: source, toOffset: destination)
        save()
    }

    // MARK: Watchlist

    func isWatched(_ key: ProductKey) -> Bool { watchedKeys.contains(key) }

    func toggleWatch(_ product: Product) {
        if watchedKeys.contains(product.key) {
            watchlist.removeAll { $0.key == product.key }
        } else {
            watchlist.append(WatchItem(key: product.key, name: product.name, centsAtAdd: product.cents))
        }
        save()
    }

    func markWatchlistViewed() {
        let now = Date()
        for i in watchlist.indices { watchlist[i].lastViewed = now }
        save()
    }
}
