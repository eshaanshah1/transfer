import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The whole app on screen: one Dropshelf-style square. Drag something to the left or
/// right edge and it appears; drop onto it to hold things; drag from it to take them all.
@MainActor
final class SquareController {
    static let side: CGFloat = 132

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
        // The stack in hand leaves as one picture, right where it's sitting, so it looks
        // like the same cards coming off the folder. The rest ride along unseen.
        let center = store.hand ?? handPoint(pressedAt: view.convert(event.locationInWindow, from: nil), in: view)
        let picture = handPicture(items, scale: view.window?.backingScaleFactor ?? 2)
        let side = SquareController.side
        let box = NSRect(x: center.x - side / 2, y: side - center.y - side / 2, width: side, height: side)
        var dragging: [NSDraggingItem] = []
        for (i, item) in items.enumerated() {
            // Still arriving: hand out a promise that's kept once it lands.
            let writer: NSPasteboardWriting = item.state == .pending
                ? PendingPromise(item: item).provider
                : store.url(for: item) as NSURL
            let d = NSDraggingItem(pasteboardWriter: writer)
            d.setDraggingFrame(box, contents: i == 0 ? picture : nil)
            dragging.append(d)
        }
        store.hand = nil
        store.draggingItemIDs = items.map(\.id)
        let session = view.beginDraggingSession(with: dragging, event: event, source: source)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }

    /// Mouse down: the files come out of the folder and into your hand.
    func press(event: NSEvent, in view: NSView) {
        guard store.items.contains(where: { !$0.isFailed }) else { return }
        store.hand = handPoint(pressedAt: view.convert(event.locationInWindow, from: nil), in: view)
        NSCursor.closedHand.set()
    }

    /// Let go without dragging: they drop back in.
    func release() {
        store.hand = nil
        NSCursor.arrow.set()
    }

    /// Where the stack sits for a press, in SwiftUI's top-down coordinates, kept whole inside the window.
    private func handPoint(pressedAt p: NSPoint, in view: NSView) -> CGPoint {
        let side = Self.side
        return CGPoint(x: min(max(p.x, 42), side - 42), y: min(max(view.bounds.height - p.y - 8, 46), side - 46))
    }

    private func handPicture(_ items: [ShelfItem], scale: CGFloat) -> NSImage? {
        let r = ImageRenderer(content: CardFan(items: Array(items.prefix(3)), thumbs: thumbs, places: CardPlace.hand, scale: CardPlace.handScale)
            .frame(width: Self.side, height: Self.side))
        r.scale = scale
        return r.cgImage.map { NSImage(cgImage: $0, size: NSSize(width: Self.side, height: Self.side)) }
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
    private var shown = false

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: SquareController.side, height: SquareController.side),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        backgroundColor = .clear
        isOpaque = false
        // The folder isn't square, so it draws its own shadow.
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }

    func install(_ content: NSView) {
        contentView = content
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
    override func mouseDown(with event: NSEvent) {
        down = event
        controller?.press(event: event, in: self)
    }
    override func mouseUp(with event: NSEvent) {
        down = nil
        controller?.release()
    }
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

/// A blue folder: the newest files stand in it as white-edged cards, and they show
/// blurred through its frosted front.
struct SquareView: View {
    @ObservedObject var store: Store
    @ObservedObject var thumbs: Thumbnails

    private static let blue = Color(red: 0.30, green: 0.67, blue: 0.98)
    private static let size = CGSize(width: 116, height: 100)

    var body: some View {
        let hot = store.targeted
        let items = Array(store.items.prefix(3))
        let pending = store.items.contains { $0.state == .pending }
        // Out of the folder: in hand, or already gone with the drag.
        let away = store.hand != nil || !store.draggingItemIDs.isEmpty
        let inHand = store.items.filter { !$0.isFailed }.prefix(3)
        let center = SquareController.side / 2
        ZStack {
            // Nearly invisible, so the window's corners still take drops and clicks.
            Color.black.opacity(0.01)
            ZStack {
                // Back of the folder.
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Self.blue)
                    .padding(EdgeInsets(top: 0, leading: 4, bottom: 12, trailing: 4))
                cards(items, hot: hot).opacity(away ? 0 : 1)
                // Frosted front: the same cards again, blurred and clipped to the front's shape.
                ZStack {
                    Self.blue
                    cards(items, hot: hot).blur(radius: 6).opacity(away ? 0 : 1)
                    Self.blue.opacity(0.3)
                }
                .clipShape(FolderFront())
                .overlay(FolderFront().stroke(
                    LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0.3)], startPoint: .top, endPoint: .bottom),
                    lineWidth: 1))
                if pending {
                    ProgressView().controlSize(.small).offset(y: 18)
                }
                if store.itemCount > 1 {
                    Text("\(store.itemCount)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.black.opacity(0.85))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color(white: 0.96), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(8)
                }
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .compositingGroup()
            .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
            .scaleEffect(hot ? 1.04 : 1)
            // The stack in hand, sharp and in front of the folder. The drag takes over from
            // it at the same spot, so it vanishes without animating then.
            CardFan(items: Array(inHand), thumbs: thumbs,
                    places: store.hand == nil ? CardPlace.folder : CardPlace.hand,
                    scale: store.hand == nil ? 1 : CardPlace.handScale)
                .offset(x: (store.hand?.x ?? center) - center, y: (store.hand?.y ?? center) - center)
                .opacity(store.hand == nil ? 0 : 1)
                .animation(store.draggingItemIDs.isEmpty ? .spring(response: 0.22, dampingFraction: 0.72) : nil,
                           value: store.hand)
        }
        .animation(.easeOut(duration: 0.12), value: hot)
        .animation(.easeOut(duration: 0.12), value: away)
        .task(id: items.map(\.path)) { for i in items { thumbs.load(i) } }
    }

    /// The cards standing in the folder. They rise while something hovers.
    private func cards(_ items: [ShelfItem], hot: Bool) -> some View {
        CardFan(items: items, thumbs: thumbs, places: CardPlace.folder, scale: 1)
            .offset(y: hot ? -5 : 0)
            .opacity(store.items.contains { $0.state == .pending } ? 0.6 : 1)
    }
}

