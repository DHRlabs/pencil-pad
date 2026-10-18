import AppKit
import ApplicationServices
import ServiceManagement
import SystemConfiguration

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let pen = Pen()
    private lazy var targets = Targets(pen: pen)
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
        openAtLoginByDefault()

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
        menu.addItem(loginMenuItem())
        menu.addItem(.separator())
        menu.addItem(action("Show Board", #selector(showBoard)))
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
        targets.selectFrontWindow { [weak self] ok in
            if ok { self?.socket.pushTarget() }
        }
    }

    @objc private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showBoard() {
        socket.showBoard()
    }

    // MARK: Open at Login

    /// Only the copy in /Applications is ever a login item. A build folder, a worktree or a raw binary never is, so a
    /// development copy cannot end up starting at login (or taking the saved permissions' place).
    private var runsFromApplications: Bool {
        Bundle.main.bundleIdentifier == "com.dhrlabs.pencilpad"
            && Bundle.main.bundleURL.deletingLastPathComponent().path == "/Applications"
    }

    private static func name(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: "enabled"
        case .notRegistered: "not registered"
        case .requiresApproval: "waiting for approval in System Settings"
        case .notFound: "not found"
        @unknown default: "unknown"
        }
    }

    /// The first launch from /Applications opens at login by default, once. After that only the menu item changes it.
    private func openAtLoginByDefault() {
        let service = SMAppService.mainApp
        guard runsFromApplications else {
            log.notice("login item: not registering; running from \(Bundle.main.bundleURL.path, privacy: .public) (status: \(Self.name(service.status), privacy: .public))")
            return
        }
        guard !Settings.loginItemDecided else {
            log.notice("login item: already decided; only the menu changes it (status: \(Self.name(service.status), privacy: .public))")
            return
        }
        guard service.status == .notRegistered || service.status == .notFound else {
            Settings.loginItemDecided = true  // already on, or waiting for approval: nothing for the app to do, ever
            log.notice("login item: already set up (status: \(Self.name(service.status), privacy: .public))")
            return
        }
        do {
            try service.register()
            Settings.loginItemDecided = true
            log.notice("login item: registered by default, once (status: \(Self.name(service.status), privacy: .public))")
        } catch {
            log.error("login item: could not register: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The real status, not a remembered one: checked when enabled, and a note when macOS wants approval.
    private func loginMenuItem() -> NSMenuItem {
        let status = SMAppService.mainApp.status
        guard runsFromApplications else {
            let item = disabled("Open at Login (only from Applications)")
            item.state = status == .enabled ? .on : .off
            return item
        }
        let item = action(status == .requiresApproval ? "Open at Login (approve in System Settings)" : "Open at Login", #selector(toggleLoginItem))
        item.state = status == .enabled ? .on : .off
        return item
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
                log.notice("login item: turned off in the menu")
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            default:
                try service.register()
                log.notice("login item: turned on in the menu (status: \(Self.name(service.status), privacy: .public))")
            }
            Settings.loginItemDecided = true  // from here on the menu is the only thing that changes it
        } catch {
            log.error("login item: \(error.localizedDescription, privacy: .public)")
        }
    }
}
