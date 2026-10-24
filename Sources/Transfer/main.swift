import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    private var square: SquareController!
    private var status: StatusItemController!
    private var drags: DragWatcher!

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.load()
        store.cleanStaging()

        square = SquareController(store: store)
        status = StatusItemController(square: square)
        square.status = status
        status.update(count: store.itemCount)

        drags = DragWatcher()
        drags.onStart = { [weak self] in self?.square.dragStarted() }
        drags.onMove = { [weak self] p in self?.square.dragMoved(p) }
        drags.onEnd = { [weak self] in self?.square.dragEnded() }
        square.drags = drags
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.save()
    }
}

MainActor.assumeIsolated {
    if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
        Snapshot.start(CommandLine.arguments[i + 1])
    } else if CommandLine.arguments.contains("--selftest") {
        SelfTest.start()
        RunLoop.main.run()
    } else {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
