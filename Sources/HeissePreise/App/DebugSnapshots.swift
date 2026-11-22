import AppKit
import PriceCore

/// Development aid: `open HeissePreise.app --args -HPSnapshotDir /some/dir` drives a short scripted
/// session and writes PNGs of the app's own window (no screen-recording permission needed).
@MainActor
enum DebugSnapshots {
    static func runIfRequested(model: AppModel) {
        guard let dir = UserDefaults.standard.string(forKey: "HPSnapshotDir")
            ?? ProcessInfo.processInfo.environment["HP_SNAPSHOT_DIR"] else { return }
        Task { @MainActor in
            for _ in 0..<150 where model.phase != .ready {
                try? "phase=\(model.phase) products=\(model.catalog.count) windows=\(NSApp.windows.count)".write(toFile: dir + "/status.txt", atomically: true, encoding: .utf8)
                try? await Task.sleep(for: .milliseconds(200))
            }
            try? await Task.sleep(for: .seconds(1.5))
            capture("1-start", dir)
            model.searchText = "vollmilch"
            try? await Task.sleep(for: .milliseconds(600))
            model.moveSelection(by: 1)
            model.openDetail()
            try? await Task.sleep(for: .seconds(1.5))
            capture("2-search-detail", dir)
            model.searchText = "kaffee bohnen"
            model.filters.trend = .reduced
            model.sort = ResultOrder(key: .changePercent, ascending: true)
            try? await Task.sleep(for: .seconds(1.5))
            capture("3-filters", dir)
            let log = """
            products=\(model.catalog.count) results=\(model.result.ids.count) \
            searchMs=\(Double(model.result.duration.components.attoseconds) / 1e15) \
            selection=\(model.selectedProduct?.name ?? "-")
            """
            try? log.write(toFile: dir + "/log.txt", atomically: true, encoding: .utf8)
            model.filters = FilterState()
            model.searchText = ""
        }
    }

    private static func capture(_ name: String, _ dir: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }
}
