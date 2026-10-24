import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The whole app on screen: one Dropshelf-style square. Drag something to the left or
/// right edge and it appears; drop onto it to hold things; drag from it to take them all.
@MainActor
final class SquareController {
    static let side: CGFloat = 116

    let store: Store
    let thumbs = Thumbnails()
    let settings = Settings.shared
    weak var status: StatusItemController?
    var drags: DragWatcher?

    private let panel = SquarePanel()
    private var edgeHit: ScreenEdge?
    private var edgeSince: Date?
    /// Shown for the current drag even though the shelf may be empty.
    private var peeking = false
    private var cancellables = Set<AnyCancellable>()

    init(store: Store) {
        self.store = store
        let host = SquareHostingView(rootView: SquareView(store: store, thumbs: thumbs))
        host.controller = self
        panel.install(host)
        PendingPromise.onDelivered = { [weak store] id in store?.remove([id]) }
        store.$stacks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    private func refresh() {
        status?.update(count: store.itemCount)
        guard !peeking else { return }
        if store.stacks.isEmpty { panel.hide() } else { showDocked() }
    }

    // MARK: - Placement

    private var dockScreen: NSScreen {
        NSScreen.screens.first { $0.displayID == settings.dockDisplay } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func screen(containing p: NSPoint) -> NSScreen {
        NSScreen.screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(p) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func frame(edge: ScreenEdge, screen: NSScreen, along: CGFloat) -> NSRect {
        let vf = screen.visibleFrame, side = Self.side, inset: CGFloat = 10
        let y = min(max(along - side / 2, vf.minY + inset), vf.maxY - side - inset)
        let x = min(max(along - side / 2, vf.minX + inset), vf.maxX - side - inset)
        switch edge {
        case .right: return NSRect(x: vf.maxX - side - inset, y: y, width: side, height: side)
        case .left: return NSRect(x: vf.minX + inset, y: y, width: side, height: side)
        case .top: return NSRect(x: x, y: vf.maxY - side - inset, width: side, height: side)
        case .bottom: return NSRect(x: x, y: vf.minY + inset, width: side, height: side)
        }
    }

    /// The screen edge under the pointer, unless another display continues past it.
    private func edge(at p: NSPoint) -> (NSScreen, ScreenEdge)? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(p) }) else { return nil }
        let f = screen.frame, t: CGFloat = 3
        let hit: ScreenEdge
        if p.x <= f.minX + t { hit = .left }
        else if p.x >= f.maxX - t { hit = .right }
        else if p.y >= f.maxY - t { hit = .top }
        else if p.y <= f.minY + t { hit = .bottom }
        else { return nil }
        guard settings.edges.contains(hit) else { return nil }
        let beyond: NSPoint
        switch hit {
        case .left: beyond = NSPoint(x: p.x - 8, y: p.y)
        case .right: beyond = NSPoint(x: p.x + 8, y: p.y)
        case .top: beyond = NSPoint(x: p.x, y: p.y + 8)
        case .bottom: beyond = NSPoint(x: p.x, y: p.y - 8)
        }
        if NSScreen.screens.contains(where: { $0 != screen && $0.frame.contains(beyond) }) { return nil }
        return (screen, hit)
    }

    private func showDocked() {
        let screen = dockScreen, edge = settings.dockEdge
        let along = settings.dockAlong ?? (edge.isVertical ? screen.visibleFrame.midY : screen.visibleFrame.midX)
        panel.show(frame: frame(edge: edge, screen: screen, along: along), edge: edge)
    }

    /// Show the square where it last sat, even if empty.
    func reveal() {
        peeking = true
        showDocked()
    }

    // MARK: - Drags from other apps

    func dragStarted() {
        store.dragActive = true
        edgeHit = nil
        edgeSince = nil
    }

    func dragMoved(_ p: NSPoint) {
        if panel.isVisible, panel.frame.insetBy(dx: -6, dy: -6).contains(p) { return }
        guard let (screen, edge) = edge(at: p) else { edgeHit = nil; return }
        if edgeHit != edge {
            edgeHit = edge
            edgeSince = Date()
            return
        }
        guard let since = edgeSince, Date().timeIntervalSince(since) >= 0.15 else { return }
        let along = edge.isVertical ? p.y : p.x
        settings.dockEdge = edge
        settings.dockDisplay = screen.displayID
        settings.dockAlong = along
        peeking = true
        panel.show(frame: frame(edge: edge, screen: screen, along: along), edge: edge)
        edgeHit = nil
    }

