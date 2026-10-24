import AppKit

/// Notices drags happening anywhere on screen, without Accessibility permission:
/// a global mouse-down records the drag pasteboard's change count, and while the
/// button is held we poll the pointer and whether a drag has begun.
@MainActor
final class DragWatcher {
    var onStart: (() -> Void)?
    var onMove: ((NSPoint) -> Void)?
    var onEnd: (() -> Void)?
    private(set) var isDragging = false
    private var baseline = NSPasteboard(name: .drag).changeCount
    private var timer: Timer?
    private var monitor: Any?

    init() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged]) { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
        }
    }

    private func handle(_ e: NSEvent) {
        if e.type == .leftMouseDown {
            baseline = NSPasteboard(name: .drag).changeCount
            isDragging = false
        }
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 40, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        if NSEvent.pressedMouseButtons & 1 == 0 {
            timer?.invalidate()
            timer = nil
            if isDragging {
                isDragging = false
                onEnd?()
            }
            return
        }
        if !isDragging, NSPasteboard(name: .drag).changeCount != baseline {
            isDragging = true
            onStart?()
        }
        if isDragging { onMove?(NSEvent.mouseLocation) }
    }
}

/// The menu bar icon: click for the menu, or drop onto it to shelve.
@MainActor
final class StatusItemController {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    weak var square: SquareController?

    init(square: SquareController) {
        self.square = square
        guard let b = item.button else { return }
        let image = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: "Transfer")
        image?.isTemplate = true
        b.image = image
        b.imagePosition = .imageLeading
        b.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let drop = StatusDropView(frame: b.bounds)
        drop.autoresizingMask = [.width, .height]
        drop.owner = self
        b.addSubview(drop)
    }

    func update(count: Int) {
        item.button?.title = count > 0 ? "\(count)" : ""
    }

    func showMenu() {
        guard let square else { return }
        item.menu = square.buildMenu()
        item.button?.performClick(nil)
        item.menu = nil
    }
}

final class StatusDropView: NSView {
    weak var owner: StatusItemController?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(Intake.types)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { owner?.showMenu() }
    override func rightMouseDown(with event: NSEvent) { owner?.showMenu() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !(sender.draggingSource is ShelfDragSource) else { return [] }
        owner?.item.button?.highlight(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { owner?.item.button?.highlight(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        owner?.item.button?.highlight(false)
        guard let square = owner?.square, !(sender.draggingSource is ShelfDragSource) else { return false }
        guard square.drop(sender.draggingPasteboard) else { return false }
        square.reveal()
        return true
    }
}
