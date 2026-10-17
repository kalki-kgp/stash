// Store, capture, paste and import tests. Run with ./test.sh — never touches the real history.
import AppKit
import CryptoKit
import Darwin

var failures = 0
var passes = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if condition() { passes += 1 } else { failures += 1; print("  FAIL line \(line): \(message)") }
}
func section(_ name: String) { malloc_zone_pressure_relief(nil, 0); print("• \(name)  [\(String(format: "%.0f", footprintMB())) MB]") }

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

func text(_ s: String, at: TimeInterval = Date().timeIntervalSince1970, app: String? = nil) -> NewItem {
    var item = NewItem(kind: .text, text: s, rtf: nil, html: nil, app: app)
    item.firstAt = Date(timeIntervalSince1970: at); item.lastAt = item.firstAt
    return item
}

func makeImage(width: Int, height: Int, seed: UInt8) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: CGFloat(seed) / 255, green: 0.4, blue: 0.7, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(.white)
    ctx.fill(CGRect(x: 10, y: 10, width: width / 3, height: height / 4))
    return ctx.makeImage()!
}
func encode(_ image: CGImage, _ type: NSBitmapImageRep.FileType) -> Data {
    NSBitmapImageRep(cgImage: image).representation(using: type, properties: [:])!
}

let store = Store()
func count() -> Int { store.rows(matching: "", limit: 1_000_000).count }

// MARK: -
section("text: save, dedupe, order")
store.clear(includingPinned: true)
store.save(text("alpha one", at: 100))
store.save(text("beta two", at: 200))
store.save(text("alpha one", at: 300))
var rows = store.rows(matching: "", limit: 50)
check(rows.count == 2, "duplicate text stored once (got \(rows.count))")
check(rows.first?.preview == "alpha one", "re-copied item moves to the top")
check(store.save(text("   \n\t ")) || true, "whitespace save doesn't crash")
check(Capture.item(from: [Capture.text: Data("  \n ".utf8)], app: nil) == nil, "whitespace-only copy is ignored")

section("pinning")
store.setPinned(rows[1].id, true)
rows = store.rows(matching: "", limit: 50)
check(rows.first?.preview == "beta two" && rows.first?.pinned == true, "pinned item sits on top")
store.save(text("gamma newest"))
check(store.rows(matching: "", limit: 50).first?.preview == "beta two", "pinned stays above newer copies")

section("preview")
let messy = "  line one\n\n\t   line    two  " + String(repeating: "x", count: 1000)
store.save(text(messy))
let messyRow = store.rows(matching: "line one", limit: 5).first
check(messyRow?.preview.hasPrefix("line one line two") == true, "whitespace collapsed in preview")
check((messyRow?.preview.count ?? 999) <= 200, "preview capped at 200 chars")
check(store.content(messyRow!.id)?.text == messy, "full text round-trips exactly")

section("search: substring, short, special characters, unicode")
store.clear(includingPinned: true)
let corpus = ["The Quick Brown Fox", "100% done_ok", "path\\to\\file", "say \"hi\" there", "मराठी भाषा", "emoji 🍕 pizza",
              "SELECT * FROM t; DROP TABLE items;--", "a'b", "stash test", "s t a s h spaced far apart letters everywhere"]
for (i, s) in corpus.enumerated() { store.save(text(s, at: Double(1000 + i))) }
func search(_ q: String) -> [String] { store.rows(matching: q, limit: 50, fuzzy: false).map(\.preview) }
check(search("quick").contains("The Quick Brown Fox"), "case-insensitive substring")
check(search("ui") == ["The Quick Brown Fox"], "2-char search (LIKE path)")
check(search("%") == ["100% done_ok"], "% is literal")
check(search("_") == ["100% done_ok"], "_ is literal")
check(search("\\") == ["path\\to\\file"], "backslash is literal")
check(search("\"hi\"") == ["say \"hi\" there"], "quotes in FTS query")
check(search("मराठी") == ["मराठी भाषा"], "Devanagari search")
check(search("🍕") == ["emoji 🍕 pizza"], "emoji search")
check(search("DROP TABLE") == ["SELECT * FROM t; DROP TABLE items;--"], "SQL text is just text")
check(count() == corpus.count, "table survived the SQL-looking text")
check(search("a'b") == ["a'b"], "apostrophe")
check(search("zzzz").isEmpty, "no match → empty")
check(search("   ").count == corpus.count, "blank query lists everything")

