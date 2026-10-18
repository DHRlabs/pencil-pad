import SwiftUI

private let accent = Color(red: 0.25, green: 0.85, blue: 1)

extension View {
    /// Liquid Glass where the system has it, a material before that.
    @ViewBuilder
    func glass<S: Shape>(_ shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}

/// The page's palm rule, for the toolbar and the window list: a contact wider than 30 points across, or a second finger down,
/// makes the press that follows do nothing. This watches every touch that begins in the window (it never takes one and never
/// delays one) and tells the session; the buttons ask the session before they act (`Session.press`).
private struct PalmWatcher: UIViewRepresentable {
    let s: Session
    func makeUIView(context: Context) -> PalmWatcherView { PalmWatcherView(session: s) }
    func updateUIView(_ view: PalmWatcherView, context: Context) {}
}

private final class PalmWatcherView: UIView {
    private let session: Session
    private var watcher: UIGestureRecognizer?

    init(session: Session) {
        self.session = session
        super.init(frame: .zero)
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let watcher { watcher.view?.removeGestureRecognizer(watcher) }
        watcher = nil
        guard let window else { return }
        let g = Watcher(session: session)
        g.cancelsTouchesInView = false
        g.delaysTouchesBegan = false
        g.delaysTouchesEnded = false
        window.addGestureRecognizer(g)
        watcher = g
    }
}

private final class Watcher: UIGestureRecognizer {
    private let session: Session
    init(session: Session) {
        self.session = session
        super.init(target: nil, action: nil)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        let fingers = (event.allTouches ?? touches).filter { $0.type == .direct }
        session.palmPress = fingers.count > 1 || fingers.contains { 2 * contactRadius($0) > Tuning.palm }
        state = .failed  // it only looks
    }
}

/// Where the Window chip sits, so its list opens under it.
private struct WindowChipFrame: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// Everything drawn over the surface. Touches fall through to the surface wherever nothing is drawn, and the toolbar
/// ignores touches while the Pencil is down (a palm or a slip must not press a button mid-stroke).
struct Chrome: View {
    let s: Session
    @State private var chip = CGRect.zero

    var body: some View {
        ZStack(alignment: .top) {
            if s.phase == .needsPairing || s.phase == .denied {
                PairingView(s: s)
            } else {
                VStack(spacing: 0) {
                    Toolbar(s: s)
                        .padding(.top, s.safeTop + Tuning.barInset)
                        .padding(.horizontal, 12)
                    Spacer(minLength: 0)
                }
                .allowsHitTesting(!s.pencilDown)
                if s.windowsOpen { WindowMenu(s: s, anchor: chip).allowsHitTesting(!s.pencilDown) }
                if s.phase != .live { StatusCard(s: s).allowsHitTesting(!s.pencilDown) }
                Badge(s: s)
            }
            ToastView(text: s.toast)
        }
        .background(PalmWatcher(s: s))
        .coordinateSpace(name: "chrome")
        .onPreferenceChange(WindowChipFrame.self) { chip = $0 }
    }
}

// MARK: Toolbar

private struct Toolbar: View {
    let s: Session

    var body: some View {
        HStack(spacing: 6) {
            StatusPill(s: s)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(s.chips) { c in
                        Chip(c: c) { s.press { s.tapChip(c.id) } }
                            .background(c.isWindow ? AnyView(GeometryReader { g in
                                Color.clear.preference(key: WindowChipFrame.self, value: g.frame(in: .named("chrome")))
                            }) : AnyView(EmptyView()))
                    }
                    Rule()
                    IconButton(symbol: "arrow.uturn.backward", label: "Undo") { s.press { s.sendKey("undo") } }
                    IconButton(symbol: "arrow.uturn.forward", label: "Redo") { s.press { s.sendKey("redo") } }
                    TextButton(text: "esc", label: "Escape") { s.press { s.sendKey("escape") } }
                    IconButton(symbol: "cursorarrow.click.2", label: "Right-click, once", on: s.rightArmed) { s.press { s.toggleRight() } }
                    Rule()
                    TextButton(text: "Aim \(s.aim.name)", label: "Aim \(s.aim.name). \(s.aimNote)", symbol: "scope", on: s.aim != .off) { s.press { s.cycleAim() } }
                    ZoomButton(s: s)
                    IconButton(symbol: s.showOn ? "eye" : "eye.slash", label: "Show the Mac's picture", on: s.showOn) { s.press { s.toggleShow() } }
                    if s.pageURL != nil {
                        Rule()
                        IconButton(symbol: "pencil.and.scribble", label: "Open Board in Safari") { s.press { s.openBoard() } }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Tuning.barHeight)
        .glass(Capsule())
    }
}

private struct Rule: View {
    var body: some View {
        Capsule().fill(.white.opacity(0.18)).frame(width: 1, height: 22).padding(.horizontal, 2)
    }
}

private struct StatusPill: View {
    let s: Session

