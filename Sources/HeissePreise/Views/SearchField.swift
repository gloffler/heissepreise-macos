import AppKit
import SwiftUI

/// Native search field that keeps focus while ↑/↓/Enter/Esc drive the result list,
/// like Raycast or Spotlight.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var focusToken: Int
    var placeholder: String
    var onMove: (Int) -> Void
    var onEdge: (Bool) -> Void
    var onSubmit: () -> Void
    var onEscape: () -> Void

    func makeNSView(context: Context) -> AutoFocusSearchField {
        let field = AutoFocusSearchField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.recentsAutosaveName = nil
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 17)
        field.controlSize = .large
        field.bezelStyle = .roundedBezel
        (field.cell as? NSSearchFieldCell)?.cancelButtonCell?.target = context.coordinator
        (field.cell as? NSSearchFieldCell)?.cancelButtonCell?.action = #selector(Coordinator.clear)
        return field
    }

    func updateNSView(_ field: AutoFocusSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
                field.currentEditor()?.selectAll(nil)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchField
        var focusToken: Int

        init(parent: SearchField) {
            self.parent = parent
            self.focusToken = parent.focusToken
        }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        @objc func clear() {
            parent.text = ""
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)): parent.onMove(-20)
            case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)): parent.onMove(20)
            case #selector(NSResponder.moveToBeginningOfDocument(_:)), #selector(NSResponder.scrollToBeginningOfDocument(_:)): parent.onEdge(true)
            case #selector(NSResponder.moveToEndOfDocument(_:)), #selector(NSResponder.scrollToEndOfDocument(_:)): parent.onEdge(false)
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)): parent.onEscape()
            default: return false
            }
            return true
        }
    }
}

/// Grabs keyboard focus as soon as it appears in a window.
final class AutoFocusSearchField: NSSearchField {
    private var didAutoFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !didAutoFocus, let window else { return }
        didAutoFocus = true
        DispatchQueue.main.async { window.makeFirstResponder(self) }
    }
}
