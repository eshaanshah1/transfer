import AppKit

@MainActor
final class Store: ObservableObject {
    @Published var stacks: [ShelfStack] = [] { didSet { stacksChanged() } }
    /// A drag is in progress somewhere: the square shows as a drop target.
    @Published var dragActive = false
    /// A drag is hovering over the square.
    @Published var targeted = false

    /// Items in a drag that started on the square.
    var draggingItemIDs: [UUID] = []

    private var saveWork: DispatchWorkItem?
    private var loading = false

    var items: [ShelfItem] { stacks.flatMap(\.items) }
    var itemCount: Int { items.count }

    func item(_ id: UUID) -> ShelfItem? { items.first { $0.id == id } }

    func items(inStack id: UUID) -> [ShelfItem] { stacks.first { $0.id == id }?.items ?? [] }

    /// Current location of an item, following its bookmark if the file moved.
    func url(for item: ShelfItem) -> URL {
        if FileManager.default.fileExists(atPath: item.path) { return item.url }
        if let bm = item.bookmark {
            var stale = false
            if let u = try? URL(resolvingBookmarkData: bm, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: u.path) {
                if self.item(item.id) != nil, u.path != item.path {
                    mutateItem(item.id) { $0.path = u.path; $0.name = u.lastPathComponent }
                }
                return u
            }
        }
        return item.url
    }

    // MARK: - Mutations

    @discardableResult
    func add(_ items: [ShelfItem]) -> UUID {
        let s = ShelfStack(items: items)
        stacks.insert(s, at: 0)
        return s.id
    }

    @discardableResult
    func addStaged(_ urls: [URL]) -> UUID { add(urls.map { ShelfItem.staged($0) }) }

    func mutateItem(_ id: UUID, _ f: (inout ShelfItem) -> Void) {
        for si in stacks.indices {
            if let ii = stacks[si].items.firstIndex(where: { $0.id == id }) {
                f(&stacks[si].items[ii])
                return
            }
        }
    }

    func append(_ item: ShelfItem, toStack id: UUID) {
        guard let si = stacks.firstIndex(where: { $0.id == id }) else { return }
        stacks[si].items.append(item)
    }

    func replaceItems(ofStack id: UUID, with items: [ShelfItem]) {
        guard let si = stacks.firstIndex(where: { $0.id == id }) else { return }
        stacks[si].items = items
    }

    /// Takes items off the shelf and deletes any copies the shelf itself was holding.
    func remove(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let gone = items.filter { ids.contains($0.id) }
        stacks = stacks.compactMap { s in
            var s = s
            s.items.removeAll { ids.contains($0.id) }
            return s.items.isEmpty ? nil : s
        }
        for item in gone where item.staged && Paths.isStaged(item.url) {
            try? FileManager.default.removeItem(at: item.url)
        }
        cleanStaging()
    }

    func clear() { remove(Set(items.map(\.id))) }

    /// Removes staging folders nothing on the shelf points into.
    func cleanStaging() {
        let live = Set(items.filter(\.staged).map { $0.url.deletingLastPathComponent().resolvingSymlinksInPath().path })
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: Paths.staging, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let old = Date().addingTimeInterval(-600)
        for dir in dirs where !live.contains(dir.resolvingSymlinksInPath().path) {
            let created = (try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let empty = (try? fm.contentsOfDirectory(atPath: dir.path).isEmpty) ?? false
            if created < old || empty { try? fm.removeItem(at: dir) }
        }
    }

    /// A drag out of the square landed somewhere: those items are done.
    func dragEnded(_ ids: [UUID], operation: NSDragOperation) {
        guard !operation.isEmpty else { return }
        // Items still arriving leave once their promised copy has been handed over.
        remove(Set(ids.filter { item($0)?.state != .pending }))
    }

    // MARK: - Promises

    func promiseDelivered(_ url: URL, placeholder: UUID, stack: UUID) {
        if let current = item(placeholder), current.state == .pending {
            mutateItem(placeholder) { $0 = .staged(url, id: placeholder) }
        } else {
            append(.staged(url), toStack: stack)
        }
    }

    func promiseFailed(_ placeholder: UUID, stack id: UUID, error: Error, fallback: Fallback, folder: URL) {
        mutateItem(placeholder) { $0.state = .failed(error.localizedDescription) }
        let stackItems = items(inStack: id)
        guard !stackItems.isEmpty, stackItems.allSatisfy(\.isFailed) else { return }
        let urls = fallback.write(to: folder)
        if urls.isEmpty { remove(Set(stackItems.map(\.id))) } else { replaceItems(ofStack: id, with: urls.map { .staged($0) }) }
    }

    // MARK: - Persistence

    private func stacksChanged() {
        ItemRegistry.shared.update(stacks)
        guard !loading else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func load() {
        loading = true
        defer { loading = false }
        guard let data = try? Data(contentsOf: Paths.stateFile),
              let saved = try? JSONDecoder().decode([ShelfStack].self, from: data) else { return }
        // A promise interrupted by quitting either finished on disk or didn't.
        stacks = saved.compactMap { s in
            var s = s
            s.items = s.items.compactMap { i in
                var i = i
                if i.state == .pending { i.state = .ready }
                return FileManager.default.fileExists(atPath: i.path) || i.bookmark != nil ? i : nil
            }
            return s.items.isEmpty ? nil : s
        }
        ItemRegistry.shared.update(stacks)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(stacks) else { return }
        try? data.write(to: Paths.stateFile, options: .atomic)
    }
}
