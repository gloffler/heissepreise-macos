import AppKit
import PriceCore
import SwiftUI

/// Result list backed by a view-based `NSTableView`.
///
/// A SwiftUI `Table` diffs the identity of every row on each update, which costs tens of
/// milliseconds at 160 000 rows. `NSTableView` only asks for the ~40 visible rows, so a new
/// result set is a single `reloadData()` – constant time regardless of the result size.
struct ProductTable: NSViewRepresentable {
    let catalog: Catalog
    let ids: [Int32]
    let generation: Int
    let selection: Int32?
    let selectionGeneration: Int
    let sort: ResultOrder
    let watched: Set<ProductKey>
    var onSelect: (Int32?) -> Void
    var onActivate: () -> Void
    var onEscape: () -> Void
    var onSort: (ResultOrder) -> Void
    var onType: (String) -> Void
    var onToggleWatch: (Product) -> Void
    var onOpenShop: (Product) -> Void
    var onCopy: () -> Void

    enum Column: String, CaseIterable {
        case store, name, quantity, unitPrice, price, change, changePercent, lastChange

        var title: String {
            switch self {
            case .store: "Händler"
            case .name: "Produkt"
            case .quantity: "Menge"
            case .unitPrice: "Grundpreis"
            case .price: "Preis"
            case .change: "Δ €"
            case .changePercent: "Δ %"
            case .lastChange: "Geändert"
            }
        }

        var width: (min: CGFloat, ideal: CGFloat, max: CGFloat) {
            switch self {
            case .store: (54, 72, 100)
            case .name: (160, 380, 2000)
            case .quantity: (50, 72, 140)
            case .unitPrice: (70, 98, 160)
            case .price: (56, 74, 120)
            case .change: (56, 72, 120)
            case .changePercent: (48, 62, 100)
            case .lastChange: (60, 74, 120)
            }
        }

        var alignment: NSTextAlignment {
            switch self {
            case .store, .name: .left
            default: .right
            }
        }

        var sortKey: SortKey { SortKey(rawValue: rawValue)! }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = KeyTableView()
        table.coordinator = context.coordinator
        table.style = .fullWidth
        table.rowHeight = 24
        table.intercellSpacing = NSSize(width: 8, height: 0)
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.headerView = NSTableHeaderView()
        table.focusRingType = .none
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked)
        table.menu = context.coordinator.makeMenu()

