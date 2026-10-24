import AppKit
import UniformTypeIdentifiers

enum ItemState: Codable, Equatable {
    case ready
    /// A file promise (Mail, Photos, Messages…) the source app is still writing out.
    case pending
    case failed(String)
}

/// One file on the shelf. Real files are kept by reference (path + bookmark), so a 50 GB
/// video costs nothing to shelve. `staged` marks files the shelf wrote itself (promises,
/// dropped text, images, links, action output); those live under `Paths.staging`.
struct ShelfItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var path: String
    var bookmark: Data?
    var staged: Bool
    var name: String
    var state: ItemState = .ready

    var url: URL { URL(fileURLWithPath: path) }
    var isReady: Bool { state == .ready }
    var isFailed: Bool { if case .failed = state { return true } else { return false } }

    static func reference(_ url: URL) -> ShelfItem {
        ShelfItem(path: url.path, bookmark: try? url.bookmarkData(), staged: false, name: url.lastPathComponent)
    }

    static func staged(_ url: URL, id: UUID = UUID()) -> ShelfItem {
        ShelfItem(id: id, path: url.path, bookmark: try? url.bookmarkData(), staged: true, name: url.lastPathComponent)
    }
}

/// Whatever arrived in one drop.
struct ShelfStack: Identifiable, Codable, Equatable {
    var id = UUID()
    var items: [ShelfItem]
    var added = Date()
}

struct OpError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Thread-safe view of item states, for promise writers running off the main thread.
final class ItemRegistry: @unchecked Sendable {
    static let shared = ItemRegistry()
    private let lock = NSLock()
    private var map: [UUID: (ItemState, String)] = [:]

    func update(_ stacks: [ShelfStack]) {
        var m: [UUID: (ItemState, String)] = [:]
        for s in stacks { for i in s.items { m[i.id] = (i.state, i.path) } }
        lock.withLock { map = m }
    }

    func get(_ id: UUID) -> (ItemState, String)? { lock.withLock { map[id] } }
}

enum Paths {
    static let support: URL = {
        let base: URL
        if let home = ProcessInfo.processInfo.environment["TRANSFER_HOME"] {
            base = URL(fileURLWithPath: home, isDirectory: true)
        } else {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Transfer", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static let staging: URL = {
        let url = support.appendingPathComponent("Staging", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let stateFile = support.appendingPathComponent("shelf.json")

    static func newStagingFolder() -> URL {
        let url = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func isStaged(_ url: URL) -> Bool {
        url.resolvingSymlinksInPath().path.hasPrefix(staging.resolvingSymlinksInPath().path + "/")
    }

    /// Scratch space other apps hand files over from and clean up after the drag.
    static func isTemporary(_ url: URL) -> Bool {
        let p = url.resolvingSymlinksInPath().path
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        return p.hasPrefix("/private/var/folders/") || p.hasPrefix("/private/tmp/")
            || p.hasPrefix(tmp) || p.contains("/Library/Caches/")
    }

    static func uniqueURL(in dir: URL, name: String) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        repeat {
            candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }

    static func safeName(_ s: String, fallback: String) -> String {
        let firstLine = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let cleaned = firstLine
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let short = String(cleaned.prefix(60)).trimmingCharacters(in: .whitespaces)
        return short.isEmpty || short.hasPrefix(".") ? fallback : short
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let key: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let va = try? a.resourceValues(forKeys: key).volumeIdentifier as? NSObject,
              let vb = try? b.resourceValues(forKeys: key).volumeIdentifier as? NSObject else { return false }
        return va.isEqual(vb)
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    static func size(of dir: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e {
            let v = try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
        }
        return total
    }
}

func formatBytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

enum ScreenEdge: String, CaseIterable, Codable {
    case left, right, top, bottom
    var isVertical: Bool { self == .left || self == .right }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
