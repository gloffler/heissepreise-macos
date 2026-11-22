import Foundation

/// Summary statistics of a product's price history for the inspector.
public struct PriceStats: Sendable {
    public var current: PricePoint
    public var lowest: PricePoint
    public var highest: PricePoint
    /// Time-weighted average over the whole recorded period (each price weighted by how long it was valid).
    public var timeWeightedAverage: Double
    public var first: PricePoint
    public var changes: Int
    /// Chronological points (oldest first) plus a synthetic point for `today`, ready for a step chart.
    public var series: [PricePoint]

    public init?(history: ArraySlice<PricePoint>, today: Day) {
        guard let newest = history.first, let oldest = history.last else { return nil }
        let chronological = Array(history.reversed())
        current = newest
        first = oldest
        changes = history.count - 1
        // Most recent occurrence of the extreme prices.
        lowest = history.min { $0.cents < $1.cents || ($0.cents == $1.cents && $0.day > $1.day) }!
        highest = history.max { $0.cents < $1.cents || ($0.cents == $1.cents && $0.day < $1.day) }!

        let end = max(today, newest.day)
        var weighted = 0.0
        var days = 0.0
        for (i, point) in chronological.enumerated() {
            let until = i + 1 < chronological.count ? chronological[i + 1].day : end
            let span = Double(max(until - point.day, 1))
            weighted += Double(point.cents) * span
            days += span
        }
        timeWeightedAverage = days > 0 ? weighted / days / 100 : newest.euros

        series = chronological
        if end > newest.day { series.append(PricePoint(day: end, cents: newest.cents)) }
    }
}
