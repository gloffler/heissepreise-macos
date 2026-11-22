import AppKit
import Foundation
import Observation
import PriceCore

/// Central state: catalog, query, filters, results, selection. Searches run on a
/// background task per keystroke; stale results are discarded by generation number.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case starting
        case loading(String)
        case ready
        case failed(String)
    }

    enum Scope: Hashable {
        case all
        case watchlist
        case pinned(UUID)
    }

    // MARK: Data

    private(set) var catalog: Catalog = .empty
    private(set) var engine: SearchEngine?
    private(set) var phase: Phase = .starting
    private(set) var isSyncing = false
    private(set) var syncMessage: String?
    private(set) var lastSync: Date?
    let library = LibraryStore()
    private let sync = DataSyncService()

    // MARK: Query state

    var searchText = "" { didSet { if searchText != oldValue { scheduleSearch() } } }
    var filters = FilterState() { didSet { if filters != oldValue { scheduleSearch() } } }
    var sort = ResultOrder.default { didSet { if sort != oldValue { scheduleSearch() } } }
    private(set) var scope: Scope = .all

    // MARK: Results

    private(set) var result = SearchResult.empty(SearchRequest(text: "", filters: FilterState(), sort: .default))
    /// Bumped whenever `result` changes – the table reloads only then.
    private(set) var resultGeneration = 0
    var selection: Int32? { didSet { if selection != oldValue { selectionGeneration += 1 } } }
    private(set) var selectionGeneration = 0
    var showInspector = false
    /// Bumped to move keyboard focus into the search field.
    private(set) var focusSearchToken = 0
    /// Per pinned search: (total results, results changed since last viewed).
    private(set) var pinnedStats: [UUID: (total: Int, changed: Int)] = [:]
    private(set) var watchlistChanged = 0

    private var generation = 0
    private var searchTask: Task<Void, Never>?
    private var keyMonitor: Any?

    var selectedProduct: Product? {
        guard let selection, Int(selection) < catalog.count else { return nil }
        return catalog[selection]
    }

    // MARK: Lifecycle

    func start() async {
        installKeyMonitor()
        DebugSnapshots.runIfRequested(model: self)
        lastSync = await sync.lastSync
        let cached = await sync.cachedFeeds()
        if !cached.isEmpty {
            phase = .loading("Lade lokalen Cache …")
            await build(from: cached)
        } else {
            phase = .loading("Lade Preisdaten von heisse-preise.io …")
        }
        await refresh(force: false)
    }

    /// Revalidates all feeds (conditional GET); rebuilds the index only if something changed.
    func refresh(force: Bool) async {
        guard !isSyncing else { return }
        isSyncing = true
        syncMessage = "Prüfe auf neue Daten …"
        defer { isSyncing = false }
        let report = await sync.sync(force: force)
        lastSync = await sync.lastSync
        if report.anyChanged || catalog.count == 0 {
            syncMessage = "Aktualisiere Index …"
            let feeds = await sync.cachedFeeds()
            if feeds.isEmpty {
                phase = .failed(report.failed.values.first ?? "Keine Daten verfügbar")
                syncMessage = nil
                return
            }
            await build(from: feeds)
        }
        if !report.failed.isEmpty {
            syncMessage = "\(report.failed.count) Händler nicht erreichbar"
        } else if report.anyChanged {
            let mb = Double(report.bytesDownloaded) / 1_000_000
            syncMessage = "\(report.changed.count) Feeds aktualisiert (\(String(format: "%.1f", mb)) MB)"
        } else {
            syncMessage = "Daten aktuell"
        }
    }

    private func build(from feeds: [Store: Data]) async {
        do {
            let catalog = try await Catalog.build(feeds: feeds)
            let engine = SearchEngine(catalog: catalog)
            await Task.detached(priority: .userInitiated) { engine.warmUp([.unitPrice, .lastChange]) }.value
            let selectedKey = selectedProduct?.key
            self.catalog = catalog
            self.engine = engine
            selection = selectedKey.flatMap { catalog.lookup[$0] }
            phase = .ready
            scheduleSearch()
            refreshLibraryStats()
            // Remaining sort orders in the background, so header clicks are instant later.
            Task.detached(priority: .utility) { engine.warmUp(SortKey.allCases) }
        } catch {
            phase = .failed("Daten konnten nicht gelesen werden: \(error)")
        }
    }

    // MARK: Searching

    private var watchlistIDs: Set<Int32> {
        Set(library.watchlist.compactMap { catalog.lookup[$0.key] })
    }

    private func currentRequest() -> SearchRequest {
        SearchRequest(text: searchText, filters: filters, sort: sort, today: DayMath.today,
                      restrictTo: scope == .watchlist ? watchlistIDs : nil)
    }

    func scheduleSearch() {
        guard let engine else { return }
        generation += 1
        let generation = self.generation
        let request = currentRequest()
        searchTask?.cancel()
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let result = engine.run(request, isCancelled: { Task.isCancelled }) else { return }
            await self?.apply(result, generation: generation)
        }
    }

    private func apply(_ result: SearchResult, generation: Int) {
        guard generation == self.generation else { return }
        let queryChanged = result.request.text != self.result.request.text
        self.result = result
        resultGeneration += 1
        // A new query jumps to the best hit; filter/sort changes keep the selection if it is still visible.
        if !queryChanged, let selection, result.ids.contains(selection) { return }
        selection = result.ids.first
    }

    // MARK: Keyboard actions

    func focusSearch() { focusSearchToken += 1 }

    func moveSelection(by delta: Int) {
        let ids = result.ids
        guard !ids.isEmpty else { return }
        let current = selection.flatMap { ids.firstIndex(of: $0) } ?? (delta > 0 ? -1 : ids.count)
        selection = ids[min(max(current + delta, 0), ids.count - 1)]
    }

    func moveSelectionToEdge(top: Bool) {
        selection = top ? result.ids.first : result.ids.last
    }

    func openDetail() {
        if selection == nil { selection = result.ids.first }
        if selection != nil { showInspector = true }
    }

    /// Esc: close details → clear search → leave special scope → reset filters.
    func escape() {
        if showInspector {
            showInspector = false
        } else if !searchText.isEmpty {
            searchText = ""
        } else if scope != .all {
            show(.all)
        } else if filters != FilterState() {
            filters = FilterState()
        }
    }

    func setSort(_ key: SortKey) {
        if sort.key == key {
            sort.ascending.toggle()
        } else {
            // Newest changes first; everything else cheapest / smallest / A–Z first.
            sort = ResultOrder(key: key, ascending: key != .lastChange)
        }
    }

    // MARK: Scopes, pinned searches, watchlist

    func show(_ newScope: Scope) {
        switch newScope {
        case .all:
            scope = .all
        case .watchlist:
            scope = .watchlist
            library.markWatchlistViewed()
            watchlistChanged = 0
        case .pinned(let id):
            guard let pinned = library.pinned.first(where: { $0.id == id }) else { return }
            scope = .pinned(id)
            searchText = pinned.text
            filters = pinned.filters
            sort = pinned.sort
            library.markViewed(id)
            pinnedStats[id]?.changed = 0
        }
        scheduleSearch()
        focusSearch()
    }

    func pinCurrentSearch() {
        let base = searchText.trimmingCharacters(in: .whitespaces)
        var name = base.isEmpty ? "Alle Produkte" : base
        if filters.activeCount > 0 { name += " (\(filters.activeCount) Filter)" }
        library.pin(name: name, text: searchText, filters: filters, sort: sort)
        if let id = library.pinned.last?.id { scope = .pinned(id) }
        refreshLibraryStats()
    }

    func toggleWatchSelected() {
        guard let product = selectedProduct else { return }
        library.toggleWatch(product)
        if scope == .watchlist { scheduleSearch() }
    }

    /// Evaluates every pinned search in the background: total hits and hits whose
    /// price changed since the search was last opened.
    func refreshLibraryStats() {
        guard let engine else { return }
        let catalog = self.catalog
        let pinned = library.pinned
        let today = DayMath.today
        Task.detached(priority: .utility) { [weak self] in
            var stats: [UUID: (total: Int, changed: Int)] = [:]
            for search in pinned {
                let request = SearchRequest(text: search.text, filters: search.filters, sort: search.sort, today: today)
                guard let result = engine.run(request) else { continue }
                let since = DayMath.day(of: search.lastViewed)
                let changed = result.ids.reduce(0) { $0 + (catalog[$1].lastChange > since && catalog[$1].historyCount > 1 ? 1 : 0) }
                stats[search.id] = (result.ids.count, changed)
            }
            engine.resetTextCache()
            await self?.setPinnedStats(stats)
        }
        watchlistChanged = library.watchlist.reduce(0) { count, item in
            guard let id = catalog.lookup[item.key] else { return count }
            return count + (catalog[id].lastChange > DayMath.day(of: item.lastViewed) ? 1 : 0)
        }
    }

    private func setPinnedStats(_ stats: [UUID: (total: Int, changed: Int)]) {
        pinnedStats = stats
    }

    // MARK: Product actions

    func copySelected() {
        guard let product = selectedProduct else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Fmt.clipboardLine(product), forType: .string)
    }

    func openInShop(_ product: Product? = nil) {
        guard let product = product ?? selectedProduct else { return }
        if let url = product.productURL ?? product.store.shopSearchURL(for: product.name) {
            NSWorkspace.shared.open(url)
        }
    }

    func searchInShop(_ product: Product? = nil) {
        guard let product = product ?? selectedProduct,
              let url = product.store.shopSearchURL(for: product.name) else { return }
        NSWorkspace.shared.open(url)
    }

    /// ⌘C copies the selected product – unless text is selected in a text view.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "c" else { return event }
            let consumed = MainActor.assumeIsolated { () -> Bool in
                if let textView = NSApp.keyWindow?.firstResponder as? NSTextView, textView.selectedRange().length > 0 {
                    return false
                }
                guard let self, self.selectedProduct != nil else { return false }
                self.copySelected()
                return true
            }
            return consumed ? nil : event
        }
    }
}
