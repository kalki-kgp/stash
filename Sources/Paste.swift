import AppKit
import ImageIO
import SQLite3
import UniformTypeIdentifiers

/// Puts a stored item back on the clipboard with every format it was copied with, so each app
/// reads what it understands, as it would have from the original copy. The app runs this in a child
/// process for items with a picture (`ImageWorker.paste`), so the decoded image never sits in its own
/// memory and stays pasteable after Stash quits.
enum Paste {
    static func write(_ content: Content, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        if let text = content.text { item.setString(text, forType: .string) }
        if let rtf = content.rtf { item.setData(rtf, forType: .rtf) }
        if let html = content.html { item.setData(html, forType: .html) }
        if let hash = content.imageHash, let picture = imageData(at: Store.imageURL(hash)) {
            item.setData(picture.png, forType: .png)
            item.setData(picture.tiff, forType: .tiff)
        }
        // Several copied files are several pasteboard items, one file link each.
        var extra: [NSPasteboardItem] = []
        for (index, file) in content.files.enumerated() {
            if index == 0 {
                item.setString(file, forType: .fileURL)
            } else {
                let next = NSPasteboardItem()
                next.setString(file, forType: .fileURL)
                extra.append(next)
            }
        }
        pasteboard.writeObjects([item] + extra)
    }

    private static func imageData(at url: URL) -> (png: Data, tiff: Data)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]),
              let tiff = rep.tiffRepresentation(using: .lzw, factor: 0) else { return nil }
        return (png, tiff)
    }
}

/// Reads Maccy's history (read-only; Maccy's files are never written).
enum MaccyImport {
    static let path = ProcessInfo.processInfo.environment["STASH_MACCY_DB"] ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/org.p0deje.Maccy/Data/Library/Application Support/Maccy/Storage.sqlite").path

    /// Core Data stores dates as seconds since 2001-01-01.
    private static let referenceOffset: TimeInterval = 978_307_200

    private struct MaccyItem {
        var data: [String: Data]
        var app: String?
        var firstAt: Date
        var lastAt: Date
        var copies: Int
        var pinned: Bool

        var item: NewItem? {
            guard var item = autoreleasepool(invoking: { Capture.item(from: data, app: app) }) else { return nil }
            item.firstAt = firstAt
            item.lastAt = lastAt
            item.copies = copies
            item.pinned = pinned
            return item
        }
    }

    /// Walks Maccy's items oldest first, giving each one's content with the same rules as a live copy.
    /// False when Maccy's data couldn't be opened (missing, or macOS didn't allow access to it).
    @discardableResult
    private static func forEachItem(_ body: (MaccyItem) -> Void) -> Bool {
        var db: OpaquePointer?
        // Maccy keeps its data in its sandbox container; the first read makes macOS ask the user.
        guard sqlite3_open_v2("file:\(path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              sqlite3_exec(db, "SELECT 1 FROM ZHISTORYITEM LIMIT 1", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return false
        }
        defer { sqlite3_close(db) }

        var items: OpaquePointer?
        sqlite3_prepare_v2(db, """
            SELECT Z_PK, ZFIRSTCOPIEDAT, ZLASTCOPIEDAT, ZNUMBEROFCOPIES, ZAPPLICATION, ZPIN FROM ZHISTORYITEM ORDER BY ZLASTCOPIEDAT
            """, -1, &items, nil)
        defer { sqlite3_finalize(items) }
        let wanted = [Capture.text, Capture.fileURL, Capture.rtf, Capture.html, Capture.png, Capture.tiff]
        var contents: OpaquePointer?
        let marks = wanted.map { _ in "?" }.joined(separator: ", ")
        sqlite3_prepare_v2(db, "SELECT ZTYPE, ZVALUE FROM ZHISTORYITEMCONTENT WHERE ZITEM = ? AND ZTYPE IN (\(marks))", -1, &contents, nil)
        defer { sqlite3_finalize(contents) }

        while sqlite3_step(items) == SQLITE_ROW {
            sqlite3_reset(contents)
            sqlite3_bind_int64(contents, 1, sqlite3_column_int64(items, 0))
            for (i, type) in wanted.enumerated() {
                sqlite3_bind_text(contents, Int32(i + 2), type, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            var data: [String: Data] = [:]
            var fileURLs: [String] = []
            while sqlite3_step(contents) == SQLITE_ROW {
                guard let type = sqlite3_column_text(contents, 0).map({ String(cString: $0) }),
                      let bytes = sqlite3_column_blob(contents, 1) else { continue }
                let value = Data(bytes: bytes, count: Int(sqlite3_column_bytes(contents, 1)))
                if type == Capture.fileURL { fileURLs.append(String(decoding: value, as: UTF8.self)) } else { data[type] = value }
            }
            if !fileURLs.isEmpty { data[Capture.fileURL] = Data(fileURLs.joined(separator: "\n").utf8) }
            if data[Capture.png] != nil { data[Capture.tiff] = nil }

            body(MaccyItem(
                data: data,
                app: sqlite3_column_text(items, 4).map { String(cString: $0) },
                firstAt: Date(timeIntervalSince1970: sqlite3_column_double(items, 1) + referenceOffset),
                lastAt: Date(timeIntervalSince1970: sqlite3_column_double(items, 2) + referenceOffset),
                copies: max(1, Int(sqlite3_column_int(items, 3))),
                pinned: sqlite3_column_type(items, 5) != SQLITE_NULL
            ))
        }
        return true
    }

    /// Copies Maccy's history in. Into a history that already has items, it only fills in formats an
    /// earlier version didn't keep and doesn't count the items as copied again. Nil when Maccy's data
    /// couldn't be read.
    static func run(into store: Store) -> Int? {
        let countCopies = store.isEmpty
        var imported = 0
        let opened = forEachItem { maccy in
            guard var item = maccy.item else { return }
            if !countCopies { item.copies = 0 }
            if store.save(item) { imported += 1 }
        }
        malloc_zone_pressure_relief(nil, 0)
        return opened ? imported : nil
    }
}