section("fuzzy search")
let fuzzy = store.rows(matching: "stst", limit: 50).map(\.preview)
check(fuzzy.first == "stash test", "letters in order within a short span match (got \(fuzzy))")
check(!fuzzy.contains("s t a s h spaced far apart letters everywhere") || fuzzy.first == "stash test", "tight match ranks first")
let exactFirst = store.rows(matching: "pizza", limit: 50).map(\.preview)
check(exactFirst.first == "emoji 🍕 pizza", "substring hit ranks before fuzzy")
check(store.rows(matching: "qbf", limit: 50).isEmpty || true, "fuzzy with spread letters doesn't crash")
check(!store.rows(matching: "xqzj", limit: 50).contains { $0.preview.contains("Quick") }, "unrelated letters don't match")
check(fuzzyScore([0x61, 0x62].withUnsafeBufferPointer { $0 }, [0x61, 0x62, 0x63].withUnsafeBufferPointer { $0 }) == 0, "query longer than text scores 0")

section("large text")
let big = String(repeating: "lorem ipsum dolor sit amet ", count: 200_000) + "NEEDLE_AT_END"
let t0 = Date()
store.save(text(big))
let bigRow = store.rows(matching: "lorem", limit: 1).first!
check(store.content(bigRow.id)?.text?.count == big.count, "5 MB text stored and read back intact")
check(Date().timeIntervalSince(t0) < 3, "5 MB save + read under 3 s (\(Date().timeIntervalSince(t0)))")
let t1 = Date()
_ = store.rows(matching: "dolor", limit: 60)
check(Date().timeIntervalSince(t1) < 0.5, "search with a 5 MB item under 0.5 s (\(Date().timeIntervalSince(t1)))")
check(store.fullText(bigRow.id)?.count == 2000, "tooltip text capped at 2000")

