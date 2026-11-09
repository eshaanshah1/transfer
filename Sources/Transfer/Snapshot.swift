import AppKit
import SwiftUI

/// `Transfer --snapshot <dir>`: renders the square's states to PNGs, for checking the
/// look without screen-recording permission.
@MainActor
enum Snapshot {
    static func start(_ dir: String) {
        _ = NSApplication.shared
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let store = Store()
        let thumbs = Thumbnails()

        func render(_ name: String) {
            let r = ImageRenderer(content: SquareView(store: store, thumbs: thumbs)
                .frame(width: SquareController.side, height: SquareController.side)
                .background(Color.clear,
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(24)
                .background(Color(red: 0.17, green: 0.19, blue: 0.19)))
            r.scale = 2
            if let cg = r.cgImage {
                try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                    .write(to: out.appendingPathComponent(name))
            }
        }

        store.dragActive = true
        render("square-empty.png")
        store.targeted = true
        render("square-hover.png")
        store.targeted = false
        store.dragActive = false

        let samples = Paths.support.appendingPathComponent("samples", isDirectory: true)
        try? FileManager.default.createDirectory(at: samples, withIntermediateDirectories: true)
        var urls: [URL] = []
        for (i, hue) in [0.58, 0.08, 0.33].enumerated() {
            let url = samples.appendingPathComponent("IMG_\(2041 + i).jpg")
            let img = NSImage(size: NSSize(width: 600, height: 400), flipped: false) { r in
                NSColor(hue: hue, saturation: 0.45, brightness: 0.9, alpha: 1).setFill(); r.fill()
                NSColor(hue: hue, saturation: 0.7, brightness: 0.6, alpha: 1).setFill()
                NSBezierPath(ovalIn: NSRect(x: 180, y: 90, width: 240, height: 240)).fill()
                return true
            }
            try? NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .jpeg, properties: [:])?.write(to: url)
            urls.append(url)
        }
        store.add(urls.reversed().map { .reference($0) })
        for i in store.items { thumbs.load(i) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            render("square-full.png")
            exit(0)
        }
        RunLoop.main.run()
    }
}
