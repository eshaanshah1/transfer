import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Thumbnails and file facts (size, iCloud status) for shelf items, read off the main thread.
@MainActor
final class Thumbnails: ObservableObject {
    struct Meta {
        var exists = true
        var isDirectory = false
        var isPackage = false
        var size: Int64?
        /// An iCloud (or other File Provider) placeholder not downloaded to this Mac.
        var cloud = false
    }

    @Published private(set) var images: [String: NSImage] = [:]
    @Published private(set) var meta: [String: Meta] = [:]
    private var requested: Set<String> = []
    private var icons: [String: NSImage] = [:]

    func load(_ item: ShelfItem) {
        guard item.isReady, !requested.contains(item.path) else { return }
        requested.insert(item.path)
        let path = item.path
        Task { [weak self] in
            let m = await Task.detached(priority: .utility) { Self.readMeta(path) }.value
            self?.meta[path] = m
            // Don't make QuickLook pull a placeholder down from iCloud just for a preview.
            guard m.exists, !m.cloud, !m.isDirectory || m.isPackage else { return }
            let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: 128, height: 128),
                                                       scale: 2, representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                self?.images[path] = rep.nsImage
            }
        }
    }

    /// Re-read sizes and iCloud status next time items are shown.
    func refresh() {
        requested.removeAll()
    }

    func image(for item: ShelfItem) -> NSImage {
        if let i = images[item.path] { return i }
        if let i = icons[item.path] { return i }
        let icon: NSImage
        if item.isReady, FileManager.default.fileExists(atPath: item.path) {
            icon = NSWorkspace.shared.icon(forFile: item.path)
        } else {
            let type = UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data
            icon = NSWorkspace.shared.icon(for: type)
        }
        icons[item.path] = icon
        return icon
    }

    nonisolated static func readMeta(_ path: String) -> Meta {
        // A fresh URL each time: URL caches resource values per instance.
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .isUbiquitousItemKey,
                                         .ubiquitousItemDownloadingStatusKey]
        guard FileManager.default.fileExists(atPath: path), let v = try? url.resourceValues(forKeys: keys) else {
            return Meta(exists: false)
        }
        var m = Meta()
        m.isDirectory = v.isDirectory ?? false
        m.isPackage = v.isPackage ?? false
        m.size = m.isDirectory ? nil : v.fileSize.map(Int64.init)
        if v.isUbiquitousItem == true, v.ubiquitousItemDownloadingStatus == .notDownloaded { m.cloud = true }
        return m
    }
}
