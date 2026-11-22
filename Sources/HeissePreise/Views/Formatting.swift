import AppKit
import PriceCore
import SwiftUI

/// Shared, cached formatters (de-AT). Formatting happens only for visible rows.
@MainActor
enum Fmt {
    static let locale = Locale(identifier: "de_AT")

    private static let currency: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()

    private static let decimal: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        return f
    }()

    private static let integer: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = "dd.MM.yy"
        return f
    }()

    private static let longDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = locale
        f.dateStyle = .medium
        return f
    }()

    static func euro(_ value: Double) -> String { (currency.string(from: value as NSNumber) ?? "–") + " €" }
    static func euro(cents: Int32) -> String { euro(Double(cents) / 100) }
    static func count(_ n: Int) -> String { integer.string(from: n as NSNumber) ?? "\(n)" }
    static func number(_ value: Double) -> String { decimal.string(from: value as NSNumber) ?? "\(value)" }

    static func date(_ day: Day) -> String { day > 0 ? dateFormatter.string(from: DayMath.date(day)) : "–" }
    static func longDate(_ day: Day) -> String { day > 0 ? longDateFormatter.string(from: DayMath.date(day)) : "–" }

    private static let precise: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.minimumFractionDigits = 3
        f.maximumFractionDigits = 3
        return f
    }()

    static func unitPrice(_ p: Product) -> String {
        guard p.hasUnitPrice else { return "–" }
        // Sub-10-cent unit prices (per Stk, m, Waschgang) need a third decimal to be distinguishable.
        let value = p.unitPrice > 0 && p.unitPrice < 0.1
            ? (precise.string(from: p.unitPrice as NSNumber) ?? "–") + " €"
            : euro(p.unitPrice)
        return value + "/" + p.unit.baseLabel
    }

    static func quantity(_ p: Product) -> String {
        guard p.quantity > 0 else { return "–" }
        switch p.unit {
        case .gram: return p.quantity >= 1000 ? number(p.quantity / 1000) + " kg" : number(p.quantity) + " g"
        case .milliliter: return p.quantity >= 1000 ? number(p.quantity / 1000) + " L" : number(p.quantity) + " ml"
        case .piece, .unknown: return number(p.quantity) + " Stk"
        case .washLoads: return number(p.quantity) + " WG"
        case .centimeter: return p.quantity >= 100 ? number(p.quantity / 100) + " m" : number(p.quantity) + " cm"
        }
    }

    static func change(_ p: Product) -> String {
        guard p.historyCount > 1 else { return "–" }
        let c = p.changeCents
        if c == 0 { return "±0,00 €" }
        return (c > 0 ? "+" : "−") + euro(cents: abs(c))
    }

    static func changePercent(_ p: Product) -> String {
        guard p.historyCount > 1, p.previousCents > 0 else { return "–" }
        let v = p.changePercent
        if abs(v) < 0.05 { return "±0 %" }
        return (v > 0 ? "+" : "−") + number((abs(v) * 10).rounded() / 10) + " %"
    }

    static func changeColor(_ p: Product) -> NSColor {
        if p.historyCount < 2 || p.changeCents == 0 { return .secondaryLabelColor }
        return p.changeCents > 0 ? .systemRed : .systemGreen
    }

    static func clipboardLine(_ p: Product) -> String {
        var line = "\(p.name)"
        if p.quantity > 0 { line += " (\(quantity(p)))" }
        line += " – \(euro(cents: p.cents))"
        if p.hasUnitPrice { line += " (\(unitPrice(p)))" }
        line += " · \(p.store.displayName)"
        return line
    }

    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = locale
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

extension Store {
    var nsBackground: NSColor { NSColor(hex: badgeColors.background) }
    var nsForeground: NSColor { NSColor(hex: badgeColors.foreground) }
    var background: Color { Color(nsColor: nsBackground) }
    var foreground: Color { Color(nsColor: nsForeground) }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Compact colour-coded store label (SwiftUI).
struct StoreBadge: View {
    let store: Store
    var compact = false

    var body: some View {
        Text(store.displayName)
            .font(.system(size: compact ? 9.5 : 11, weight: .bold))
            .foregroundStyle(store.foreground)
            .padding(.horizontal, compact ? 5 : 7)
            .padding(.vertical, compact ? 1.5 : 2.5)
            .background(store.background, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .fixedSize()
    }
}

/// `@State` is declared as a macro in recent SDKs; its plugin ships only with Xcode.
/// Using the underlying property wrapper through an alias builds with the Command Line Tools too.
typealias ViewState<Value> = SwiftUI.State<Value>