        for column in Column.allCases {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            c.title = column.title
            c.minWidth = column.width.min
            c.width = column.width.ideal
            c.maxWidth = column.width.max
            c.headerCell.alignment = column.alignment
            c.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: column != .lastChange)
            c.resizingMask = column == .name ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            table.addTableColumn(c)
        }
        // Persist column widths/order; the sort order belongs to the model, so drop any restored one
        // before the delegate is attached (otherwise it would fire sortDescriptorsDidChange).
        table.autosaveName = "ProductTable.v1"
        table.autosaveTableColumns = true
        table.sortDescriptors = []
        table.delegate = context.coordinator
        table.dataSource = context.coordinator

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let table = c.table else { return }

        var reloaded = false
        if c.generation != generation || c.catalog !== catalog {
            c.generation = generation
            c.catalog = catalog
            c.ids = ids
            table.reloadData()
            reloaded = true
        } else if c.watched != watched {
            c.watched = watched
            let visible = table.rows(in: table.visibleRect)
            table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
                             columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        }
        c.watched = watched

        // Mirror the sort order in the header without triggering a feedback loop.
        let descriptor = NSSortDescriptor(key: sort.key.rawValue, ascending: sort.ascending)
        if table.sortDescriptors.first?.key != descriptor.key || table.sortDescriptors.first?.ascending != descriptor.ascending {
            c.isUpdating = true
            table.sortDescriptors = sort.key == .relevance ? [] : [descriptor]
            c.isUpdating = false
        }

        if reloaded || c.selectionGeneration != selectionGeneration {
            c.selectionGeneration = selectionGeneration
            c.isUpdating = true
            if let selection, let row = ids.firstIndex(of: selection) {
                if table.selectedRow != row { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
                table.scrollRowToVisible(row)
            } else {
                table.deselectAll(nil)
                if reloaded { table.scrollRowToVisible(0) }
            }
            c.isUpdating = false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: ProductTable
        weak var table: KeyTableView?
        var catalog: Catalog = .empty
        var ids: [Int32] = []
        var watched: Set<ProductKey> = []
        var generation = -1
        var selectionGeneration = -1
        var isUpdating = false

        init(parent: ProductTable) {
            self.parent = parent
        }

        func numberOfRows(in tableView: NSTableView) -> Int { ids.count }

        func product(at row: Int) -> Product? {
            guard row >= 0, row < ids.count else { return nil }
            return catalog[ids[row]]
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue),
                  let p = product(at: row) else { return nil }

            if column == .store {
                let id = NSUserInterfaceItemIdentifier("badge")
                let cell = tableView.makeView(withIdentifier: id, owner: nil) as? BadgeCell ?? BadgeCell(identifier: id)
                cell.store = p.store
                cell.dimmed = p.isUnavailable
                return cell
            }

            let id = NSUserInterfaceItemIdentifier("text-\(column.alignment.rawValue)")
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? TextCell ?? TextCell(identifier: id, alignment: column.alignment)
            let primary: NSColor = p.isUnavailable ? .tertiaryLabelColor : .labelColor
            cell.field.textColor = primary
            cell.field.font = column == .name ? .systemFont(ofSize: 13) : .monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)

            switch column {
            case .store:
                break
            case .name:
                cell.field.attributedStringValue = nameString(p, color: primary)
                cell.toolTip = p.name
            case .quantity:
                cell.field.stringValue = Fmt.quantity(p)
                cell.field.textColor = p.isUnavailable ? .tertiaryLabelColor : .secondaryLabelColor
            case .unitPrice:
                cell.field.stringValue = Fmt.unitPrice(p)
                cell.field.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
            case .price:
                cell.field.stringValue = Fmt.euro(cents: p.cents)
            case .change:
                cell.field.stringValue = Fmt.change(p)
                cell.field.textColor = p.isUnavailable ? .tertiaryLabelColor : Fmt.changeColor(p)
            case .changePercent:
                cell.field.stringValue = Fmt.changePercent(p)
                cell.field.textColor = p.isUnavailable ? .tertiaryLabelColor : Fmt.changeColor(p)
            case .lastChange:
                cell.field.stringValue = Fmt.date(p.lastChange)
                cell.field.textColor = .secondaryLabelColor
            }
            return cell
        }

        private func nameString(_ p: Product, color: NSColor) -> NSAttributedString {
            let s = NSMutableAttributedString()
            let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold)]
            if watched.contains(p.key) {
                s.append(NSAttributedString(string: "★ ", attributes: [.foregroundColor: NSColor.systemYellow, .font: NSFont.systemFont(ofSize: 12)]))
            }
            s.append(NSAttributedString(string: p.name, attributes: [.foregroundColor: color, .font: NSFont.systemFont(ofSize: 13)]))
            func tag(_ text: String, _ tagColor: NSColor) {
                var attributes = small
                attributes[.foregroundColor] = tagColor
                s.append(NSAttributedString(string: "  " + text, attributes: attributes))
            }
            if p.isBio { tag("BIO", .systemGreen) }
            if p.isBudget { tag("EIGENMARKE", .systemOrange) }
            if p.isAllTimeLow { tag("TIEFSTPREIS", .systemTeal) }
            // Single line, truncated – attributed strings ignore the field's own line break mode.
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            s.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: s.length))
            return s
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdating, let table else { return }
            let row = table.selectedRow
            parent.onSelect(row >= 0 && row < ids.count ? ids[row] : nil)
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isUpdating, let d = tableView.sortDescriptors.first, let key = d.key.flatMap(SortKey.init(rawValue:)) else { return }
            parent.onSort(ResultOrder(key: key, ascending: d.ascending))
        }

        @objc func doubleClicked() {
            guard let table, table.clickedRow >= 0 else { return }
            parent.onSelect(ids[table.clickedRow])
            parent.onActivate()
        }

        // MARK: Context menu

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.delegate = self
            return menu
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table, let p = product(at: table.clickedRow) else { return }
            parent.onSelect(p.id)
            func item(_ title: String, _ symbol: String, _ action: @escaping () -> Void) {
                let i = ClosureMenuItem(title: title, action: action)
                i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                menu.addItem(i)
            }
            item("Details anzeigen", "sidebar.right") { [parent] in parent.onActivate() }
            item("Im Shop öffnen", "safari") { [parent] in parent.onOpenShop(p) }
            item("Produkt kopieren", "doc.on.doc") { [parent] in parent.onCopy() }
            menu.addItem(.separator())
            item(watched.contains(p.key) ? "Von Merkliste entfernen" : "Zur Merkliste", "star") { [parent] in parent.onToggleWatch(p) }
        }
    }
}

// MARK: - AppKit pieces

/// Table that hands Return/Esc to the model and forwards typing to the search field.
final class KeyTableView: NSTableView {
    weak var coordinator: ProductTable.Coordinator?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 36, 76: // Return, Enter
            coordinator?.parent.onActivate()
            return
        case 53: // Esc
            coordinator?.parent.onEscape()
            return
        default:
            break
        }
        if flags.isDisjoint(with: [.command, .control, .option]),
           let chars = event.characters, let scalar = chars.unicodeScalars.first,
           !CharacterSet.controlCharacters.contains(scalar), scalar.value < 0xF700 {
            coordinator?.parent.onType(chars)
            return
        }
        super.keyDown(with: event)
    }
}

final class TextCell: NSTableCellView {
    let field = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier, alignment: NSTextAlignment) {
        super.init(frame: .zero)
        self.identifier = identifier
        field.alignment = alignment
        field.lineBreakMode = .byTruncatingTail
        field.cell?.truncatesLastVisibleLine = true
        field.maximumNumberOfLines = 1
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// Draws the colour-coded store label directly (no subviews, no layout).
final class BadgeCell: NSView {
    var store: Store = .billa { didSet { if store != oldValue { needsDisplay = true } } }
    var dimmed = false { didSet { if dimmed != oldValue { needsDisplay = true } } }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let text = store.displayName as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: store.nsForeground,
        ]
        let size = text.size(withAttributes: attributes)
        let rect = NSRect(x: 2, y: (bounds.height - 16) / 2, width: min(size.width + 10, bounds.width - 4), height: 16)
        NSGraphicsContext.current?.saveGraphicsState()
        if dimmed { NSGraphicsContext.current?.cgContext.setAlpha(0.45) }
        store.nsBackground.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        text.draw(at: NSPoint(x: rect.minX + 5, y: rect.midY - size.height / 2), withAttributes: attributes)
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
