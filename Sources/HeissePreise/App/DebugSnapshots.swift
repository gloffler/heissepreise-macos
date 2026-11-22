import AppKit
import PriceCore

/// Development aid: `open HeissePreise.app --args -HPSnapshotDir /some/dir` drives a short scripted
/// session and writes PNGs of the app's own window (no screen-recording permission needed).
/// Add `-HPClicks "x,y;x,y"` to inject clicks (window points, top-left origin) after the detail opens.
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
            // `-HPClicks "x,y;x,y"`: synthetic clicks in window coordinates (top-left origin).
            let clicks = (UserDefaults.standard.string(forKey: "HPClicks") ?? "").split(separator: ";")
            for (i, pair) in clicks.enumerated() {
                let xy = pair.split(separator: ",").compactMap { Double($0) }
                guard xy.count == 2 else { continue }
                click(at: NSPoint(x: xy[0], y: xy[1]))
                try? await Task.sleep(for: .seconds(1))
                capture("click-\(i + 1)", dir)
            }
            model.searchText = "kaffee bohnen"
            model.filters.trend = .reduced
            model.sort = ResultOrder(key: .changePercent, ascending: true)
            try? await Task.sleep(for: .seconds(1.5))
            capture("3-filters", dir)
            model.searchText = "zzqxv"
            try? await Task.sleep(for: .seconds(1))
            capture("4-empty", dir)
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

    private static func click(at topLeft: NSPoint) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
        let location = NSPoint(x: topLeft.x, y: window.frame.height - topLeft.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                // Queue the events like real input, so tracking loops (scroll views) see the mouse-up.
                NSApp.postEvent(event, atStart: false)
            }
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
