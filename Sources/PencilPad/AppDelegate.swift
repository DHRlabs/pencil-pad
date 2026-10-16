import AppKit
import ApplicationServices
import SystemConfiguration

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let targets = Targets()
    private let pen = Pen()
    private lazy var socket = SocketServer(targets: targets, pen: pen)
    private lazy var http = HTTPServer(root: HTTPServer.webRoot())
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = Settings.token  // make and save the link token now, not on first request
        let canPost = CGPreflightPostEventAccess()
        log.notice("launch: post access preflight \(canPost), AX trusted \(AXIsProcessTrusted()), target \(self.targets.current.name, privacy: .public)")
        if !canPost {
            log.notice("launch: requesting post access; request returned \(CGRequestPostEventAccess())")
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "pencil.tip.crop.circle", accessibilityDescription: "PencilPad")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        http.start()
        socket.start()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pen.release(reason: "app quitting")
    }

    private func screensChanged() {
        let changed = targets.refresh()
        log.notice("screens changed: \(self.targets.screens.map(\.name).joined(separator: ", "), privacy: .public)")
        if changed.screens { socket.pushScreens() }
        if changed.target { socket.pushTarget() }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(disabled(socket.active != nil ? "iPad connected" : "Waiting for iPad"))
        menu.addItem(.separator())
        menu.addItem(action("Copy iPad link", #selector(copyLink)))

        let targetMenu = NSMenu()
        for screen in targets.screens {
            let item = action(screen.name, #selector(pickScreen(_:)))
            item.representedObject = screen.id
            item.state = targets.current.id == screen.id ? .on : .off
            targetMenu.addItem(item)
        }
        let window = action("Front window", #selector(pickWindow))
        window.state = targets.current.id == "window" ? .on : .off
        targetMenu.addItem(window)
        let target = NSMenuItem(title: "Target: \(targets.current.name)", action: nil, keyEquivalent: "")
        target.submenu = targetMenu
        menu.addItem(target)

        menu.addItem(.separator())
        if CGPreflightPostEventAccess() && AXIsProcessTrusted() {
            menu.addItem(disabled("Accessibility: allowed"))
        } else {
            menu.addItem(action("Accessibility: not allowed. Open Settings…", #selector(openAccessibility)))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit PencilPad", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func copyLink() {
        let host = (SCDynamicStoreCopyLocalHostName(nil) as String?).map { "\($0).local" } ?? ProcessInfo.processInfo.hostName
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("http://\(host):\(HTTPServer.port.rawValue)/\(Settings.token)/", forType: .string)
    }

    @objc private func pickScreen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, targets.select(id) else { return }
        socket.pushTarget()
    }

    @objc private func pickWindow() {
        guard targets.select("window") else { return }
        socket.pushTarget()
    }

    @objc private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
