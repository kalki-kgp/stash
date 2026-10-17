#if STASH_TEST
import AppKit

/// Test builds only (`./build.sh test`): lets the test script drive the real panel through
/// distributed notifications and read its state back as JSON.
enum TestHook {
    private static var token: NSObjectProtocol?

    static func install(app: AppDelegate, history: History, watcher: Watcher) {
        token = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("dev.kalki.stash.test"), object: nil, queue: .main
        ) { [weak app, weak history] note in
            guard let app, let history, let command = note.object as? String else { return }
            let parts = command.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            let window = app.panelWindow
            switch parts[0] {
            case "open": app.showPanel(atCursor: parts.count > 1 && parts[1] == "cursor")
            case "close": app.hidePanel()
            case "key":
                // key:<keyCode>:<modifier flags raw value>:<characters>
                let flags = NSEvent.ModifierFlags(rawValue: UInt(parts.count > 2 ? parts[2] : "0") ?? 0)
                let chars = parts.count > 3 ? parts[3].replacingOccurrences(of: "ESC", with: "\u{1b}") : ""
                if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                                windowNumber: window.windowNumber, context: nil, characters: chars,
                                                charactersIgnoringModifiers: chars, isARepeat: false,
                                                keyCode: UInt16(parts[1]) ?? 0) {
                    window.sendEvent(event)
                }
            case "type":
                for ch in parts.dropFirst().joined(separator: ":") {
                    if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, characters: String(ch),
                                                    charactersIgnoringModifiers: String(ch), isARepeat: false, keyCode: 0) {
                        window.sendEvent(event)
                    }
                }
            case "hotkey": app.togglePanelForTest()
            case "hover": history.hoverArmed = true
            case "pause": watcher.isPaused = parts[1] == "1"
            case "ignorenext": watcher.ignoreNext = true
            case "dump":
                let selected = history.rows.firstIndex { $0.id == history.selection }
                let state: [String: Any] = [
                    "visible": app.isPanelVisible,
                    "key": window.isKeyWindow,
                    "query": history.query,
                    "rows": history.rows.prefix(12).map { ["preview": $0.preview, "kind": $0.kind.rawValue, "pinned": $0.pinned] },
                    "rowCount": history.rows.count,
                    "selected": selected ?? -1,
                    "hotKey": app.hotKeyRegistered,
                    "openMs": app.lastOpenMs,
                ]
                if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: parts[1]))
                }
            default: break
            }
        }
    }
}
#endif
