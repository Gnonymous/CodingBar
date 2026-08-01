import AppKit
import SwiftUI

// MARK: - The menu-bar pulse, drawn on CALayer instead of SwiftUI
//
// The glyph animates continuously, and that is exactly what SwiftUI cannot afford here:
// a running animation re-evaluates the body every frame, and inside an NSStatusItem each
// of those frames drags the whole item through Auto Layout and
// -[NSStatusItem _updateReplicants] (which mirrors the item onto every screen and the
// Control Center). Measured at a permanent 60% of a core while nothing on screen changed
// size — and it stayed there whether the opacity came from a sin() or from two constant
// endpoints, so it is the hosting, not the curve.
//
// Core Animation interpolates on the render server: the app submits the animation once
// and then burns nothing per frame. Geometry still comes from `PulseGlyph`, so this and
// the SwiftUI `PulseIcon` (kept for offscreen rendering) draw the same mark.
final class PulseLayerView: NSView {
    // Matches PulseIcon's box exactly — the two must stay visually interchangeable.
    static let box = CGSize(width: 18, height: 13)
    private let lineWidth: CGFloat = 1.5
    private let dotRadius: CGFloat = 1.7

    private let waveLayer = CAShapeLayer()
    private let dotLayer = CAShapeLayer()

    private var active = false
    private var tempoBucket = 0

    // Flipped so the PulseGlyph design space (y grows downward) maps with the same
    // arithmetic the SwiftUI Shape uses.
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { Self.box }

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.box))
        wantsLayer = true
        layer?.addSublayer(waveLayer)
        layer?.addSublayer(dotLayer)
        waveLayer.fillColor = nil
        waveLayer.lineWidth = lineWidth
        waveLayer.lineCap = .round
        waveLayer.lineJoin = .round
        dotLayer.strokeColor = nil
        buildPaths()
        applyTint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    // The waveform fills an inset rect; the dot caps the right end, so the box leaves
    // room on the right for the dot's radius. Same inset math as PulseIcon.
    private var inner: CGRect {
        CGRect(x: lineWidth / 2,
               y: lineWidth / 2,
               width: Self.box.width - lineWidth - dotRadius,
               height: Self.box.height - lineWidth)
    }

    private func buildPaths() {
        let r = inner
        let path = CGMutablePath()
        for (i, point) in PulseGlyph.points.enumerated() {
            let n = PulseGlyph.normalized(point)
            let pt = CGPoint(x: r.minX + n.x * r.width, y: r.minY + n.y * r.height)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        waveLayer.path = path
        waveLayer.frame = CGRect(origin: .zero, size: Self.box)

        let n = PulseGlyph.normalized(PulseGlyph.terminus)
        let center = CGPoint(x: r.minX + n.x * r.width, y: r.minY + n.y * r.height)
        let d = dotRadius * 2
        // The dot gets its own layer frame so `transform.scale` breathes around its
        // center rather than the view's origin.
        dotLayer.frame = CGRect(x: center.x - dotRadius, y: center.y - dotRadius, width: d, height: d)
        dotLayer.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: d, height: d), transform: nil)
    }

    // MARK: - Appearance

    /// Crisp white on a dark menu bar, black on a light one — matching PulseIcon's tint
    /// rule. The dot keeps its own green/gray (liveness, not quota).
    private func applyTint() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        waveLayer.strokeColor = (isDark ? NSColor.white : NSColor.black).cgColor
        dotLayer.fillColor = (active ? NSColor(Theme.liveGreen) : .tertiaryLabelColor).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTint()
    }

    // MARK: - State

    /// Drive the glyph from the latest snapshot. Restarting is keyed to `active` and the
    /// tempo bucket only — a raw throughput reading would restart the animation on every
    /// 30s refresh for no visible gain.
    func update(active: Bool, throughput: Double) {
        let bucket = Self.tempoBucket(for: throughput)
        let changed = active != self.active || bucket != tempoBucket
        self.active = active
        self.tempoBucket = bucket
        applyTint()
        guard changed else { return }
        if active { startAnimating() } else { stopAnimating() }
    }

    private static func tempoBucket(for throughput: Double) -> Int {
        min(2, Int(min(max(throughput, 0), 2000) / 667))
    }

    /// 1.6s idle → 0.6s busy, bucketed.
    private var period: Double { [1.6, 1.1, 0.6][tempoBucket] }

    private func startAnimating() {
        stopAnimating()
        // autoreverses doubles each duration, so halve them to keep the original periods
        // (line: `period`, dot: 1.5s).
        waveLayer.add(breathe(from: 1.0, to: 0.78, duration: period / 2, key: "opacity"), forKey: "pulse")
        dotLayer.add(breathe(from: 1.0, to: 0.55, duration: 0.75, key: "opacity"), forKey: "breathe")
        dotLayer.add(breathe(from: 1.0, to: 0.78, duration: 0.75, key: "transform.scale"), forKey: "breatheScale")
    }

    private func stopAnimating() {
        waveLayer.removeAllAnimations()
        dotLayer.removeAllAnimations()
        waveLayer.opacity = 1
        dotLayer.opacity = 1
        dotLayer.transform = CATransform3DIdentity
    }

    private func breathe(from: Double, to: Double, duration: Double, key: String) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: key)
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // Survive the menu bar hiding the item and bringing it back.
        a.isRemovedOnCompletion = false
        return a
    }
}