    private var text: String {
        switch s.phase {
        case .live: s.macName
        case .connecting: "Connecting"
        case .retrying: "Reconnecting"
        case .searching: "Searching"
        case .choosing: "Choose a Mac"
        case .replaced: "Open elsewhere"
        case .needsPairing, .denied: "Not paired"
        }
    }

    private var color: Color {
        switch s.phase {
        case .live: .green
        case .connecting, .retrying, .searching, .choosing: .orange
        case .replaced, .needsPairing, .denied: .red
        }
    }

    var body: some View {
        Menu {
            Section("Macs nearby") {
                if s.found.isEmpty { Text("None found") }
                ForEach(s.found) { mac in
                    Button { s.press { s.choose(mac) } } label: {
                        if mac.name == s.macName { Label(mac.name, systemImage: "checkmark") } else { Text(mac.name) }
                    }
                }
            }
            Button("Pair again…", systemImage: "link") { s.press { s.pairAgain() } }
        } label: {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 9, height: 9)
                Text(text).font(.subheadline.weight(.semibold)).lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .foregroundStyle(.white)
        .accessibilityLabel("Connection: \(text)")
    }
}

private struct Chip: View {
    let c: ChipItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(c.label).font(.subheadline.weight(.medium)).lineLimit(1)
                if c.isWindow { Image(systemName: "chevron.down").font(.caption2.weight(.bold)).opacity(c.active ? 1 : 0.5) }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(c.active ? accent.opacity(0.28) : .white.opacity(c.pending ? 0.14 : 0.0), in: Capsule())
            .overlay(Capsule().stroke(c.active ? accent.opacity(0.9) : .clear, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel(c.hint)
    }
}

private struct IconButton: View {
    let symbol: String
    let label: String
    var on = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium))
                .frame(width: 42, height: 38)
                .background(on ? accent.opacity(0.28) : .clear, in: Capsule())
                .overlay(Capsule().stroke(on ? accent.opacity(0.9) : .clear, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel(label)
    }
}

private struct TextButton: View {
    let text: String
    let label: String
    var symbol: String?
    var on = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 15, weight: .medium)) }
                Text(text).font(.subheadline.weight(.medium)).lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(on ? accent.opacity(0.28) : .clear, in: Capsule())
            .overlay(Capsule().stroke(on ? accent.opacity(0.9) : .clear, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel(label)
    }
}

/// A tap arms one pinch or drag; a press held for 0.6 s shows the whole target again.
private struct ZoomButton: View {
    let s: Session

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "plus.magnifyingglass").font(.system(size: 17, weight: .medium))
            if s.zoomLevel > 1.005 { Text(String(format: "%.1f×", s.zoomLevel)).font(.subheadline.weight(.medium)) }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(s.zoomArmed ? accent.opacity(0.28) : .clear, in: Capsule())
        .overlay(Capsule().stroke(s.zoomArmed ? accent.opacity(0.9) : .clear, lineWidth: 1))
        .contentShape(Capsule())
        .foregroundStyle(.white)
        .onTapGesture { s.press { s.toggleZoom() } }
        .onLongPressGesture(minimumDuration: Tuning.zoomHold) { s.press { s.resetZoom() } }
        .accessibilityElement()
        .accessibilityLabel("Zoom. Tap, then pinch or drag. Hold to show the whole screen")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: Window list

private struct WindowMenu: View {
    let s: Session
    let anchor: CGRect

    private func text(_ w: WindowItem) -> String { w.title.isEmpty ? w.app : "\(w.app): \(w.title)" }

