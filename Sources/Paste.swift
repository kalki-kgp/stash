import AppKit
import ImageIO
import SQLite3

/// Puts a stored item back on the clipboard in the forms other apps expect.
enum Paste {
    static func write(_ content: Content) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch content.kind {
        case .text:
            let item = NSPasteboardItem()
            if let text = content.text { item.setString(text, forType: .string) }
            if let rtf = content.rtf { item.setData(rtf, forType: .rtf) }
            if let html = content.html { item.setData(html, forType: .html) }
            pasteboard.writeObjects([item])
        case .file:
            pasteboard.writeObjects(content.files.compactMap { URL(string: $0) as NSURL? })
        case .image:
            // PNG and TIFF are produced only if an app asks for them, so the 27 MB TIFF of a
            // screenshot exists only while something is pasting it.
            guard let hash = content.imageHash else { return }
            let item = NSPasteboardItem()
            let provider = ImageProvider(url: Store.imageURL(hash))
            ImageProvider.current = provider
            item.setDataProvider(provider, forTypes: [.png, .tiff])
            pasteboard.writeObjects([item])
        }
    }
}

private final class ImageProvider: NSObject, NSPasteboardItemDataProvider {
    /// Held here because the pasteboard only keeps a weak reference to its provider.
    static var current: ImageProvider?
    let url: URL

    init(url: URL) { self.url = url }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        let data = type == .png ? rep.representation(using: .png, properties: [:]) : rep.tiffRepresentation
        if let data { item.setData(data, forType: type) }
    }
}

/// One-time copy of Maccy's history (read-only; Maccy's files are never written).
enum MaccyImport {
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/org.p0deje.Maccy/Data/Library/Application Support/Maccy/Storage.sqlite").path

    /// Core Data stores dates as seconds since 2001-01-01.
    private static let referenceOffset: TimeInterval = 978_307_200

    static func run(into store: Store) -> Int {
        var db: OpaquePointer?
        guard FileManager.default.fileExists(atPath: path),
              sqlite3_open_v2("file:\(path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_close(db) }

        var items: OpaquePointer?
        sqlite3_prepare_v2(db, """
            SELECT Z_PK, ZFIRSTCOPIEDAT, ZLASTCOPIEDAT, ZNUMBEROFCOPIES, ZAPPLICATION, ZPIN FROM ZHISTORYITEM ORDER BY ZLASTCOPIEDAT
            """, -1, &items, nil)
        defer { sqlite3_finalize(items) }
        var contents: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT ZTYPE, ZVALUE FROM ZHISTORYITEMCONTENT WHERE ZITEM = ? AND ZTYPE IN (?, ?, ?, ?, ?, ?)", -1, &contents, nil)
        defer { sqlite3_finalize(contents) }

        let wanted = [Capture.text, Capture.fileURL, Capture.rtf, Capture.html, Capture.png, Capture.tiff]
        var imported = 0
        store.transaction {
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
                // Same rule as a live copy: an image only matters when there's no text with it.
                if data[Capture.text] != nil { data[Capture.png] = nil; data[Capture.tiff] = nil }
                if data[Capture.png] != nil { data[Capture.tiff] = nil }

                let app = sqlite3_column_text(items, 4).map { String(cString: $0) }
                guard var item = autoreleasepool(invoking: { Capture.item(from: data, app: app) }) else { continue }
                item.firstAt = Date(timeIntervalSince1970: sqlite3_column_double(items, 1) + referenceOffset)
                item.lastAt = Date(timeIntervalSince1970: sqlite3_column_double(items, 2) + referenceOffset)
                item.copies = max(1, Int(sqlite3_column_int(items, 3)))
                item.pinned = sqlite3_column_type(items, 5) != SQLITE_NULL
                if store.save(item) { imported += 1 }
            }
        }
        malloc_zone_pressure_relief(nil, 0)
        return imported
    }
}
