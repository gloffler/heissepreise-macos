import AppKit
import PriceCore
import SwiftUI

@main
struct HeissePreiseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ViewState private var model = AppModel()

    var body: some Scene {
        Window("Heiße Preise", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 560)
        }
        .defaultSize(width: 1440, height: 860)
        .commands { AppCommands(model: model) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Also behave like a proper app when started as a bare executable (`swift run`).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        // The standard Find items would shadow ⌘F.
        CommandGroup(replacing: .textEditing) {}

        CommandMenu("Suche") {
            Button("Suchen") { model.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
            Button("Schnellsuche") { model.focusSearch() }
                .keyboardShortcut("k", modifiers: .command)
            Divider()
            Button("Daten aktualisieren") { Task { await model.refresh(force: false) } }
                .keyboardShortcut("r", modifiers: .command)
            Button("Alle Daten neu laden") { Task { await model.refresh(force: true) } }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Divider()
            Button("Suche anpinnen") { model.pinCurrentSearch() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Alle Produkte") { model.show(.all) }
                .keyboardShortcut("0", modifiers: .command)
            Button("Merkliste") { model.show(.watchlist) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Filter zurücksetzen") { model.filters = FilterState() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Menu("Sortieren nach") {
                ForEach(Array(SortKey.allCases.enumerated()), id: \.element) { index, key in
                    Button(key.title) { model.setSort(key) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command, .control])
                }
            }
        }

        CommandMenu("Produkt") {
            Button("Details anzeigen") { model.openDetail() }
                .keyboardShortcut("i", modifiers: .command)
            Button("Im Shop öffnen") { model.openInShop() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Im Shop suchen") { model.searchInShop() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Name + Preis kopieren") { model.copySelected() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Divider()
            Button("Merken / Entfernen") { model.toggleWatchSelected() }
                .keyboardShortcut("d", modifiers: .command)
        }
    }
}
