import SwiftUI
import UIKit

/// The drawing surface: a plain UIView, so every Pencil sample goes straight from the touch to the socket. It owns the
/// picture layer, the ink trail and the hover reticle; what the touches mean lives in `Session`.
final class PencilSurfaceView: UIView, UIPencilInteractionDelegate {
    private let session: Session
    private var pen: UITouch?
    private var penBeganAt: TimeInterval = 0

    private let areaLayer = CALayer()
    private let projLayer = CALayer()
    private let inkLayer = CALayer()
    private let reticleLayer = CAShapeLayer()
    private var trail: CAShapeLayer?
    private var trailPath = CGMutablePath()
    private var trailPoints = 0
    private var trailDirty = false

    private static let ink = UIColor(red: 0.25, green: 0.85, blue: 1, alpha: 0.9).cgColor
    private static let inkRight = UIColor(red: 1, green: 0.62, blue: 0.2, alpha: 0.95).cgColor

    init(session: Session) {
        self.session = session
        super.init(frame: .zero)
        backgroundColor = .clear
        isMultipleTouchEnabled = true

        areaLayer.backgroundColor = UIColor(white: 1, alpha: 0.04).cgColor
        areaLayer.borderColor = UIColor(white: 1, alpha: 0.14).cgColor
        areaLayer.borderWidth = 1
        areaLayer.cornerRadius = 8
        projLayer.contentsGravity = .resize
        projLayer.masksToBounds = true
        projLayer.cornerRadius = 8
        projLayer.magnificationFilter = .linear
        reticleLayer.fillColor = nil
        reticleLayer.strokeColor = UIColor(white: 1, alpha: 0.7).cgColor
        reticleLayer.lineWidth = 1.5
        reticleLayer.path = CGPath(ellipseIn: CGRect(x: -9, y: -9, width: 18, height: 18), transform: nil)
        reticleLayer.isHidden = true
        for l in [areaLayer, projLayer, inkLayer, reticleLayer] { layer.addSublayer(l) }

        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
        let pencil = UIPencilInteraction()
        pencil.delegate = self
        addInteraction(pencil)
        session.surface = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        session.layout(size: bounds.size, insets: window?.safeAreaInsets ?? safeAreaInsets,
                       scale: window?.screen.scale ?? traitCollection.displayScale)
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    /// The active area moved or resized.
    func areaChanged() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        areaLayer.frame = session.area
        projLayer.frame = session.area
        inkLayer.frame = bounds
        CATransaction.commit()
    }

    // MARK: Projection

    func display(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        projLayer.contents = image
        CATransaction.commit()
    }

