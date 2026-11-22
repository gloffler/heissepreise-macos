import Charts
import PriceCore
import SwiftUI

/// Right-hand detail pane: product facts, price statistics and the history chart.
struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let product = model.selectedProduct {
            ProductDetail(product: product, history: model.catalog.history(of: product))
                .id(product.id)
        } else {
            ContentUnavailableView("Kein Produkt ausgewählt", systemImage: "cart",
                                   description: Text("Wähle ein Produkt mit ↑/↓ und drücke ↩︎."))
        }
    }
}

private struct ProductDetail: View {
    @Environment(AppModel.self) private var model
    let product: Product
    let history: ArraySlice<PricePoint>

    var body: some View {
        let stats = PriceStats(history: history, today: DayMath.today)
        let names = ProductCategory.names(for: product.categoryCode)
        let watched = model.library.isWatched(product.key)

        InspectorScroll {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        StoreBadge(store: product.store)
                        if product.isBio { Tag(text: "BIO", color: .green) }
                        if product.isBudget { Tag(text: "EIGENMARKE", color: .orange) }
                        if product.isAllTimeLow { Tag(text: "TIEFSTPREIS", color: .teal) }
                        if product.isUnavailable { Tag(text: "NICHT VERFÜGBAR", color: .gray) }
                    }
                    Text(product.name)
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(names.main) › \(names.sub)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                // Price block
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(Fmt.euro(cents: product.cents))
                        .font(.system(size: 32, weight: .bold, design: .rounded).monospacedDigit())
                    if product.historyCount > 1 && product.changeCents != 0 {
                        Text("\(Fmt.change(product))  \(Fmt.changePercent(product))")
                            .font(.callout.monospacedDigit().weight(.medium))
                            .foregroundStyle(product.changeCents > 0 ? .red : .green)
                    }
                    Spacer()
                }
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    Fact("Grundpreis", Fmt.unitPrice(product), emphasized: true)
                    Fact("Menge", Fmt.quantity(product) + (product.flags.contains(.weighted) ? " (gewogen)" : ""))
                    Fact("Letzte Änderung", Fmt.longDate(product.lastChange))
                    Fact("Vorheriger Preis", product.historyCount > 1 ? Fmt.euro(cents: product.previousCents) : "–")
                    Fact("Artikel-ID", product.storeID, monospaced: true)
                }

                Divider()

                if let stats {
                    PriceChart(stats: stats)

                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                        Fact("Allzeittief", "\(Fmt.euro(cents: stats.lowest.cents))  ·  \(Fmt.date(stats.lowest.day))", color: .green)
                        Fact("Allzeithoch", "\(Fmt.euro(cents: stats.highest.cents))  ·  \(Fmt.date(stats.highest.day))", color: .red)
                        Fact("Ø zeitgewichtet", Fmt.euro(stats.timeWeightedAverage))
                        Fact("Aktuell vs. Tief", stats.lowest.cents > 0
                             ? "+" + Fmt.number((Double(product.cents - stats.lowest.cents) / Double(stats.lowest.cents) * 1000).rounded() / 10) + " %"
                             : "–")
                        Fact("Preisänderungen", "\(stats.changes) seit \(Fmt.date(stats.first.day))")
                    }
                }

                Divider()

                // Actions
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button {
                            model.openInShop(product)
                        } label: {
                            Label("Im Shop öffnen", systemImage: "safari")
                        }
                        .disabled(product.productURL == nil)
                        Button {
                            model.searchInShop(product)
                        } label: {
                            Label("Im Shop suchen", systemImage: "magnifyingglass")
                        }
                    }
                    HStack {
                        Button {
                            model.copySelected()
                        } label: {
                            Label("Kopieren", systemImage: "doc.on.doc")
                        }
                        .help("Produktname + Preis kopieren (⌘C)")
                        Button {
                            model.library.toggleWatch(product)
                        } label: {
                            Label(watched ? "Gemerkt" : "Merken", systemImage: watched ? "star.fill" : "star")
                        }
                        .help("Zur Merkliste (⌘D)")
                    }
                }
                .controlSize(.regular)
            }
            .padding(16)
        }
    }
}

private struct Fact: View {
    let label: String
    let value: String
    var emphasized = false
    var monospaced = false
    var color: Color?

    init(_ label: String, _ value: String, emphasized: Bool = false, monospaced: Bool = false, color: Color? = nil) {
        self.label = label
        self.value = value
        self.emphasized = emphasized
        self.monospaced = monospaced
        self.color = color
    }

