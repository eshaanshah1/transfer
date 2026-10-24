import AppKit
import UniformTypeIdentifiers

/// Everything on a pasteboard that isn't a file, captured at drop time so it can be
/// written out later (pasteboards are only valid during the drop).
struct Fallback {
    var images: [(Data, String)] = []
    var links: [(URL, String?)] = []
    var texts: [String] = []

    var isEmpty: Bool { images.isEmpty && links.isEmpty && texts.isEmpty }

    init(_ pb: NSPasteboard) {
        for item in pb.pasteboardItems ?? [] {
            if let d = item.data(forType: .png) { images.append((d, "png")); continue }
            if let d = item.data(forType: .init("public.jpeg")) { images.append((d, "jpg")); continue }
            if let d = item.data(forType: .init("public.heic")) { images.append((d, "heic")); continue }
            if let d = item.data(forType: .tiff), let rep = NSBitmapImageRep(data: d),
               let png = rep.representation(using: .png, properties: [:]) {
                images.append((png, "png")); continue
            }
            if let s = item.string(forType: .URL), let u = URL(string: s), let scheme = u.scheme, scheme != "file" {
                links.append((u, item.string(forType: .init("public.url-name")))); continue
            }
            if let s = item.string(forType: .string) {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { continue }
                if !t.contains(where: \.isWhitespace), let u = URL(string: t),
                   ["http", "https"].contains(u.scheme?.lowercased() ?? "") {
                    links.append((u, nil))
                } else {
                    texts.append(s)
                }
                continue
            }
            if let d = item.data(forType: .rtf), let a = NSAttributedString(rtf: d, documentAttributes: nil),
               !a.string.isEmpty {
                texts.append(a.string)
            }
        }
    }

    func write(to folder: URL) -> [URL] {
        var out: [URL] = []
        let stamp = Self.stamp()
        for (i, (data, ext)) in images.enumerated() {
            let name = images.count > 1 ? "Image \(stamp) \(i + 1).\(ext)" : "Image \(stamp).\(ext)"
            let url = Paths.uniqueURL(in: folder, name: name)
            if (try? data.write(to: url)) != nil { out.append(url) }
        }
        for (link, title) in links {
            let fallbackName = [link.host, link.lastPathComponent == "/" ? nil : link.lastPathComponent]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            let base = Paths.safeName(title ?? fallbackName, fallback: "Link")
            let url = Paths.uniqueURL(in: folder, name: base + ".webloc")
            if let plist = try? PropertyListSerialization.data(fromPropertyList: ["URL": link.absoluteString], format: .xml, options: 0),
               (try? plist.write(to: url)) != nil {
                out.append(url)
            }
        }
        for text in texts {
            let url = Paths.uniqueURL(in: folder, name: Paths.safeName(text, fallback: "Text") + ".txt")
            if (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil { out.append(url) }
        }
        return out
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f.string(from: Date())
    }
}

/// Turns whatever is being dropped into shelf items. In order of preference:
/// real files (kept by reference), file promises (written into staging),
/// then images, links and text (saved as .png / .webloc / .txt).
@MainActor
enum Intake {
    static let types: [NSPasteboard.PasteboardType] =
        [.fileURL, .URL, .string, .png, .tiff, .rtf, .init("public.jpeg"), .init("public.heic")]
        + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    static let promiseQueue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        q.name = "Transfer promises"
        return q
    }()

    static func fileURLs(_ pb: NSPasteboard) -> [URL] {
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.map { ($0 as NSURL).filePathURL ?? $0 }
    }

    /// Adds what's on the pasteboard as a new stack. Returns its id.
    @discardableResult
    static func ingest(_ pb: NSPasteboard, into store: Store) -> UUID? {
        let files = fileURLs(pb)
        if !files.isEmpty { return store.add(files.map(fileItem)) }

        let fallback = Fallback(pb)
        if let receivers = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !receivers.isEmpty {
            return receive(receivers, fallback: fallback, store: store)
        }

        let folder = Paths.newStagingFolder()
        let urls = fallback.write(to: folder)
        guard !urls.isEmpty else {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        return store.addStaged(urls)
    }

    static func fileItem(_ url: URL) -> ShelfItem {
        // Apps like browsers and chat clients drag out of temp folders they delete
        // right after; clone those (free on APFS) so the shelf doesn't hold a dangling path.
        if Paths.isTemporary(url), !Paths.isStaged(url) {
            let dest = Paths.uniqueURL(in: Paths.newStagingFolder(), name: url.lastPathComponent)
            if (try? FileManager.default.copyItem(at: url, to: dest)) != nil { return .staged(dest) }
        }
        return .reference(url)
    }

    private static func receive(_ receivers: [NSFilePromiseReceiver], fallback: Fallback, store: Store) -> UUID {
        let folder = Paths.newStagingFolder()
        let placeholders: [ShelfItem] = receivers.map { r in
            let name = r.fileTypes.first.flatMap { UTType($0)?.localizedDescription } ?? "File"
            return ShelfItem(path: folder.appendingPathComponent(name).path, bookmark: nil, staged: true, name: name, state: .pending)
        }
        let stackID = store.add(placeholders)
        for (r, placeholder) in zip(receivers, placeholders) {
            let id = placeholder.id
            r.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: promiseQueue) { url, error in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if let error {
                            store.promiseFailed(id, stack: stackID, error: error, fallback: fallback, folder: folder)
                        } else {
                            store.promiseDelivered(url, placeholder: id, stack: stackID)
                        }
                    }
                }
            }
            // File names are only known once receiving has started.
            if let name = r.fileNames.first, store.item(id)?.state == .pending {
                store.mutateItem(id) {
                    $0.name = name
                    $0.path = folder.appendingPathComponent(name).path
                }
            }
        }
        return stackID
    }
}
