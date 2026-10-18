import AppKit

/// A transparent, click-through window that is only ever the outline on screen.
private final class OutlinePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    /// Never nudged back under the menu bar or onto another screen: it sits exactly where the region is.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class OutlineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        // The page's cyan. The stroke's outer edge is the region's edge.
        NSColor(srgbRed: 51 / 255, green: 240 / 255, blue: 255 / 255, alpha: 0.95).setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 5, yRadius: 5)
        path.lineWidth = 3
        path.stroke()
    }
}

/// Where the iPad is zoomed to, drawn on the Mac for a moment: 1.5 s after the last region message, then a 0.3 s
/// fade. It never takes a click and never takes focus; it only shows.
@MainActor
final class RegionOutline {
    private let targets: Targets
    private let panel: OutlinePanel
    private var fade: Task<Void, Never>?
    /// The zoomed part of the target, 0 to 1 of it; nil while the whole target is shown. Kept after the outline fades.
    private(set) var region: CGRect?

    init(targets: Targets) {
        self.targets = targets
        panel = OutlinePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.contentView = OutlineView()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.sharingType = .none  // out of screen shares and captures: it is only for the person at the Mac
        panel.hidesOnDeactivate = false  // this app is never active
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver  // above normal windows, the Dock and the menu bar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    /// A region message. The whole target hides the outline; anything else shows it.
    func set(_ r: CGRect) {
        if r.minX <= 0.001, r.minY <= 0.001, r.width >= 0.999, r.height >= 0.999 {
            region = nil
            hide()
        } else {
            region = r
            show(for: 1.5)
        }
    }

    /// Shows the outline again for a second (the Pencil came back after a while), if the iPad is zoomed.
    func flash() {
        if region != nil { show(for: 1) }
    }

    /// The client is gone or the zoom was undone: nothing to remember, nothing to show.
    func reset() {
        region = nil
        hide()
    }

    private func hide() {
        fade?.cancel()
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    private func show(for seconds: TimeInterval) {
        guard let region else { return }
        let rect = targets.current.rect  // global, top-left origin, points
        let box = CGRect(x: rect.minX + region.minX * rect.width, y: rect.minY + region.minY * rect.height,
                         width: region.width * rect.width, height: region.height * rect.height)
        // Window frames are bottom-left: flip against the height of the screen that holds the menu bar (the first).
        guard let primary = NSScreen.screens.first else { return }
        let frame = NSRect(x: box.minX, y: primary.frame.height - box.maxY, width: box.width, height: box.height)
        fade?.cancel()
        panel.setFrame(frame, display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        log.debug("outline: region \(NSStringFromRect(region), privacy: .public) of \(self.targets.current.name, privacy: .public) at \(NSStringFromRect(frame), privacy: .public) for \(seconds) s")
        fade = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            for step in 1...15 {  // 0.3 s
                guard !Task.isCancelled, let self else { return }
                panel.alphaValue = 1 - CGFloat(step) / 15
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard !Task.isCancelled, let self else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
    }
}
