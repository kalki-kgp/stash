import AppKit
import Combine

/// The panel's state: one page of lightweight rows, the search text and the keyboard selection.
final class History: ObservableObject {
    let store: Store
    @Published var query = "" { didSet { pageSize = Self.page; reload() } }
    @Published private(set) var rows: [Row] = []
    @Published var selection: Int64?
    /// Bumped only by keyboard moves, so hovering a row never scrolls the list under the pointer.
    @Published private(set) var keyboardMoves = 0
    var onPick: (() -> Void)?
    var skipCapture: (() -> Void)?

    private static let page = 60
    private var pageSize = page
    let thumbs = NSCache<NSString, NSImage>()
    private var icons: [String: NSImage] = [:]

    init(store: Store) {
        self.store = store
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

    /// Called when the panel closes: drop everything that only mattered while it was on screen.
    func release() {
        thumbs.removeAllObjects()
        icons.removeAll()
        if !query.isEmpty { query = "" }
        pageSize = Self.page
        rows = []
    }

    func pick(_ row: Row) {
        guard let content = store.content(row.id) else { return }
        Paste.write(content)
        skipCapture?()
        store.touch(row.id)
        onPick?()
    }

    func pickSelected() {
        if let row = rows.first(where: { $0.id == selection }) { pick(row) }
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
    }

    func delete(_ row: Row) {
        let index = rows.firstIndex { $0.id == row.id } ?? 0
        store.delete(row.id)
        reload()
        if !rows.isEmpty { selection = rows[min(index, rows.count - 1)].id }
    }

    func clear() {
        store.clearUnpinned()
        reload()
    }

    func thumbnail(_ hash: String) -> NSImage? {
        if let cached = thumbs.object(forKey: hash as NSString) { return cached }
        guard let image = NSImage(contentsOf: Store.thumbURL(hash)) else { return nil }
        thumbs.setObject(image, forKey: hash as NSString)
        return image
    }

    func icon(for bundleID: String) -> NSImage? {
        if let cached = icons[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        icons[bundleID] = icon
        return icon
    }
}