section("rich text")
let rtf = try! NSAttributedString(string: "bold text", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)])
    .data(from: NSRange(location: 0, length: 9), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
let html = Data("<b>bold text</b>".utf8)
store.save(NewItem(kind: .text, text: "bold text", rtf: rtf, html: html))
let rich = store.content(store.rows(matching: "bold text", limit: 1).first!.id)!
check(rich.rtf == rtf && rich.html == html, "RTF and HTML round-trip through LZFSE")

section("images: HEIC, thumbnails, pixel dedupe, cleanup")
store.clear(includingPinned: true)
let img = makeImage(width: 1600, height: 1000, seed: 30)
let tiffData = encode(img, .tiff), pngData = encode(img, .png)
let fromTiff = Capture.item(from: [Capture.tiff: tiffData], app: nil)!
let fromPng = Capture.item(from: [Capture.png: pngData], app: nil)!
check(fromTiff.imageHash == fromPng.imageHash, "same pixels as TIFF and PNG → same hash")
store.save(fromTiff); store.save(fromPng)
check(count() == 1, "stored once")
let heic = Store.imageURL(fromTiff.imageHash!)
let heicSize = (try? FileManager.default.attributesOfItem(atPath: heic.path)[.size] as? Int) ?? 0
check(heicSize > 0 && heicSize < tiffData.count / 5, "HEIC much smaller than TIFF (\(heicSize) vs \(tiffData.count))")
check(FileManager.default.fileExists(atPath: Store.thumbURL(fromTiff.imageHash!).path), "thumbnail written")
let imgRow = store.rows(matching: "", limit: 1).first!
check(imgRow.kind == .image && imgRow.imageSize == CGSize(width: 1600, height: 1000), "image row has its size")
let other = Capture.item(from: [Capture.png: encode(makeImage(width: 200, height: 200, seed: 200), .png)], app: nil)!
store.save(other)
check(other.imageHash != fromTiff.imageHash, "different pixels → different hash")
store.delete(imgRow.id)
check(!FileManager.default.fileExists(atPath: heic.path), "deleting an image item removes its files")
check(Capture.item(from: [Capture.png: Data("not an image".utf8)], app: nil) == nil, "garbage image data is ignored")

section("clear")
store.clear(includingPinned: true)
for i in 0..<5 { store.save(text("item \(i)")) }
store.setPinned(store.rows(matching: "item 2", limit: 1).first!.id, true)
store.clear()
check(store.rows(matching: "", limit: 50).map(\.preview) == ["item 2"], "clear keeps pinned")
store.clear(includingPinned: true)
check(count() == 0, "clear all removes pinned too")
let leftover = (try? FileManager.default.contentsOfDirectory(atPath: Store.directory.appendingPathComponent("images").path)) ?? []
check(leftover.isEmpty, "no orphaned image files after clear all (\(leftover.count))")

section("pasteboard read")
let pb = NSPasteboard(name: NSPasteboard.Name("stash.tests.\(getpid())"))
pb.clearContents(); pb.setString("hello", forType: .string)
check(Capture.read(pb)?[Capture.text] == Data("hello".utf8), "plain text read")
pb.clearContents()
let concealed = NSPasteboardItem(); concealed.setString("hunter2", forType: .string)
concealed.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
pb.writeObjects([concealed])
check(Capture.read(pb) == nil, "password-manager (concealed) copy ignored")
for type in ["com.agilebits.onepassword", "de.petermaurer.TransientPasteboardType", "net.antelle.keeweb", "org.nspasteboard.TransientType"] {
    pb.clearContents(); let i = NSPasteboardItem(); i.setString("x", forType: .string); i.setData(Data(), forType: .init(type))
    pb.writeObjects([i])
    check(Capture.read(pb) == nil, "ignored type \(type)")
}
pb.clearContents(); pb.writeObjects([URL(fileURLWithPath: "/tmp/a.txt") as NSURL, URL(fileURLWithPath: "/tmp/b c.txt") as NSURL])
let files = Capture.item(from: Capture.read(pb)!, app: nil)!
check(files.kind == .file && files.files.count == 2, "multiple Finder files → one file item")
pb.clearContents(); let both = NSPasteboardItem(); both.setString("caption", forType: .string); both.setData(pngData, forType: .png)
pb.writeObjects([both])
let read = Capture.read(pb)!
check(read[Capture.png] == nil && Capture.item(from: read, app: nil)?.kind == .text, "text + image → text, image not read")
pb.clearContents(); pb.setData(pngData, forType: .png)
check(Capture.item(from: Capture.read(pb)!, app: nil)?.kind == .image, "image-only copy → image")
pb.clearContents(); pb.setData(Data(count: 10), forType: .init("com.apple.webarchive"))
check(Capture.read(pb) == nil, "web archive alone isn't stored")

section("paste back")
Paste.write(Content(kind: .text, text: "bold text", rtf: rtf, html: html, files: [], imageHash: nil), to: pb)
check(pb.string(forType: .string) == "bold text" && pb.data(forType: .rtf) == rtf && pb.data(forType: .html) == html, "text + formatting written")
Paste.write(Content(kind: .text, text: "plain", rtf: nil, html: nil, files: [], imageHash: nil), to: pb)
check(pb.data(forType: .rtf) == nil, "plain paste carries no formatting")
store.save(fromPng)
Paste.write(Content(kind: .image, text: nil, rtf: nil, html: nil, files: [], imageHash: fromPng.imageHash), to: pb)
let pasted = pb.data(forType: .png).flatMap { NSBitmapImageRep(data: $0) }
check(pasted?.pixelsWide == 1600 && pasted?.pixelsHigh == 1000, "image pastes back as PNG at full size")
check(pb.data(forType: .tiff).flatMap { NSBitmapImageRep(data: $0) }?.pixelsWide == 1600, "and as TIFF")
Paste.write(Content(kind: .file, text: nil, rtf: nil, html: nil, files: files.files, imageHash: nil), to: pb)
check((pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.map(\.path) == ["/tmp/a.txt", "/tmp/b c.txt"], "files paste back as file URLs")
pb.releaseGlobally()

section("Maccy import (read-only)")
let maccy = MaccyImport.path
if FileManager.default.fileExists(atPath: maccy) {
    func digest(_ p: String) -> String { SHA256.hash(data: (try? Data(contentsOf: URL(fileURLWithPath: p))) ?? Data()).description }
    let before = digest(maccy)
    store.clear(includingPinned: true)
    let t = Date()
    let n = MaccyImport.run(into: store)
    let first = count()
    _ = MaccyImport.run(into: store)
    check(n > 900 && first > 900, "imported \(n) items in \(String(format: "%.1f", Date().timeIntervalSince(t))) s")
    check(count() == first, "re-import adds no duplicates")
    check(digest(maccy) == before, "Maccy's database is byte-for-byte unchanged")
    check(!store.rows(matching: "the", limit: 10).isEmpty, "imported text is searchable")

    // Per-keystroke search cost on the real ~1000-item history; the panel runs this on every key.
    var worst = 0.0, total = 0.0, runs = 0
    for word in ["c", "cl", "cla", "clau", "claude", "git", "http", "the", "xqzv", "stsh", "deloitte", "पु", "kalki"] {
        for prefix in 1...word.count {
            let q = String(word.prefix(prefix))
            let t = DispatchTime.now().uptimeNanoseconds
            _ = store.rows(matching: q, limit: 60)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
            worst = max(worst, ms); total += ms; runs += 1
        }
    }
    print("  search per keystroke: avg \(String(format: "%.2f", total / Double(runs))) ms, worst \(String(format: "%.2f", worst)) ms over \(runs) queries")
    check(worst < 16, "every keystroke's search fits in one 60 Hz frame (worst \(String(format: "%.1f", worst)) ms)")
    let open = DispatchTime.now().uptimeNanoseconds
    _ = store.rows(matching: "", limit: 60)
    print("  open list query: \(String(format: "%.2f", Double(DispatchTime.now().uptimeNanoseconds - open) / 1e6)) ms")
} else { print("  (no Maccy database, skipped)") }

section("concurrency")
store.clear(includingPinned: true)
DispatchQueue.concurrentPerform(iterations: 8) { worker in
    for i in 0..<200 {
        store.save(text("w\(worker) n\(i)"))
        _ = store.rows(matching: "w\(worker)", limit: 20)
        if i % 50 == 0, let r = store.rows(matching: "", limit: 1).first { _ = store.content(r.id) }
    }
}
check(count() == 1600, "1600 concurrent saves all landed (\(count()))")

section("memory: 20k operations")
for i in 0..<300 { autoreleasepool { store.save(text("warm \(i)")); _ = Capture.item(from: [Capture.png: pngData], app: nil) } }
malloc_zone_pressure_relief(nil, 0)
let startMB = footprintMB()
for round in 0..<4 {
    for i in 0..<1000 {
        autoreleasepool {
            store.save(text("cycle \(round) \(i) " + String(repeating: "z", count: 500)))
            _ = store.rows(matching: "cycle \(i % 10)", limit: 60)
            _ = store.rows(matching: "", limit: 60)
            if let r = store.rows(matching: "", limit: 1).first { _ = store.content(r.id); _ = store.fullText(r.id) }
            _ = Capture.item(from: [Capture.png: pngData], app: nil)
        }
    }
}
store.clear(includingPinned: true)
malloc_zone_pressure_relief(nil, 0)
let endMB = footprintMB()
print("  footprint \(String(format: "%.1f", startMB)) MB → \(String(format: "%.1f", endMB)) MB")
check(endMB - startMB < 15, "no growth over 20k operations (+\(String(format: "%.1f", endMB - startMB)) MB)")

print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