    func clearProjection() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        projLayer.contents = nil
        CATransaction.commit()
    }

    // MARK: Ink trail and reticle (feedback only; cheap)

    func inkBegin(at p: CGPoint, right: Bool) {
        inkEnd()
        let l = CAShapeLayer()
        l.fillColor = nil
        l.strokeColor = right ? Self.inkRight : Self.ink
        l.lineWidth = 3
        l.lineCap = .round
        l.lineJoin = .round
        trailPath = CGMutablePath()
        trailPath.move(to: p)
        trailPath.addLine(to: p)
        trailPoints = 1
        trailDirty = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        l.path = trailPath
        inkLayer.addSublayer(l)
        CATransaction.commit()
        trail = l
    }

    /// Adds a point to the trail's path. The layer is only told once the whole touch event is in (`inkFlush`).
    func inkAppend(to p: CGPoint) {
        guard trail != nil else { return }
        if trailPoints >= 400 {  // keep the path short: start again from here
            trailPath = CGMutablePath()
            trailPath.move(to: p)
            trailPoints = 0
        }
        trailPath.addLine(to: p)
        trailPoints += 1
        trailDirty = true
    }

    func inkFlush() {
        guard trailDirty, let l = trail else { return }
        trailDirty = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        l.path = trailPath
        CATransaction.commit()
    }

    /// The trail fades out over about a second, then goes.
    func inkEnd() {
        guard let l = trail else { return }
        trail = nil
        CATransaction.begin()
        CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 1
        l.opacity = 0
        l.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    func reticle(at p: CGPoint, progress: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        reticleLayer.position = p
        reticleLayer.opacity = Float(0.35 + 0.6 * progress)
        reticleLayer.isHidden = false
        CATransaction.commit()
    }

    func hideReticle() {
        guard !reticleLayer.isHidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        reticleLayer.isHidden = true
        CATransaction.commit()
    }

    // MARK: Touches

    /// Only the Pencil drives the Mac. (A debug build run with -debugFingerAsPencil lets a finger stand in for it.)
    private func isPen(_ t: UITouch) -> Bool {
        if t.type == .pencil { return true }
        return Debug.fingerAsPencil && t.type == .direct && !session.zoomArmed
    }

    private func sample(_ t: UITouch) -> Session.Sample {
        let at = t.location(in: self)
        let most = t.maximumPossibleForce
        var p = most > 0 ? Double(t.force / most) : 0.5  // a Pencil that reports no pressure counts as a medium press
        if let forced = Debug.pressure, t.type == .direct { p = forced }
        if Debug.pressureRamp, t.type == .direct {
            let age = t.timestamp - penBeganAt
            p = age < 1.2 ? 0.05 + 0.25 * age : 0.02
        }
        // Tilt, from the Pencil's altitude and azimuth, as the page gets it from a Pointer Event.
        var tx = 0.0, ty = 0.0
        if t.type == .pencil, t.altitudeAngle < .pi / 2 - 1e-3 {
            let tangent = max(tan(Double(t.altitudeAngle)), 1e-6)
            let az = Double(t.azimuthAngle(in: self))
            tx = atan(cos(az) / tangent) * 180 / .pi
            ty = atan(sin(az) / tangent) * 180 / .pi
        }
        return Session.Sample(x: at.x, y: at.y, p: (p * 1000).rounded() / 1000,
                              tx: (tx * 10).rounded() / 10, ty: (ty * 10).rounded() / 10)
    }

    /// A contact wider than this is a resting palm, not a fingertip. (The Simulator gives every touch a 37 pt radius; a debug
    /// run sets its own with -debugTouchRadius.)
    private func palm(_ t: UITouch) -> Bool { 2 * contactRadius(t) > Tuning.palm }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if pen != nil, !session.isPenActive { pen = nil }  // the session already let go of it
        for t in touches {
            if isPen(t) {
                penBeganAt = t.timestamp
                if pen == nil, session.penDown(sample(t)) { pen = t }
            } else if t.type == .direct, session.zoomArmed, !palm(t) {
                _ = session.zoomBegan(ObjectIdentifier(t), at: t.location(in: self))
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            if t === pen {
                let all = event?.coalescedTouches(for: t) ?? [t]  // every sample, not one per frame
                session.penMoved(all.map(sample))
            } else if t.type == .direct {
                session.zoomMoved(ObjectIdentifier(t), to: t.location(in: self))
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            if t === pen {
                pen = nil
                session.penUp(sample(t))
            } else if t.type == .direct {
                session.zoomEnded(ObjectIdentifier(t))
            }
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            if t === pen {
                pen = nil
                session.releaseStroke()  // up at the last point; nothing is left held
            } else if t.type == .direct {
                session.zoomEnded(ObjectIdentifier(t))
            }
        }
    }

    // MARK: Hover and Pencil gestures

    /// The Pencil above the glass (iPad hardware that supports hover). A pointer's hover has no height and no altitude.
    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            guard g.zOffset > 0 || g.altitudeAngle > 0 else { return }
            let at = g.location(in: self)
            session.hover(at.x, at.y)
        case .ended, .cancelled:
            session.hoverLeft()
        default:
            break
        }
    }

    // The system's own Pencil settings decide whether a double-tap or squeeze counts: "off" there means off here.

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        guard UIPencilInteraction.preferredTapAction != .ignore else { return }
        session.armRightFromPencil()
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard UIPencilInteraction.preferredSqueezeAction != .ignore, squeeze.phase == .ended else { return }
        session.armRightFromPencil()
    }

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        guard UIPencilInteraction.preferredTapAction != .ignore else { return }
        session.armRightFromPencil()  // iPadOS before 17.5; later systems call the method above instead
    }
}

struct Surface: UIViewRepresentable {
    let session: Session
    func makeUIView(context: Context) -> PencilSurfaceView { PencilSurfaceView(session: session) }
    func updateUIView(_ view: PencilSurfaceView, context: Context) {}
}