    var body: some View {
        let counts = Dictionary(s.windows.map { (text($0), 1) }, uniquingKeysWith: +)
        GeometryReader { g in
            let width: CGFloat = 360
            let top = s.safeTop + Tuning.barInset + Tuning.barHeight + 8
            let left = max(10, min(anchor.minX, g.size.width - width - 10))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !s.windowsLoaded {
                        Text("Loading windows…").foregroundStyle(.secondary).padding(14)
                    } else if s.windows.isEmpty {
                        Text("No windows").foregroundStyle(.secondary).padding(14)
                    }
                    ForEach(s.windows) { w in
                        Button { s.press { s.pick(window: w.id) } } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark").opacity(w.current ? 1 : 0).frame(width: 18)
                                Text((counts[text(w)] ?? 1) > 1 ? "\(text(w)) (\(w.w)×\(w.h))" : text(w)).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .foregroundStyle(.white)
            .frame(width: width)
            .frame(maxHeight: max(88, g.size.height - top - 14))
            .fixedSize(horizontal: false, vertical: true)
                .glass(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .offset(x: left, y: top)
        }
    }
}

// MARK: Status

private struct StatusCard: View {
    let s: Session

    var body: some View {
        VStack(spacing: 14) {
            switch s.phase {
            case .replaced:
                Text("PencilPad is open somewhere else").font(.headline)
                Text("Another page or iPad took over this Mac.").font(.subheadline).foregroundStyle(.secondary)
                Button("Take over") { s.takeOver() }.buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black)
            case .connecting, .retrying:
                ProgressView()
                Text(s.phase == .retrying ? "Reconnecting to \(s.macName)…" : "Connecting to \(s.macName)…").font(.headline)
            default:  // searching, choosing
                if s.found.isEmpty { ProgressView() }
                Text(s.phase == .choosing ? "Choose your Mac" : "Looking for \(s.macName)…").font(.headline)
                if s.found.isEmpty {
                    Text(s.searchBlocked
                         ? "Allow Local Network for PencilPad in Settings, and check that Wi-Fi is on."
                         : "PencilPad must be running on the Mac. No shared Wi-Fi network is needed, but Wi-Fi and Bluetooth must be on, on both.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                ForEach(s.found) { mac in
                    Button { s.choose(mac) } label: {
                        Label(mac.name, systemImage: "desktopcomputer").frame(minWidth: 240, minHeight: 28)
                    }
                    .buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(28)
        .frame(maxWidth: 440)
        .glass(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .frame(maxHeight: .infinity)
    }
}

private struct Badge: View {
    let s: Session

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                if s.fps > 0 {
                    Text("\(s.fps) fps").font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .glass(Capsule())
                }
            }
            .padding(.trailing, 24).padding(.bottom, 22)
        }
        .allowsHitTesting(false)
    }
}

private struct ToastView: View {
    let text: String?

    var body: some View {
        VStack {
            Spacer()
            if let text {
                Text(text).font(.subheadline.weight(.medium)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glass(Capsule())
                    .transition(.opacity)
            }
        }
        .padding(.bottom, 44)
        .animation(.easeInOut(duration: 0.2), value: text)
        .allowsHitTesting(false)
    }
}

// MARK: Pairing

private struct PairingView: View {
    let s: Session

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.06)
            VStack(spacing: 22) {
                Image(systemName: "pencil.tip.crop.circle").font(.system(size: 64, weight: .light)).foregroundStyle(accent)
                Text("Pair with your Mac").font(.largeTitle.bold())
                Text("On the Mac, click the PencilPad icon in the menu bar and choose Copy iPad link. It reaches this iPad through the shared clipboard. Then tap Paste.")
                    .font(.title3).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 560)
                PasteButton(payloadType: String.self) { strings in
                    if let text = strings.first { s.pair(with: text) }
                }
                .buttonBorderShape(.capsule).controlSize(.large).tint(accent)
                if let note = s.pairingNote {
                    Text(note).font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center).frame(maxWidth: 520)
                }
                VStack(spacing: 6) {
                    Text("Macs nearby").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    if s.found.isEmpty {
                        Text(s.searchBlocked ? "Allow Local Network for PencilPad in Settings" : "Looking…").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(s.found) { mac in Label(mac.name, systemImage: "desktopcomputer").font(.callout) }
                }
                .padding(.top, 8)
            }
            .foregroundStyle(.white)
            .padding(32)
        }
    }
}
