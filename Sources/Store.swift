import CryptoKit
import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum ItemKind: Int { case text = 0, image = 1, file = 2 }

/// What the list holds in memory: enough to draw a row, never the full content.
struct Row: Identifiable, Equatable {
    let id: Int64
    let kind: ItemKind
    let preview: String
    let imageHash: String?
    let imageSize: CGSize?
    let app: String?
    let lastAt: Date
    let pinned: Bool
}

/// A capture ready to be written: text and rich data already compressed, images already on disk.
struct NewItem {
    var kind: ItemKind
    var text: String?
    var rtf: Data?
    var html: Data?
    var files: [String] = []
    var imageHash: String?
    var imageSize: CGSize?
    var app: String?
    var firstAt = Date()
    var lastAt = Date()
    var copies = 1
    var pinned = false

    /// Identity for deduplication: same text, same image pixels or same file list is the same item.
    var contentHash: String {
        let key: String
        switch kind {
        case .text: key = "t:" + (text ?? "")
        case .image: key = "i:" + (imageHash ?? "")
        case .file: key = "f:" + files.joined(separator: "\n")
        }
        return SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The full content of one item, read only when it is copied back.
struct Content {
    let kind: ItemKind
    let text: String?
    let rtf: Data?
    let html: Data?
    let files: [String]
    let imageHash: String?
}

/// SQLite history. Text is searched on disk through a trigram index, rich text is LZFSE-compressed,
/// images live as content-addressed HEIC files next to the database.
final class Store {
    static let directory: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Stash", isDirectory: true)
        for sub in ["", "images", "thumbs"] {
            try? FileManager.default.createDirectory(at: url.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        return url
    }()

    static func imageURL(_ hash: String) -> URL { directory.appendingPathComponent("images/\(hash).heic") }
    static func thumbURL(_ hash: String) -> URL { directory.appendingPathComponent("thumbs/\(hash).heic") }

    private var db: OpaquePointer?
    /// Every statement runs on this queue; reads from the UI use `sync`, they take microseconds.
    let queue = DispatchQueue(label: "stash.store")

    init() {
        let path = Self.directory.appendingPathComponent("history.sqlite").path
        sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
        exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA cache_size=-2000;")
        exec("""
        CREATE TABLE IF NOT EXISTS items (
            id INTEGER PRIMARY KEY,
            kind INTEGER NOT NULL,
            hash TEXT NOT NULL UNIQUE,
            preview TEXT NOT NULL,
            text TEXT,
            rtf BLOB,
            html BLOB,
            files TEXT,
            image TEXT,
            width INTEGER, height INTEGER,
            app TEXT,
            first_at REAL NOT NULL,
            last_at REAL NOT NULL,
            copies INTEGER NOT NULL DEFAULT 1,
            pinned INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS items_order ON items (pinned DESC, last_at DESC);
        CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(text, content='items', content_rowid='id', tokenize='trigram');
        CREATE TRIGGER IF NOT EXISTS items_ai AFTER INSERT ON items BEGIN
            INSERT INTO items_fts(rowid, text) VALUES (new.id, coalesce(new.text, new.files, ''));
        END;
        CREATE TRIGGER IF NOT EXISTS items_ad AFTER DELETE ON items BEGIN
            INSERT INTO items_fts(items_fts, rowid, text) VALUES ('delete', old.id, coalesce(old.text, old.files, ''));
        END;
        """)
    }

    // MARK: Writes

    /// Inserts the item, or moves the existing copy of it to the top. Returns true when it changed the list.
    @discardableResult
    func save(_ item: NewItem) -> Bool {
        queue.sync {
            let hash = item.contentHash
            let bump = prepare("""
                UPDATE items SET last_at = max(last_at, ?), first_at = min(first_at, ?), copies = copies + ?,
                    pinned = max(pinned, ?), app = coalesce(?, app) WHERE hash = ?
                """)
            defer { sqlite3_finalize(bump) }
            bind(bump, 1, item.lastAt.timeIntervalSince1970)
            bind(bump, 2, item.firstAt.timeIntervalSince1970)
            sqlite3_bind_int(bump, 3, Int32(item.copies))
            sqlite3_bind_int(bump, 4, item.pinned ? 1 : 0)
            bind(bump, 5, item.app)
            bind(bump, 6, hash)
            sqlite3_step(bump)
            if sqlite3_changes(db) > 0 { return true }

            let insert = prepare("""
                INSERT INTO items (kind, hash, preview, text, rtf, html, files, image, width, height, app, first_at, last_at, copies, pinned)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            defer { sqlite3_finalize(insert) }
            sqlite3_bind_int(insert, 1, Int32(item.kind.rawValue))
            bind(insert, 2, hash)
            bind(insert, 3, Self.preview(for: item))
            bind(insert, 4, item.text)
            bind(insert, 5, item.rtf.flatMap(Self.compress))
            bind(insert, 6, item.html.flatMap(Self.compress))
            bind(insert, 7, item.files.isEmpty ? nil : item.files.joined(separator: "\n"))
            bind(insert, 8, item.imageHash)
            if let size = item.imageSize {
                sqlite3_bind_int(insert, 9, Int32(size.width))
                sqlite3_bind_int(insert, 10, Int32(size.height))
            }
            bind(insert, 11, item.app)
            bind(insert, 12, item.firstAt.timeIntervalSince1970)
            bind(insert, 13, item.lastAt.timeIntervalSince1970)
            sqlite3_bind_int(insert, 14, Int32(item.copies))
            sqlite3_bind_int(insert, 15, item.pinned ? 1 : 0)
            return sqlite3_step(insert) == SQLITE_DONE
        }
    }

    /// Marks an item as just used, so it comes back to the top.
    func touch(_ id: Int64) {
        queue.sync {
            let stmt = prepare("UPDATE items SET last_at = ?, copies = copies + 1 WHERE id = ?")
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, Date().timeIntervalSince1970)
            sqlite3_bind_int64(stmt, 2, id)
            sqlite3_step(stmt)
        }
    }

    func setPinned(_ id: Int64, _ pinned: Bool) {
        queue.sync {
            let stmt = prepare("UPDATE items SET pinned = ? WHERE id = ?")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, pinned ? 1 : 0)
            sqlite3_bind_int64(stmt, 2, id)
            sqlite3_step(stmt)
        }
    }

    func delete(_ id: Int64) {
        let image: String? = queue.sync {
            let find = prepare("SELECT image FROM items WHERE id = ?")
            defer { sqlite3_finalize(find) }
            sqlite3_bind_int64(find, 1, id)
            let image = sqlite3_step(find) == SQLITE_ROW ? column(find, 0) : nil
            let stmt = prepare("DELETE FROM items WHERE id = ?")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, id)
            sqlite3_step(stmt)
            return image
        }
        if let image { removeImageIfUnused(image) }
    }

    /// Deletes everything that isn't pinned.
    func clearUnpinned() {
        let images: [String] = queue.sync {
            let find = prepare("SELECT image FROM items WHERE pinned = 0 AND image IS NOT NULL")
            defer { sqlite3_finalize(find) }
            var images: [String] = []
            while sqlite3_step(find) == SQLITE_ROW { if let h = column(find, 0) { images.append(h) } }
            exec("DELETE FROM items WHERE pinned = 0")
            return images
        }
        images.forEach(removeImageIfUnused)
        queue.async { [self] in exec("VACUUM") }
    }

    private func removeImageIfUnused(_ hash: String) {
        let used: Bool = queue.sync {
            let stmt = prepare("SELECT 1 FROM items WHERE image = ? LIMIT 1")
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, hash)
            return sqlite3_step(stmt) == SQLITE_ROW
        }
        guard !used else { return }
        try? FileManager.default.removeItem(at: Self.imageURL(hash))
        try? FileManager.default.removeItem(at: Self.thumbURL(hash))
    }

    // MARK: Reads

    /// One page of rows, pinned first then newest. A query searches the full text, not just the preview.
    func rows(matching query: String, limit: Int) -> [Row] {
        queue.sync {
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let columns = "i.id, i.kind, i.preview, i.image, i.width, i.height, i.app, i.last_at, i.pinned"
            let stmt: OpaquePointer?
            if q.isEmpty {
                stmt = prepare("SELECT \(columns) FROM items i ORDER BY i.pinned DESC, i.last_at DESC LIMIT ?")
                sqlite3_bind_int(stmt, 1, Int32(limit))
            } else if q.count >= 3 {
                // The trigram index answers substring matches; quoting keeps the query literal.
                stmt = prepare("""
                    SELECT \(columns) FROM items_fts f JOIN items i ON i.id = f.rowid
                    WHERE items_fts MATCH ? ORDER BY i.pinned DESC, i.last_at DESC LIMIT ?
                    """)
                bind(stmt, 1, "\"" + q.replacingOccurrences(of: "\"", with: "\"\"") + "\"")
                sqlite3_bind_int(stmt, 2, Int32(limit))
            } else {
                // Trigrams need three characters; one or two fall back to a scan.
                stmt = prepare("""
                    SELECT \(columns) FROM items i WHERE coalesce(i.text, i.files) LIKE ? ESCAPE '\\'
                    ORDER BY i.pinned DESC, i.last_at DESC LIMIT ?
                    """)
                let escaped = q.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
                bind(stmt, 1, "%\(escaped)%")
                sqlite3_bind_int(stmt, 2, Int32(limit))
            }
            defer { sqlite3_finalize(stmt) }
            var rows: [Row] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let hasSize = sqlite3_column_type(stmt, 4) != SQLITE_NULL
                rows.append(Row(
                    id: sqlite3_column_int64(stmt, 0),
                    kind: ItemKind(rawValue: Int(sqlite3_column_int(stmt, 1))) ?? .text,
                    preview: column(stmt, 2) ?? "",
                    imageHash: column(stmt, 3),
                    imageSize: hasSize ? CGSize(width: Int(sqlite3_column_int(stmt, 4)), height: Int(sqlite3_column_int(stmt, 5))) : nil,
                    app: column(stmt, 6),
                    lastAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7)),
                    pinned: sqlite3_column_int(stmt, 8) != 0
                ))
            }
            return rows
        }
    }

    func content(_ id: Int64) -> Content? {
        queue.sync {
            let stmt = prepare("SELECT kind, text, rtf, html, files, image FROM items WHERE id = ?")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, id)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return Content(
                kind: ItemKind(rawValue: Int(sqlite3_column_int(stmt, 0))) ?? .text,
                text: column(stmt, 1),
                rtf: blob(stmt, 2).flatMap(Self.decompress),
                html: blob(stmt, 3).flatMap(Self.decompress),
                files: column(stmt, 4)?.split(separator: "\n").map(String.init) ?? [],
                imageHash: column(stmt, 5)
            )
        }
    }

    var isEmpty: Bool {
        queue.sync {
            let stmt = prepare("SELECT 1 FROM items LIMIT 1")
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) != SQLITE_ROW
        }
    }

    func transaction(_ body: () -> Void) {
        queue.sync { exec("BEGIN") }
        body()
        queue.sync { exec("COMMIT") }
    }

    // MARK: Helpers

    private static func preview(for item: NewItem) -> String {
        switch item.kind {
        case .text:
            // Collapse whitespace so a row shows words, not a block of indentation.
            let head = String((item.text ?? "").prefix(400))
            return head.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(200).description
        case .image:
            return item.imageSize.map { "Image \(Int($0.width))×\(Int($0.height))" } ?? "Image"
        case .file:
            let names = item.files.compactMap { URL(string: $0)?.lastPathComponent }
            return names.count > 1 ? "\(names[0]) + \(names.count - 1) more" : names.first ?? "File"
        }
    }

    private static func compress(_ data: Data) -> Data? { try? (data as NSData).compressed(using: .lzfse) as Data }
    private static func decompress(_ data: Data) -> Data? { try? (data as NSData).decompressed(using: .lzfse) as Data }

    private func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        return stmt
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value { sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, index) }
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: Double) {
        sqlite3_bind_double(stmt, index, value)
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: Data?) {
        guard let value else { sqlite3_bind_null(stmt, index); return }
        value.withUnsafeBytes { _ = sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32(value.count), SQLITE_TRANSIENT) }
    }

    private func column(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        sqlite3_column_text(stmt, index).map { String(cString: $0) }
    }

    private func blob(_ stmt: OpaquePointer?, _ index: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(stmt, index) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, index)))
    }
}