    var body: some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .body.monospaced() : .body.monospacedDigit())
                .fontWeight(emphasized ? .semibold : .regular)
                .foregroundStyle(color ?? .primary)
                .textSelection(.enabled)
        }
        .font(.callout)
    }
}

private struct Tag: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Chart

/// Step-line price history with min/max/average rules and a hover tooltip.
struct PriceChart: View {
    let stats: PriceStats
    @ViewState private var range: Range = .all
    @ViewState private var hovered: PricePoint?

    enum Range: String, CaseIterable, Identifiable {
        case threeMonths = "3M", year = "1J", threeYears = "3J", all = "Alles"
        var id: String { rawValue }
        var days: Day? {
            switch self {
            case .threeMonths: 92
            case .year: 366
            case .threeYears: 1096
            case .all: nil
            }
        }
    }

    /// Visible series: clipped to the range, with the price valid at the range start carried in.
    private var visible: [PricePoint] {
        guard let days = range.days, let last = stats.series.last else { return stats.series }
        let start = last.day - days
        var points = stats.series.filter { $0.day >= start }
        if let carried = stats.series.last(where: { $0.day < start }) {
            points.insert(PricePoint(day: start, cents: carried.cents), at: 0)
        }
        return points.count >= 2 ? points : stats.series
    }

    var body: some View {
        let points = visible
        let low = Double(points.map(\.cents).min() ?? 0) / 100
        let high = Double(points.map(\.cents).max() ?? 0) / 100
        let padding = max((high - low) * 0.15, 0.1)

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Preisverlauf").font(.headline)
                Spacer()
                Picker("Zeitraum", selection: $range) {
                    ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            Chart {
                ForEach(points, id: \.day) { point in
                    AreaMark(x: .value("Datum", point.date), yStart: .value("Basis", low - padding), yEnd: .value("Preis", point.euros))
                        .interpolationMethod(.stepEnd)
                        .foregroundStyle(.linearGradient(colors: [Color.accentColor.opacity(0.25), Color.accentColor.opacity(0.02)],
                                                         startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Datum", point.date), y: .value("Preis", point.euros))
                        .interpolationMethod(.stepEnd)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .foregroundStyle(Color.accentColor)
                }
                RuleMark(y: .value("Allzeittief", stats.lowest.euros))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(.green.opacity(0.7))
                    .annotation(position: .bottom, alignment: .leading) {
                        Text("Tief \(Fmt.euro(cents: stats.lowest.cents))").font(.caption2).foregroundStyle(.green)
                    }
                RuleMark(y: .value("Allzeithoch", stats.highest.euros))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(.red.opacity(0.7))
                    .annotation(position: .top, alignment: .leading) {
                        Text("Hoch \(Fmt.euro(cents: stats.highest.cents))").font(.caption2).foregroundStyle(.red)
                    }
                RuleMark(y: .value("Durchschnitt", stats.timeWeightedAverage))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [1, 3]))
                    .foregroundStyle(.secondary)
                    .annotation(position: .top, alignment: .trailing) {
                        Text("Ø \(Fmt.euro(stats.timeWeightedAverage))").font(.caption2).foregroundStyle(.secondary)
                    }

                if let hovered {
                    RuleMark(x: .value("Datum", hovered.date))
                        .foregroundStyle(.secondary.opacity(0.6))
                        .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            VStack(spacing: 1) {
                                Text(Fmt.euro(cents: hovered.cents)).font(.callout.weight(.semibold).monospacedDigit())
                                Text(Fmt.longDate(hovered.day)).font(.caption2).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                            .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                        }
                    PointMark(x: .value("Datum", hovered.date), y: .value("Preis", hovered.euros))
                        .symbolSize(40)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .chartYScale(domain: (low - padding)...(high + padding))
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text(Fmt.euro(v)).font(.caption2) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.abbreviated).year(.twoDigits))
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard let plot = proxy.plotFrame else { return }
                                let x = location.x - geometry[plot].origin.x
                                guard let date: Date = proxy.value(atX: x) else { return }
                                let day = DayMath.day(of: date)
                                // Price in effect on the hovered day (step semantics).
                                if let point = points.last(where: { $0.day <= day }) ?? points.first {
                                    hovered = PricePoint(day: min(max(day, points.first!.day), points.last!.day), cents: point.cents)
                                }
                            case .ended:
                                hovered = nil
                            }
                        }
                }
            }
            .frame(height: 220)
        }
    }
}

/// Scroll container for the inspector.
///
/// A SwiftUI `ScrollView` inside `.inspector` swallows every click (observed on macOS 27): buttons and the
/// range picker never fire. A plain `List` scrolls the same content and passes clicks through.
private struct InspectorScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        List {
            content
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}
