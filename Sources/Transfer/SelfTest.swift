import AppKit
import ImageIO
import UniformTypeIdentifiers

/// `Transfer --selftest`: exercises intake, actions, moves and history headlessly.
/// Set TRANSFER_HOME to a scratch folder so the real shelf isn't touched.
@MainActor
enum SelfTest {
    private static var failures = 0
    private static var passes = 0

    static func start() {
        guard ProcessInfo.processInfo.environment["TRANSFER_HOME"] != nil else {
            print("Set TRANSFER_HOME to a scratch folder first")
            exit(2)
        }
        Task { @MainActor in
            await run()
            print("\n\(passes) passed, \(failures) failed")
            exit(failures == 0 ? 0 : 1)
        }
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if ok { passes += 1; print("  ok  \(name)") } else { failures += 1; print("FAIL  \(name) \(detail)") }
    }

    private static func run() async {
        let fm = FileManager.default
        let work = Paths.support.appendingPathComponent("work", isDirectory: true)
        try? fm.removeItem(at: work)
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        let store = Store()
        let pb = NSPasteboard(name: .init("com.eshaan.transfer.selftest"))

        print("Intake")
        pb.clearContents()
        pb.setString("Meeting notes\nsecond line", forType: .string)
        if let id = Intake.ingest(pb, into: store), let item = store.items(inStack: id).first {
            let text = try? String(contentsOf: item.url, encoding: .utf8)
            check("text becomes a .txt", item.name == "Meeting notes.txt" && text == "Meeting notes\nsecond line", item.name)
            check("text is staged", item.staged && Paths.isStaged(item.url))
        } else { check("text ingested", false) }

        pb.clearContents()
        pb.setString("https://github.com/pilotmoon", forType: .string)
        if let id = Intake.ingest(pb, into: store), let item = store.items(inStack: id).first {
            let plist = (try? Data(contentsOf: item.url)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) } as? [String: String]
            check("link becomes a .webloc", item.name.hasSuffix(".webloc") && plist?["URL"] == "https://github.com/pilotmoon", item.name)
        } else { check("link ingested", false) }

        pb.clearContents()
        let png = makeImage(width: 40, height: 30, text: nil, alpha: false, type: .png)
        pb.setData(png, forType: .png)
        if let id = Intake.ingest(pb, into: store), let item = store.items(inStack: id).first {
            check("image data becomes a .png", item.name.hasSuffix(".png") && (try? Data(contentsOf: item.url)) == png, item.name)
        } else { check("image ingested", false) }

        let real = work.appendingPathComponent("Report.pdf")
        try? Data("pdf".utf8).write(to: real)
        let other = work.appendingPathComponent("Clip.mov")
        try? Data("mov".utf8).write(to: other)
        pb.clearContents()
        pb.writeObjects([real as NSURL, other as NSURL])
        if let id = Intake.ingest(pb, into: store) {
            let items = store.items(inStack: id)
            check("files dropped together form one stack", items.count == 2 && store.stacks.count(where: { $0.id == id }) == 1)
            check("real files are referenced, not copied", items.allSatisfy { !$0.staged && $0.path.hasPrefix(work.path) })
        } else { check("files ingested", false) }

        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("transfer-selftest-\(UUID().uuidString).txt")
        try? Data("temp".utf8).write(to: temp)
        pb.clearContents()
        pb.writeObjects([temp as NSURL])
        if let id = Intake.ingest(pb, into: store), let item = store.items(inStack: id).first {
            check("files from temp folders are cloned into staging", item.staged && Paths.isStaged(item.url))
        } else { check("temp file ingested", false) }
        try? fm.removeItem(at: temp)

        print("Bookmarks")
        if let report = store.stacks.flatMap(\.items).first(where: { $0.name == "Report.pdf" }) {
            let moved = work.appendingPathComponent("Renamed.pdf")
            try? fm.moveItem(at: real, to: moved)
            let found = store.url(for: report)
            check("references follow a file that was moved", found.resolvingSymlinksInPath().path == moved.resolvingSymlinksInPath().path, found.path)
        }

        print("Names")
        try? Data("x".utf8).write(to: work.appendingPathComponent("photo.jpg"))
        let unique = Paths.uniqueURL(in: work, name: "photo.jpg")
        check("name clashes get a number", unique.lastPathComponent == "photo 2.jpg", unique.lastPathComponent)

        print("Removing")
        let staged = store.items.filter(\.staged).map(\.path)
        store.clear()
        check("clear empties the shelf", store.stacks.isEmpty)
        check("clearing deletes the shelf's own copies", !staged.isEmpty && staged.allSatisfy { !fm.fileExists(atPath: $0) })
        check("…but never the originals", fm.fileExists(atPath: work.appendingPathComponent("Renamed.pdf").path))

        print("Dragging out")
        pb.clearContents()
        pb.writeObjects([work.appendingPathComponent("Renamed.pdf") as NSURL])
        if let id = Intake.ingest(pb, into: store) {
            let ids = store.items(inStack: id).map(\.id)
            store.dragEnded(ids, operation: [])
            check("a cancelled drag keeps items", store.itemCount == 1)
            store.dragEnded(ids, operation: .copy)
            check("a completed drag takes them off the shelf", store.itemCount == 0)
        }
        var pending = ShelfItem.staged(work.appendingPathComponent("later.pdf"))
        pending.state = .pending
        store.add([pending])
        store.dragEnded([pending.id], operation: .copy)
        check("items still arriving stay until their copy is handed over", store.item(pending.id) != nil)
        store.clear()

        print("Persistence")
        pb.clearContents()
        pb.setString("persist me", forType: .string)
        Intake.ingest(pb, into: store)
        store.save()
        let reloaded = Store()
        reloaded.load()
        check("the shelf survives a relaunch", reloaded.stacks.first?.items.first?.name == "persist me.txt")

    }

    private static func imageProps(_ url: URL) -> [CFString: Any] {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] ?? [:]
    }

    private static func makeImage(width: Int, height: Int, text: String?, alpha: Bool, type: UTType, gps: Bool = false) -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if !alpha {
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        if let text {
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ns
            (text as NSString).draw(at: NSPoint(x: 40, y: height / 3), withAttributes: [
                .font: NSFont.boldSystemFont(ofSize: 80), .foregroundColor: NSColor.black,
            ])
            NSGraphicsContext.restoreGraphicsState()
        }
        let image = ctx.makeImage()!
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        var props: [CFString: Any] = [:]
        if gps {
            props[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 37.33, kCGImagePropertyGPSLatitudeRef: "N",
                                                    kCGImagePropertyGPSLongitude: 122.0, kCGImagePropertyGPSLongitudeRef: "W"]
            props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: "2026:10:24 10:00:00"]
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        CGImageDestinationFinalize(dest)
        return data as Data
    }
}
