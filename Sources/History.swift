import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine

/// How a picked item leaves the panel: onto the clipboard, or onto it and pasted into the front app.
enum PickMode { case copy, paste, pastePlain }

/// The panel's state: one page of lightweight rows, the search text and the keyboard selection.
final class History: ObservableObject {
    let store: Store
    @Published var query = "" { didSet { pageSize = Self.page; reload() } }
    @Published private(set) var rows: [Row] = []
    @Published var selection: Int64?
    /// Bumped only by keyboard moves, so hovering a row never scrolls the list under the pointer.
    @Published private(set) var keyboardMoves = 0
    /// Hover only selects once the pointer has moved, so the row that happens to sit under it
    /// when the panel opens doesn't steal the selection from the first row.
    var hoverArmed = false
    var onPick: (() -> Void)?
    /// Called instead of pasting when Stash isn't allowed to send keystrokes yet.
    var needsPastePermission: (() -> Void)?
    var skipCapture: (() -> Void)?

    private static let page = 60
    private var pageSize = page
    let thumbs = NSCache<NSString, NSImage>()
    private var icons: [String: NSImage] = [:]

    init(store: Store) {
        self.store = store
        // A 120 px thumbnail decodes to about 40 KB, so this caps them near 1.5 MB.
        thumbs.countLimit = 40
    }

    func reload() {
        rows = store.rows(matching: query, limit: pageSize)
        if selection == nil || !rows.contains(where: { $0.id == selection }) { selection = rows.first?.id }
    }

    /// Loads the next page when the list scrolls near its end.
    func reachedEnd(of row: Row) {
        guard row.id == rows.last?.id, rows.count == pageSize else { return }
        pageSize += Self.page
        reload()
    }

    /// Called when the panel opens.
    func prepare() {
        selection = nil
        hoverArmed = false
        reload()
    }

    /// Called when the panel closes. Rows (plain structs), the small thumbnails and the app icons stay
    /// warm so the next open draws without rebuilding them; only extra pages and the search reset.
    func release() {
        if !query.isEmpty { query = "" }
        if pageSize != Self.page {
            pageSize = Self.page
            reload()
        }
    }

    private var selectedRow: Row? { rows.first { $0.id == selection } }

    func pick(_ row: Row, _ mode: PickMode = .copy) {
        guard var content = store.content(row.id) else { return }
        if mode == .pastePlain, content.kind == .text {
            content = Content(kind: .text, text: content.text, rtf: nil, html: nil, files: [], imageHash: nil)
        }
        Paste.write(content)
        skipCapture?()
        store.touch(row.id)
        onPick?()
        guard mode != .copy else { return }
        if AXIsProcessTrusted() { Self.pasteIntoFrontApp() } else { needsPastePermission?() }
    }

    /// The mode a click or ⌘/⌥ number asks for, from the modifiers held at that moment.
    static func mode(for flags: NSEvent.ModifierFlags) -> PickMode {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.option) else { return .copy }
        return flags.contains(.shift) ? .pastePlain : .paste
    }

    /// Sends ⌘V to whatever app is in front (needs Accessibility access; the item is on the clipboard either way).
    private static func pasteIntoFrontApp() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let source = CGEventSource(stateID: .combinedSessionState)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
                event?.flags = .maskCommand
                event?.post(tap: .cgSessionEventTap)
            }
        }
    }

    func moveSelection(_ step: Int) {
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.id == selection } ?? -1
        selection = rows[min(max(index + step, 0), rows.count - 1)].id
        keyboardMoves += 1
    }

    func togglePin(_ row: Row) {
        store.setPinned(row.id, !row.pinned)
        reload()
        selection = row.id
        keyboardMoves += 1
    }

    func delete(_ row: Row) {
        let index = rows.firstIndex { $0.id == row.id } ?? 0
        store.delete(row.id)
        reload()
        if !rows.isEmpty { selection = rows[min(index, rows.count - 1)].id }
    }

    func clear(includingPinned: Bool = false) {
        store.clear(includingPinned: includingPinned)
        reload()
    }

    /// Maccy's keys, read from key codes so ⌥1 arrives as 1 rather than ¡.
    /// Returns false for anything that should reach the search field.
    func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        switch Int(event.keyCode) {
        case kVK_UpArrow: moveSelection(-1); return true
        case kVK_DownArrow: moveSelection(1); return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let row = selectedRow { pick(row, Self.mode(for: flags)) }
            return true
        case kVK_Delete where flags == [.option]:
            if let row = selectedRow { delete(row) }
            return true
        case kVK_Delete where flags == [.option, .command]:
            clear()
            return true
        case kVK_Delete where flags == [.option, .command, .shift]:
            clear(includingPinned: true)
            return true
        case kVK_ANSI_P where flags == [.option]:
            if let row = selectedRow { togglePin(row) }
            return true
        default:
            guard let n = Self.digitCodes.firstIndex(of: Int(event.keyCode)),
                  flags == [.command] || flags == [.option] || flags == [.option, .shift] else { return false }
            if n < rows.count { pick(rows[n], Self.mode(for: flags)) }
            return true
        }
    }

    private static let digitCodes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                                     kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]

    func thumbnail(_ hash: String) -> NSImage? {
        if let cached = thumbs.object(forKey: hash as NSString) { return cached }
        guard let image = NSImage(contentsOf: Store.thumbURL(hash)) else { return nil }
        thumbs.setObject(image, forKey: hash as NSString)
        return image
    }

    func icon(for bundleID: String) -> NSImage? {
        if let cached = icons[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        // Workspace icons carry every resolution up to 1024 px; keep one 32 px bitmap instead.
        let source = NSWorkspace.shared.icon(forFile: url.path)
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0) {
            rep.size = icon.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            source.draw(in: NSRect(origin: .zero, size: icon.size))
            NSGraphicsContext.restoreGraphicsState()
            icon.addRepresentation(rep)
        }
        icons[bundleID] = icon
        return icon
    }
}
