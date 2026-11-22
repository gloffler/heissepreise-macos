import PriceCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var model = model

        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
        } detail: {
            VStack(spacing: 0) {
                searchBar
                Divider()
                resultArea
                Divider()
                StatusBar()
            }
            .inspector(isPresented: $model.showInspector) {
                InspectorView()
                    .inspectorColumnWidth(min: 320, ideal: 400, max: 600)
            }
        }
        .toolbar { toolbarContent }
        .navigationTitle(title)
        .task { await model.start() }
    }

    private var title: String {
        switch model.scope {
        case .all: "Heiße Preise"
        case .watchlist: "Merkliste"
        case .pinned(let id): model.library.pinned.first { $0.id == id }?.name ?? "Heiße Preise"
        }
    }

    // MARK: Search bar

    private var searchBar: some View {
        @Bindable var model = model
        return HStack(spacing: 10) {
            SearchField(
                text: $model.searchText,
                focusToken: model.focusSearchToken,
                placeholder: "Produkte suchen – z. B. „vollmilch 1l“, „bio käse -gouda“",
                onMove: { model.moveSelection(by: $0) },
                onEdge: { model.moveSelectionToEdge(top: $0) },
                onSubmit: { model.openDetail() },
                onEscape: { model.escape() }
            )
            .frame(height: 30)
            Menu {
                Picker("Sortieren nach", selection: Binding(get: { model.sort.key }, set: { model.setSort($0) })) {
                    ForEach(SortKey.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Aufsteigend", isOn: Binding(get: { model.sort.ascending }, set: { model.sort.ascending = $0 }))
            } label: {
                Label("\(model.sort.key.title) \(model.sort.ascending ? "↑" : "↓")", systemImage: "arrow.up.arrow.down")
                    .labelStyle(.titleAndIcon)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Sortierung (oder Spaltenkopf anklicken)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: Results

    @ViewBuilder
    private var resultArea: some View {
        switch model.phase {
        case .starting, .loading:
            if model.catalog.count == 0 {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    if case .loading(let message) = model.phase { Text(message).foregroundStyle(.secondary) }
                    Text("Beim ersten Start werden ca. 30 MB Preisdaten geladen und lokal gespeichert.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Daten nicht verfügbar", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Erneut versuchen") { Task { await model.refresh(force: true) } }
            }
        case .ready:
            if model.result.ids.isEmpty {
                ContentUnavailableView {
                    Label(model.scope == .watchlist && model.library.watchlist.isEmpty ? "Merkliste ist leer" : "Keine Treffer",
                          systemImage: model.scope == .watchlist ? "star" : "magnifyingglass")
                } description: {
                    Text(model.scope == .watchlist && model.library.watchlist.isEmpty
                         ? "Markiere Produkte mit ⌘D, um ihre Preise im Blick zu behalten."
                         : "Andere Suchbegriffe probieren oder Filter lockern.")
                } actions: {
                    if model.filters.activeCount > 0 {
                        Button("Filter zurücksetzen") { model.filters = FilterState() }
                    }
                }
            } else {
                table
            }
        }
    }

    private var table: some View {
        ProductTable(
            catalog: model.catalog,
            ids: model.result.ids,
            generation: model.resultGeneration,
            selection: model.selection,
            selectionGeneration: model.selectionGeneration,
            sort: model.sort,
            watched: model.library.watchedKeys,
            onSelect: { model.selection = $0 },
            onActivate: { model.openDetail() },
            onEscape: { model.escape() },
            onSort: { model.sort = $0 },
            onType: { text in
                model.searchText += text
                model.focusSearch()
            },
            onToggleWatch: { model.library.toggleWatch($0) },
            onOpenShop: { model.openInShop($0) },
            onCopy: { model.copySelected() }
        )
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { await model.refresh(force: false) }
            } label: {
                Label("Aktualisieren", systemImage: "arrow.clockwise")
            }
            .help("Daten aktualisieren (⌘R)")
            .disabled(model.isSyncing)

            Button {
                model.pinCurrentSearch()
            } label: {
                Label("Suche anpinnen", systemImage: "pin")
            }
            .help("Aktuelle Suche inkl. Filter anpinnen (⇧⌘D)")

            Button {
                model.showInspector.toggle()
            } label: {
                Label("Details", systemImage: "sidebar.right")
            }
            .help("Details ein-/ausblenden (⌘I)")
        }
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            let result = model.result
            Text("\(Fmt.count(result.ids.count)) von \(Fmt.count(model.catalog.count)) Produkten")
                .monospacedDigit()
            Text("Suche \(String(format: "%.1f", Double(result.duration.components.attoseconds) / 1e15)) ms")
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Spacer()
            if model.isSyncing { ProgressView().controlSize(.mini) }
            if let message = model.syncMessage { Text(message) }
            if let latest = model.catalog.latestDay {
                Text("Datenstand \(Fmt.date(latest))")
            }
            if let lastSync = model.lastSync {
                Text("geprüft \(Fmt.relative(lastSync))").foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }
}