/// Where a card sits, relative to the middle of the view. Newest first.
struct CardPlace {
    let x: CGFloat, y: CGFloat, angle: Double

    /// Spread out across the folder.
    static let folder = [CardPlace(x: -20, y: -11, angle: -8), CardPlace(x: 7, y: -13, angle: -3), CardPlace(x: 29, y: -12, angle: 4)]
    /// Gathered into one stack.
    static let hand = [CardPlace(x: 0, y: 0, angle: -4), CardPlace(x: 4, y: -2, angle: 2), CardPlace(x: 8, y: -4, angle: 8)]
    static let handScale: CGFloat = 1.2
}

/// Up to three files as cards, the newest on top.
struct CardFan: View {
    let items: [ShelfItem]
    @ObservedObject var thumbs: Thumbnails
    let places: [CardPlace]
    let scale: CGFloat

    var body: some View {
        ZStack {
            ForEach(Array(items.enumerated().reversed()), id: \.offset) { i, item in
                FolderCard(image: thumbs.image(for: item), isThumbnail: thumbs.images[item.path] != nil)
                    .scaleEffect(scale)
                    .rotationEffect(.degrees(places[i].angle))
                    .offset(x: places[i].x, y: places[i].y)
            }
        }
    }
}

/// One file in the folder: a thumbnail filling a white-edged card, or an icon sitting on one.
private struct FolderCard: View {
    let image: NSImage
    let isThumbnail: Bool

    var body: some View {
        let width: CGFloat = 46, height: CGFloat = 62, edge: CGFloat = 4
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(white: 0.96))
            if isThumbnail {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width - edge * 2, height: height - edge * 2)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: width - edge * 2)
                    // Up where the folder's front doesn't hide it.
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, edge)
            }
        }
        .frame(width: width, height: height)
        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
    }
}

/// The folder's front: a tab on the left that curves down into a lower right shoulder.
private struct FolderFront: Shape {
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 11, tabTop = rect.minY + 21, shoulder = rect.minY + 34
        let curveStart = rect.minX + rect.width * 0.46, curveEnd = rect.minX + rect.width * 0.64
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: tabTop + r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: tabTop), control: CGPoint(x: rect.minX, y: tabTop))
        p.addLine(to: CGPoint(x: curveStart, y: tabTop))
        p.addCurve(to: CGPoint(x: curveEnd, y: shoulder),
                   control1: CGPoint(x: curveStart + 11, y: tabTop),
                   control2: CGPoint(x: curveEnd - 11, y: shoulder))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: shoulder))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: shoulder + r), control: CGPoint(x: rect.maxX, y: shoulder))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
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