    func dragEnded() {
        store.dragActive = false
        edgeHit = nil
        guard peeking else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.drags?.isDragging != true else { return }
            self.peeking = false
            self.refresh()
        }
    }

    func drop(_ pb: NSPasteboard) -> Bool {
        Intake.ingest(pb, into: store) != nil
    }

    // MARK: - Dragging out

    func dragOut(event: NSEvent, in view: NSView, source: NSDraggingSource) {
        let items = store.items.filter { !$0.isFailed }
        guard !items.isEmpty else { return }
        let p = view.convert(event.locationInWindow, from: nil)
        var dragging: [NSDraggingItem] = []
        for (i, item) in items.enumerated() {
            // Still arriving: hand out a promise that's kept once it lands.
            let writer: NSPasteboardWriting = item.state == .pending
                ? PendingPromise(item: item).provider
                : store.url(for: item) as NSURL
            let d = NSDraggingItem(pasteboardWriter: writer)
            let o = CGFloat(min(i, 3)) * 5
            d.setDraggingFrame(NSRect(x: p.x - 28 + o, y: p.y - 28 - o, width: 56, height: 56),
                               contents: thumbs.image(for: item))
            dragging.append(d)
        }
        store.draggingItemIDs = items.map(\.id)
        let session = view.beginDraggingSession(with: dragging, event: event, source: source)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = items.count > 1 ? .stack : .none
    }

    func dragOutEnded(_ operation: NSDragOperation) {
        let ids = store.draggingItemIDs
        store.draggingItemIDs = []
        store.dragEnded(ids, operation: operation)
    }

    // MARK: - Menu

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let clear = MenuItem("Clear") { [weak self] in self?.store.clear() }
        clear.isEnabled = !store.stacks.isEmpty
        menu.addItem(clear)
        menu.addItem(.separator())
        menu.addItem(MenuItem("Launch at Login", on: settings.launchAtLogin) { [weak self] in
            guard let self else { return }
            self.settings.launchAtLogin = !self.settings.launchAtLogin
        })
        menu.addItem(MenuItem("Quit Transfer") { NSApp.terminate(nil) })
        return menu
    }

    func popUpMenu(with event: NSEvent, in view: NSView) {
        NSMenu.popUpContextMenu(buildMenu(), with: event, for: view)
    }
}

// MARK: - Window

final class SquarePanel: NSPanel {
    private let fx = NSVisualEffectView()
    private var shown = false

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: SquareController.side, height: SquareController.side),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        fx.material = .popover
        fx.state = .active
        fx.blendingMode = .behindWindow
        fx.maskImage = Self.mask(radius: 16)
    }

    override var canBecomeKey: Bool { false }

    func install(_ content: NSView) {
        content.frame = fx.bounds
        content.autoresizingMask = [.width, .height]
        fx.addSubview(content)
        contentView = fx
    }

    func show(frame: NSRect, edge: ScreenEdge) {
        alphaValue = 1
        if shown {
            guard frame != self.frame else { return }
            NSAnimationContext.runAnimationGroup { c in
                c.duration = 0.16
                animator().setFrame(frame, display: true)
            }
            return
        }
        shown = true
        // Slide in from the edge.
        var start = frame
        switch edge {
        case .right: start.origin.x += frame.width + 10
        case .left: start.origin.x -= frame.width + 10
        case .top: start.origin.y += frame.height + 10
        case .bottom: start.origin.y -= frame.height + 10
        }
        setFrame(start, display: false)
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.16
            c.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(frame, display: true)
        }
    }

    func hide() {
        guard shown else { return }
        shown = false
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.12
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.shown else { return }
                self.orderOut(nil)
                self.alphaValue = 1
            }
        })
    }

    static func mask(radius r: CGFloat) -> NSImage {
        let d = r * 2 + 2
        let img = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            NSColor.black.set()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }
}

/// Marks drags that started on the square, so it doesn't take them back in.
protocol ShelfDragSource: AnyObject {}

/// Hosts the square's look and takes drops.
final class SquareHostingView: NSHostingView<SquareView> {
    weak var controller: SquareController? { didSet { mouse.controller = controller } }
    private let mouse = SquareMouseView()

    required init(rootView: SquareView) {
        super.init(rootView: rootView)
        registerForDraggedTypes(Intake.types)
        mouse.frame = bounds
        mouse.autoresizingMask = [.width, .height]
        addSubview(mouse)
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError() }

    private func accepts(_ s: NSDraggingInfo) -> Bool { !(s.draggingSource is ShelfDragSource) }

    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation {
        guard accepts(s) else { return [] }
        controller?.store.targeted = true
        return .copy
    }

    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation { accepts(s) ? .copy : [] }
    override func draggingExited(_ s: NSDraggingInfo?) { controller?.store.targeted = false }
    override func draggingEnded(_ s: NSDraggingInfo) { controller?.store.targeted = false }

    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        controller?.store.targeted = false
        guard accepts(s) else { return false }
        return controller?.drop(s.draggingPasteboard) ?? false
    }
}

