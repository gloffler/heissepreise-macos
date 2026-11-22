import Foundation

/// Downloads the per-store feeds from heisse-preise.io, caches them on disk and
/// revalidates them with conditional requests (`If-None-Match` / `If-Modified-Since`).
public actor DataSyncService {
    public static let baseURL = URL(string: "https://heisse-preise.io/data/")!

    public struct FeedMetadata: Codable, Sendable {
        public var etag: String?
        public var lastModified: String?
        public var fetchedAt: Date
        public var byteCount: Int
    }

    public enum Progress: Sendable {
        case checking(Store)
        case downloaded(Store, bytes: Int)
        case notModified(Store)
        case failed(Store, String)
    }

    public struct SyncReport: Sendable {
        public var changed: [Store] = []
        public var unchanged: [Store] = []
        public var failed: [Store: String] = [:]
        public var bytesDownloaded = 0
        public var anyChanged: Bool { !changed.isEmpty }
    }

    public let cacheDirectory: URL
    private let session: URLSession

    public init(cacheDirectory: URL? = nil) {
        let directory = cacheDirectory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.heisse-preise.mac/feeds", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.cacheDirectory = directory

        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData // we validate ourselves
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 6
        config.timeoutIntervalForRequest = 60
        config.httpAdditionalHeaders = ["Accept-Encoding": "gzip, br", "User-Agent": "HeissePreise-macOS/1.0"]
        session = URLSession(configuration: config)
    }

    // MARK: Cache

    private func feedURL(_ store: Store) -> URL { cacheDirectory.appendingPathComponent("\(store.feedKey).json") }
    private func metaURL(_ store: Store) -> URL { cacheDirectory.appendingPathComponent("\(store.feedKey).meta.json") }

    public func metadata(for store: Store) -> FeedMetadata? {
        guard let data = try? Data(contentsOf: metaURL(store)) else { return nil }
        return try? JSONDecoder().decode(FeedMetadata.self, from: data)
    }

    public var hasCache: Bool {
        Store.allCases.contains { FileManager.default.fileExists(atPath: feedURL($0).path) }
    }

    public var lastSync: Date? {
        Store.allCases.compactMap { metadata(for: $0)?.fetchedAt }.max()
    }

    /// Reads all cached feeds (memory-mapped, so the parser works straight on the page cache).
    public func cachedFeeds() -> [Store: Data] {
        var feeds: [Store: Data] = [:]
        for store in Store.allCases {
            if let data = try? Data(contentsOf: feedURL(store), options: .alwaysMapped), !data.isEmpty {
                feeds[store] = data
            }
        }
        return feeds
    }

    // MARK: Network

    /// Revalidates all feeds in parallel. Unchanged feeds cost one tiny 304 round trip.
    public func sync(force: Bool = false, progress: (@Sendable (Progress) -> Void)? = nil) async -> SyncReport {
        let requests: [(Store, URLRequest)] = Store.allCases.map { store in
            var request = URLRequest(url: Self.baseURL.appendingPathComponent("latest-canonical.\(store.feedKey).compressed.json"))
            let haveFile = FileManager.default.fileExists(atPath: feedURL(store).path)
            if !force, haveFile, let meta = metadata(for: store) {
                if let etag = meta.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
                if let lastModified = meta.lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
            }
            return (store, request)
        }

        let session = self.session
        let results = await withTaskGroup(of: (Store, Result<(Data, HTTPURLResponse), Error>).self) { group in
            for (store, request) in requests {
                group.addTask {
                    progress?(.checking(store))
                    do {
                        let (data, response) = try await session.data(for: request)
                        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                        return (store, .success((data, http)))
                    } catch {
                        return (store, .failure(error))
                    }
                }
            }
            var all: [(Store, Result<(Data, HTTPURLResponse), Error>)] = []
            for await result in group { all.append(result) }
            return all
        }

        var report = SyncReport()
        for (store, result) in results {
            switch result {
            case .failure(let error):
                report.failed[store] = error.localizedDescription
                progress?(.failed(store, error.localizedDescription))
            case .success(let (data, http)):
                switch http.statusCode {
                case 304:
                    report.unchanged.append(store)
                    if var meta = metadata(for: store) {
                        meta.fetchedAt = Date()
                        save(meta, for: store)
                    }
                    progress?(.notModified(store))
                case 200..<300:
                    do {
                        try data.write(to: feedURL(store), options: .atomic)
                        save(FeedMetadata(
                            etag: http.value(forHTTPHeaderField: "ETag"),
                            lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
                            fetchedAt: Date(), byteCount: data.count
                        ), for: store)
                        report.changed.append(store)
                        report.bytesDownloaded += data.count
                        progress?(.downloaded(store, bytes: data.count))
                    } catch {
                        report.failed[store] = error.localizedDescription
                        progress?(.failed(store, error.localizedDescription))
                    }
                default:
                    let message = "HTTP \(http.statusCode)"
                    report.failed[store] = message
                    progress?(.failed(store, message))
                }
            }
        }
        return report
    }

    private func save(_ meta: FeedMetadata, for store: Store) {
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: metaURL(store), options: .atomic)
        }
    }
}
