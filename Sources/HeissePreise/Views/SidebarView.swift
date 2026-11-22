import PriceCore
import SwiftUI

/// Filter sidebar: saved searches, watchlist, stores, price type, ranges, quantity, categories.
/// Every control writes straight into `AppModel.filters`, which triggers a new search.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var expandedCategories: Set<Int> = []
    @ViewState private var renaming: PinnedSearch?
    @ViewState private var renameText = ""

    var body: some View {
        @Bindable var model = model
        let result = model.result

        List {
            librarySection

            Section {
                HStack(spacing: 4) {
                    ForEach(StorePreset.allCases) { preset in
                        Button(preset.title) { model.filters.stores = preset.stores }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(model.filters.stores == preset.stores ? .accentColor : nil)
                            .help(preset.help)
                    }
                }
                .padding(.vertical, 2)
                ForEach(Store.allCases) { store in
                    StoreRow(
                        store: store,
                        isOn: model.filters.stores.contains(store),
                        count: result.storeCounts[Int(store.rawValue)],
                        summary: model.catalog.feeds[store],
                        toggle: { only in
                            if only {
                                model.filters.stores = [store]
                            } else if model.filters.stores.contains(store) {
                                model.filters.stores.remove(store)
                            } else {
                                model.filters.stores.insert(store)
                            }
                        }
                    )
                }
            } header: {
                Text("Händler")
            }

            Section("Preistyp") {
                Picker("Preistrend", selection: $model.filters.trend) {
                    ForEach(PriceTrend.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                Toggle("Nur Eigenmarken", isOn: $model.filters.onlyBudget)
                    .help(Store.allBudgetBrands.map { $0.uppercased() }.joined(separator: ", "))
                Toggle("Nur Bio", isOn: $model.filters.onlyBio)
                Toggle("Nur aktuell verfügbar", isOn: $model.filters.hideUnavailable)
                    .help("Blendet Produkte aus, die der Händler nicht mehr listet bzw. deren Daten nicht mehr aktualisiert werden.")
                Picker("Geändert", selection: $model.filters.changedWithinDays) {
                    Text("Beliebig").tag(Int?.none)
                    Text("Heute").tag(Int?.some(0))
                    Text("7 Tage").tag(Int?.some(7))
                    Text("30 Tage").tag(Int?.some(30))
                    Text("90 Tage").tag(Int?.some(90))
                }
                .pickerStyle(.menu)
            }

            Section("Preisspanne") {
                RangeFields(label: "Preis €", min: $model.filters.minPrice, max: $model.filters.maxPrice)
                RangeFields(label: "Grundpreis €", min: $model.filters.minUnitPrice, max: $model.filters.maxUnitPrice)
            }

            Section("Menge") {
                Picker("Einheit", selection: $model.filters.unitFilter) {
                    ForEach(UnitFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                RangeFields(label: "Gebinde \(model.filters.unitFilter.quantityLabel)",
                            min: $model.filters.minQuantity, max: $model.filters.maxQuantity)
            }

            Section {
                ForEach(ProductCategory.all) { category in
                    categoryRow(category, result: result)
                }
            } header: {
                HStack {
                    Text("Kategorien")
                    Spacer()
                    if !model.filters.categories.isEmpty {
                        Button("Alle") { model.filters.categories = [] }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if model.filters.activeCount > 0 {
                Button {
                    model.filters = FilterState()
                } label: {
                    Label("\(model.filters.activeCount) Filter zurücksetzen", systemImage: "line.3.horizontal.decrease.circle")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .padding(10)
                .background(.bar)
            }
        }
        .sheet(item: $renaming) { pinned in
            VStack(alignment: .leading, spacing: 12) {
                Text("Gespeicherte Suche umbenennen").font(.headline)
                TextField("Name", text: $renameText).onSubmit { commitRename(pinned) }
                HStack {
                    Spacer()
                    Button("Abbrechen") { renaming = nil }.keyboardShortcut(.cancelAction)
                    Button("Sichern") { commitRename(pinned) }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 340)
        }
    }

    private func commitRename(_ pinned: PinnedSearch) {
        model.library.rename(pinned.id, to: renameText)
        renaming = nil
    }

    // MARK: Library

    @ViewBuilder
    private var librarySection: some View {
        Section {
            ScopeRow(title: "Alle Produkte", systemImage: "cart", count: model.scope == .all ? model.result.ids.count : nil,
                     badge: 0, isSelected: model.scope == .all) { model.show(.all) }
            ScopeRow(title: "Merkliste", systemImage: "star.fill", count: model.library.watchlist.count,
                     badge: model.watchlistChanged, isSelected: model.scope == .watchlist) { model.show(.watchlist) }
            ForEach(model.library.pinned) { pinned in
                let stats = model.pinnedStats[pinned.id]
                ScopeRow(title: pinned.name, systemImage: "pin.fill", count: stats?.total,
                         badge: stats?.changed ?? 0, isSelected: model.scope == .pinned(pinned.id)) {
                    model.show(.pinned(pinned.id))
                }
                .contextMenu {
                    Button("Umbenennen …") { renameText = pinned.name; renaming = pinned }
                    Button("Entfernen", role: .destructive) {
                        model.library.remove(pinned.id)
                        if model.scope == .pinned(pinned.id) { model.show(.all) }
                    }
                }
            }
            .onMove { model.library.movePinned(from: $0, to: $1) }
        } header: {
            HStack {
                Text("Bibliothek")
                Spacer()
                Button {
                    model.pinCurrentSearch()
                } label: {
                    Image(systemName: "pin")
                }
                .buttonStyle(.borderless)
                .help("Aktuelle Suche anpinnen (⇧⌘D)")
            }
        }
    }

    // MARK: Categories

    @ViewBuilder
    private func categoryRow(_ category: ProductCategory, result: SearchResult) -> some View {
        let codes = category.subcategories.indices.map { ProductCategory.code(category.index, $0) }
        let selected = codes.filter { model.filters.categories.contains($0) }.count
        let count = result.mainCategoryCounts[category.index]
        if count > 0 || selected > 0 {
            DisclosureGroup(isExpanded: Binding(
                get: { expandedCategories.contains(category.index) },
                set: { if $0 { expandedCategories.insert(category.index) } else { expandedCategories.remove(category.index) } }
            )) {
                ForEach(Array(category.subcategories.enumerated()), id: \.offset) { offset, name in
                    let code = ProductCategory.code(category.index, offset)
                    let n = result.subCategoryCounts[Int(code)]
                    if n > 0 || model.filters.categories.contains(code) {
                        CheckRow(title: name, count: n, state: model.filters.categories.contains(code) ? .on : .off) {
                            if model.filters.categories.contains(code) {
                                model.filters.categories.remove(code)
                            } else {
                                model.filters.categories.insert(code)
                            }
                        }
                    }
                }
            } label: {
                CheckRow(title: category.name, count: count,
                         state: selected == 0 ? .off : (selected == codes.count ? .on : .mixed)) {
                    if selected == codes.count {
                        model.filters.categories.subtract(codes)
                    } else {
                        model.filters.categories.formUnion(codes)
                    }
                }
            }
        }
    }
}

// MARK: - Rows

private struct ScopeRow: View {
    let title: String
    let systemImage: String
    let count: Int?
    let badge: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 16)
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                if badge > 0 {
                    Text("\(badge) neu")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                        .help("Preisänderungen seit dem letzten Öffnen")
                }
                if let count {
                    Text(Fmt.count(count)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .fontWeight(isSelected ? .semibold : .regular)
        }
        .buttonStyle(.plain)
    }
}

private struct StoreRow: View {
    let store: Store
    let isOn: Bool
    let count: Int
    let summary: Catalog.FeedSummary?
    let toggle: (_ only: Bool) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isOn ? "checkmark.square.fill" : "square")
                .foregroundStyle(isOn ? Color.accentColor : .secondary)
            StoreBadge(store: store, compact: true)
                .opacity(isOn ? 1 : 0.5)
            Spacer(minLength: 4)
            if let latest = summary?.latestDay, DayMath.today - latest > 7 {
                Text("Stand \(Fmt.date(latest))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("Der Datenfeed dieses Händlers wurde zuletzt am \(Fmt.longDate(latest)) aktualisiert.")
            } else if summary == nil || summary?.productCount == 0 {
                Text("keine Daten").font(.caption2).foregroundStyle(.tertiary)
            }
            Text(Fmt.count(count))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle(NSEvent.modifierFlags.contains(.option)) }
        .help("Klicken zum Umschalten, ⌥-Klick: nur \(store.displayName)")
        .contextMenu {
            Button("Nur \(store.displayName)") { toggle(true) }
        }
    }
}

private struct CheckRow: View {
    enum State { case on, off, mixed }
    let title: String
    let count: Int
    let state: State
    let action: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: state == .on ? "checkmark.square.fill" : state == .mixed ? "minus.square.fill" : "square")
                .foregroundStyle(state == .off ? Color.secondary : Color.accentColor)
            Text(title).lineLimit(1)
            Spacer(minLength: 4)
            Text(Fmt.count(count)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

private struct RangeFields: View {
    let label: String
    @Binding var min: Double?
    @Binding var max: Double?

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                TextField("min", value: $min, format: .number.locale(Fmt.locale))
                Text("–").foregroundStyle(.secondary)
                TextField("max", value: $max, format: .number.locale(Fmt.locale))
            }
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 130)
        }
    }
}
