import CoreGraphics

/// The zoom camera of web/app.js. The drawing area is a window onto the target, seen by a camera. `z` is how far in it
/// looks, with 1 the whole target fitted inside the drawing area (letterboxed); `cx`, `cy` are the target point (0 to 1)
/// at the middle of the drawing area. The active area is the part of the target the camera sees.
struct Camera: Equatable {
    var z: Double = 1
    var cx: Double = 0.5
    var cy: Double = 0.5
}

struct Fit {
    let tw: Double, th: Double   // the target's size (or its remembered aspect before the Mac has said)
    let base: Double             // drawing-area points per target point, whole target fitted
    let zMax: Double
    let s: Double                // z * base
    let cw: Double, ch: Double   // the camera's size, as fractions of the target
}

extension Camera {
    /// Keeps the camera inside what is allowed and returns the numbers derived from it (`clampCam`).
    mutating func clamp(aw: Double, ah: Double, tw: Double, th: Double) -> Fit {
        let base = min(aw / tw, ah / th)
        let zMax = max(1, aw / (Tuning.zoomMinW * tw * base))
        z = min(max(z, 1), zMax)
        let s = z * base, cw = aw / (s * tw), ch = ah / (s * th)
        cx = cw >= 1 ? 0.5 : min(max(cx, cw / 2), 1 - cw / 2)
        cy = ch >= 1 ? 0.5 : min(max(cy, ch / 2), 1 - ch / 2)
        return Fit(tw: tw, th: th, base: base, zMax: zMax, s: s, cw: cw, ch: ch)
    }
}

/// The two fingers of a zoom gesture, measured the same way the page does.
struct Fingers {
    var mx: Double, my: Double, d: Double

    init(_ pts: [CGPoint]) {
        let n = Double(max(pts.count, 1))
        mx = pts.reduce(0) { $0 + Double($1.x) } / n
        my = pts.reduce(0) { $0 + Double($1.y) } / n
        d = pts.count > 1 ? hypot(Double(pts[0].x - pts[1].x), Double(pts[0].y - pts[1].y)) : 0
    }
}