/// Mouse on the square: drag takes everything, right-click for the menu.
final class SquareMouseView: NSView, NSDraggingSource, ShelfDragSource {
    weak var controller: SquareController?
    private var down: NSEvent?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { down = event }
    override func mouseUp(with event: NSEvent) { down = nil }
    override func rightMouseDown(with event: NSEvent) { controller?.popUpMenu(with: event, in: self) }

    override func mouseDragged(with event: NSEvent) {
        guard let start = down else { return }
        let a = start.locationInWindow, b = event.locationInWindow
        guard hypot(a.x - b.x, a.y - b.y) > 3 else { return }
        down = nil
        controller?.dragOut(event: start, in: self, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Same as dragging out of Finder: move on the same disk, copy across disks, ⌥ copies.
        context == .outsideApplication ? [.copy, .move, .generic, .link] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        controller?.dragOutEnded(operation)
    }
}

/// Blue striped square; the newest files sit fanned out on top of it.
struct SquareView: View {
    @ObservedObject var store: Store
    @ObservedObject var thumbs: Thumbnails

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let hot = store.targeted
        let items = Array(store.items.prefix(3))
        ZStack {
            Group {
                shape.fill(Color.accentColor.opacity(hot ? 0.32 : 0.16))
                Canvas { ctx, size in
                    var path = Path()
                    var x = -size.height
                    while x < size.width {
                        path.move(to: CGPoint(x: x, y: size.height))
                        path.addLine(to: CGPoint(x: x + size.height, y: 0))
                        x += 16
                    }
                    ctx.stroke(path, with: .color(Color.accentColor.opacity(hot ? 0.45 : 0.28)), lineWidth: 6)
                }
                .clipShape(shape)
                shape.strokeBorder(Color.accentColor, lineWidth: 3)
            }
            if !items.isEmpty {
                ZStack {
                    ForEach(Array(items.enumerated().reversed()), id: \.offset) { i, item in
                        Image(nsImage: thumbs.image(for: item))
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 64, maxHeight: 64)
                            .rotationEffect(.degrees(Double(i) * -7))
                            .offset(x: CGFloat(i) * -6, y: CGFloat(i) * -2)
                            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    }
                }
                .opacity(store.items.contains { $0.state == .pending } ? 0.5 : 1)
                if store.items.contains(where: { $0.state == .pending }) {
                    ProgressView().controlSize(.small)
                }
                if store.itemCount > 1 {
                    Text("\(store.itemCount)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.regularMaterial, in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(9)
                }
            }
        }
        .scaleEffect(hot ? 1.04 : 1)
        .animation(.easeOut(duration: 0.12), value: hot)
        .task(id: items.map(\.path)) { for i in items { thumbs.load(i) } }
    }
}

/// A file promise for an item the shelf is itself still receiving.
final class PendingPromise: NSObject, NSFilePromiseProviderDelegate {
    @MainActor static var live: [UUID: PendingPromise] = [:]
    /// Called on the main thread once a promised copy has been written out.
    @MainActor static var onDelivered: ((UUID) -> Void)?
    static let queue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        return q
    }()

    let itemID: UUID
    let name: String
    private(set) var provider: NSFilePromiseProvider!

    @MainActor
    init(item: ShelfItem) {
        itemID = item.id
        name = item.name
        super.init()
        let type = UTType(filenameExtension: (name as NSString).pathExtension)?.identifier ?? UTType.data.identifier
        provider = NSFilePromiseProvider(fileType: type, delegate: self)
        PendingPromise.live[itemID] = self
    }

    func filePromiseProvider(_ p: NSFilePromiseProvider, fileNameForType fileType: String) -> String { name }

    func operationQueue(for p: NSFilePromiseProvider) -> OperationQueue { Self.queue }

    func filePromiseProvider(_ p: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        var result: Error? = OpError("\(name) was taken off the shelf")
        let deadline = Date().addingTimeInterval(3600)
        while Date() < deadline {
            guard let (state, path) = ItemRegistry.shared.get(itemID) else { break }
            if state == .ready {
                do {
                    try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: url)
                    result = nil
                } catch {
                    result = error
                }
                break
            }
            if case .failed(let m) = state { result = OpError(m); break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        completionHandler(result)
        let id = itemID, delivered = result == nil
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                PendingPromise.live[id] = nil
                if delivered { PendingPromise.onDelivered?(id) }
            }
        }
    }
}

final class MenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, on: Bool = false, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        state = on ? .on : .off
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
