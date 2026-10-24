import AppKit
import ServiceManagement

/// Where the square sits, and launch at login.
@MainActor
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    /// Screen edges that bring up the square while dragging.
    let edges: Set<ScreenEdge> = [.left, .right]

    var dockEdge: ScreenEdge {
        get { ScreenEdge(rawValue: d.string(forKey: "dockEdge") ?? "") ?? .right }
        set { d.set(newValue.rawValue, forKey: "dockEdge") }
    }
    var dockAlong: CGFloat? {
        get { (d.object(forKey: "dockAlong") as? Double).map { CGFloat($0) } }
        set { d.set(newValue.map { Double($0) }, forKey: "dockAlong") }
    }
    var dockDisplay: CGDirectDisplayID? {
        get { (d.object(forKey: "dockDisplay") as? Int).map { CGDirectDisplayID($0) } }
        set { d.set(newValue.map { Int($0) }, forKey: "dockDisplay") }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Transfer: launch at login: \(error)")
            }
        }
    }
}
