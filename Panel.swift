import AppKit
import QuartzCore

// MARK: - Floating waveform panel

/// What the card is currently showing.
enum PanelState { case wave, busy }

/// Pill-mode shapes. `idle` is the hairline capsule in the notch, `action`
/// the hover bar, `rec`/`mini` the two recording sizes, `busy` transcribing
/// in whichever of those two it interrupted.
enum PillState { case idle, action, rec, mini, busy }

final class WaveView: NSView {
    var state: PanelState = .wave
    var compact = false                 // pill mode; not cleared by reset()
    var pill: PillState = .idle         // only meaningful while compact
    var pillMini = false                // last of rec/mini; busy keeps that shape
    var hover: Int?                     // action-bar button under the cursor: 0 gear, 1 record, 2 expand
    var morphT: CGFloat = 1             // 0..1 progress of the current pill morph (1 = settled)
    var morphFromPill: PillState = .idle    // state the morph started from; its look is drawn while closing to idle
    var currentLevel: CGFloat = 0       // latest mic level from the tap
    private var smoothLevel: CGFloat = 0    // eased mic level; the bars follow this, not the raw tap
    private var bars: [CGFloat] = []        // scrolled history, oldest first
    private var ticks = 0
    private var phase = 0.0                 // transcribing-spindle clock
    var footerLeft = "Whisper"
    var footerDim = false                   // transcribing dims the whole footer
    var footerRight: [(String, String?)] = []   // (label, keycap)

    // Card geometry: 428x120, thin bars on a 3pt pitch.
    static let inset: CGFloat = 24
    static let pitch: CGFloat = 3
    static let barW: CGFloat = 1.5
    static let footerH: CGFloat = 40
    static let radius: CGFloat = 32
    static let fullSize = NSSize(width: 428, height: 120)
    // Pill geometry (mockups/notch-pill.html). Corner radius is always half
    // the height, so there is no pill radius constant.
    static let recSlots = 22            // ticker bars, 1.5 on a 3pt pitch (fits the 116pt pill)
    static let miniSlots = 6            // live bars, 2 on a 4pt pitch
    static let discSize: CGFloat = 30
    static let actionPitch: CGFloat = 40
    static let actionHit: CGFloat = 30
    static let topInset: CGFloat = 5    // expanded pills float a hair below the top edge
    static let idleInset: CGFloat = 8
    static let coral = NSColor(srgbRed: 0xef / 255, green: 0x5b / 255, blue: 0x4a / 255, alpha: 1)

    static func pillSize(_ s: PillState, mini: Bool) -> NSSize {
        switch s {
        case .idle: return NSSize(width: 44, height: 8)
        case .action: return NSSize(width: 116, height: 38)
        case .rec: return NSSize(width: 116, height: 38)
        case .mini: return NSSize(width: 54, height: 22)
        case .busy: return pillSize(mini ? .mini : .rec, mini: mini)
        }
    }

    /// Pill mode keeps the window one fixed size (`pillBox`) and animates the
    /// capsule drawn inside it. Resizing the window every frame went through
    /// the window server and flickered; drawing does not.
    static let pillBox = NSSize(width: 132, height: 48)
    var shape = NSRect.zero             // the capsule, in view coords (pill mode)
    /// The capsule to draw and hit: `shape` once the window sits at pillBox,
    /// else the whole bounds (mid compact toggle, when the window is animating).
    var pillRect: NSRect {
        guard compact,
              abs(bounds.width - Self.pillBox.width) < 0.5,
              abs(bounds.height - Self.pillBox.height) < 0.5 else { return bounds }
        return shape
    }
    /// Where a state's capsule sits in pillBox: centered, tucked under the top edge.
    static func pillShape(_ s: PillState, mini: Bool) -> NSRect {
        let sz = pillSize(s, mini: mini)
        let inset = s == .idle ? idleInset : topInset
        return NSRect(x: ((pillBox.width - sz.width) / 2).rounded(), y: pillBox.height - inset - sz.height,
                      width: sz.width, height: sz.height)
    }
    /// Pill radius follows the live capsule so a morph in flight stays a capsule.
    var radius: CGFloat { compact ? min(pillRect.width, pillRect.height) / 2 : Self.radius }

    var waveArea: NSRect {
        if compact { return bounds }
        return NSRect(x: Self.inset, y: Self.footerH + 4,
                      width: bounds.width - 2 * Self.inset, height: bounds.height - Self.footerH - 18)
    }
    private var slots: Int {
        compact ? (pillMini ? Self.miniSlots : Self.recSlots) : max(2, Int(waveArea.width / Self.pitch))
    }
    /// The eased mic level shaped for a bar height (0...1).
    private var liveLevel: CGFloat { min(1, pow(smoothLevel * 1.35, 0.9)) }
    // The two SF Symbols on the action bar, resolved once.
    private lazy var gearIcon = symbol("gearshape", size: 15, weight: .medium)
    private lazy var expandIcon = symbol("arrow.up.left.and.arrow.down.right", size: 13)

    private static var iconCache: [String: NSImage] = [:]
    private func symbol(_ name: String, size: CGFloat = 12,
                        weight: NSFont.Weight = .semibold) -> NSImage? {
        let key = "\(name)-\(size)-\(weight.rawValue)"
        if let img = Self.iconCache[key] { return img }
        guard let icon = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        let img = icon.withSymbolConfiguration(cfg) ?? icon
        img.isTemplate = true
        Self.iconCache[key] = img
        return img
    }

    /// Template SF Symbols draw black with `.sourceOver` + a fraction. Tint
    /// with the same color as the footer word so idle and busy match.
    private func drawTinted(_ img: NSImage, in r: NSRect, color: NSColor) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1,
                 respectFlipped: true, hints: nil)
        color.setFill()
        r.fill(using: .sourceIn)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    override var isFlipped: Bool { false }

    func reset() {
        state = .wave
        bars = []
        smoothLevel = 0
        currentLevel = 0
        ticks = 0
        phase = 0
    }

    /// One animation frame. Recording: the wave is a ticker of the last few
    /// seconds - a new bar lands at the right edge every ~80ms and the rest
    /// slide left, so words read as spindle-shaped blobs.
    /// Transcribing: a soft ripple slides across the bars from right to left.
    func tick() {
        switch state {
        case .wave:
            smoothLevel += (currentLevel - smoothLevel) * (currentLevel > smoothLevel ? 0.35 : 0.12)
            ticks += 1
            // Pill: one bar every 3rd frame (20/s); the card keeps its 12/s.
            if ticks % (compact ? 3 : 5) == 0 {
                bars.append(liveLevel)
                if bars.count > slots { bars.removeFirst(bars.count - slots) }
            }
        case .busy:
            phase += 1.0 / 30
        }
        // Only the bars move frame to frame; leave the card and footer alone.
        setNeedsDisplay(compact ? pillRect : waveArea.insetBy(dx: 0, dy: -4))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let path = NSBezierPath(roundedRect: pillRect, xRadius: radius, yRadius: radius)
        if !path.contains(point) { return nil }
        return super.hitTest(point)
    }

    override func draw(_ rect: NSRect) {
        if compact { drawPill(); return }
        let b = bounds
        let r = radius
        // Clip to the pill so tall bars can't paint through the corners
        // and show up as a halo outside the card.
        NSBezierPath(roundedRect: b, xRadius: r, yRadius: r).addClip()
        // Near-opaque dark wash over the blur, plus a hairline border.
        // (The soft edge translucency comes from the NSVisualEffectView behind us.)
        let card = NSBezierPath(roundedRect: b.insetBy(dx: 0.5, dy: 0.5), xRadius: r, yRadius: r)
        NSColor(calibratedWhite: 0.07, alpha: 0.55).setFill(); card.fill()
        NSColor(calibratedWhite: 1, alpha: 0.09).setStroke(); card.lineWidth = 1; card.stroke()

        if !compact { drawFooter(rect) }
        drawBars()
    }

    /// Footer row: no band, no divider - just a dim
    /// icon + mode name on the left and labels + keycaps on the right.
    /// The 60fps tick only dirties the wave area, so this text layout runs
    /// just on full redraws (state changes/resize), not every frame.
    private func drawFooter(_ rect: NSRect) {
        guard rect.minY < Self.footerH else { return }
        let footer = NSRect(x: 10, y: 2, width: bounds.width - 20, height: Self.footerH - 4)
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let dimA: CGFloat = footerDim ? 0.28 : 0.45
        let dim = NSColor(calibratedWhite: 1, alpha: dimA)
        let bright = NSColor(calibratedWhite: 1, alpha: footerDim ? 0.55 : 0.9)

        if let img = symbol("mic.fill", size: 13) {
            // Draw at the symbol's own size. A 15x14 dest squashed mic.fill
            // (taller than wide) into a short wide blob.
            var r = centered(img.size, at: NSPoint(x: 0, y: footer.midY))
            r.origin.x = footer.minX + 14
            drawTinted(img, in: r, color: dim)
        }
        (footerLeft as NSString).draw(at: NSPoint(x: footer.minX + 38, y: footer.midY - 8),
                                      withAttributes: [.font: font, .foregroundColor: dim])

        // Right side, e.g. "Stop [⌘][⌥][Space]  Cancel [esc]", laid out right-to-left.
        var x = footer.maxX - 14
        for (label, cap) in footerRight.reversed() {
            if let cap = cap {
                let capFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
                let w = (cap as NSString).size(withAttributes: [.font: capFont]).width + 14
                let capRect = NSRect(x: x - w, y: footer.midY - 10, width: w, height: 20)
                NSColor(calibratedWhite: 1, alpha: 0.13).setFill()
                NSBezierPath(roundedRect: capRect, xRadius: 5, yRadius: 5).fill()
                (cap as NSString).draw(at: NSPoint(x: capRect.minX + 7, y: capRect.midY - 7.5),
                                       withAttributes: [.font: capFont, .foregroundColor: bright])
                x = capRect.minX - 5
            }
            if !label.isEmpty {
                let w = (label as NSString).size(withAttributes: [.font: font]).width
                (label as NSString).draw(at: NSPoint(x: x - w, y: footer.midY - 8),
                                         withAttributes: [.font: font, .foregroundColor: dim])
                x -= w + 18
            }
        }
    }

    /// Thin bars mirrored around the centerline; quiet bars collapse to dots,
    /// so silence reads as a dotted line edge to edge.
    private func drawBars() {
        let area = waveArea
        let n = slots
        let (levels, busyAlpha) = self.levels(n: n)
        let maxH = area.height
        let minH: CGFloat = 1.6
        drawBarRow(n: n, pitch: Self.pitch, barW: Self.barW, centerX: area.midX, midY: area.midY,
                   height: { max(minH, levels[$0] * maxH) },
                   alpha: { i in
                       let lv = levels[i]
                       return lv * maxH <= minH ? 0.30
                           : state == .busy ? busyAlpha[i]
                           : 0.40 + 0.60 * min(1, lv * 1.5)
                   })
    }

    /// Bar heights 0...1 plus per-bar alpha for the busy ripple. Shared by
    /// the card and the pill so rec and busy look like the big wave shrunk.
    private func levels(n: Int) -> ([CGFloat], [CGFloat]) {
        var levels = [CGFloat](repeating: 0, count: n)
        var alphas = [CGFloat](repeating: 1, count: n)
        switch state {
        case .wave:
            // Right-aligned history plus a live bar hugging the right edge.
            let recent = bars.suffix(n - 1)
            let start = n - 1 - recent.count
            for (i, v) in recent.enumerated() { levels[start + i] = v }
            levels[n - 1] = liveLevel
        case .busy:
            // Ripple: one long, gentle sine sliding right to left, tapered at
            // both ends so it fades into the edges. `+ phase` is what makes it
            // travel leftward; 0.9 cycles/s, 2.2 waves across the card.
            for i in 0..<n {
                let x = Double(i) / Double(n - 1)
                let env = pow(sin(.pi * x), 0.6)
                let s = 0.5 + 0.5 * sin(2 * .pi * (x * 2.2 + phase * 0.9))
                levels[i] = CGFloat(0.08 + 0.55 * env * s)
                alphas[i] = CGFloat(0.45 + 0.35 * s)
            }
        }
        return (levels, alphas)
    }

    /// One row of `n` rounded bars on a pitch, centered on `centerX`, each
    /// mirrored about `midY`. The card wave, the rec ticker and the mini
    /// bars are all this with different height/alpha rules.
    private func drawBarRow(n: Int, pitch: CGFloat, barW: CGFloat, centerX: CGFloat, midY: CGFloat,
                            height: (Int) -> CGFloat, alpha: (Int) -> CGFloat) {
        let totalW = CGFloat(n) * pitch - (pitch - barW)
        let x0 = centerX - totalW / 2
        for i in 0..<n {
            let h = height(i)
            NSColor(calibratedWhite: 1, alpha: alpha(i)).setFill()
            NSBezierPath(roundedRect: NSRect(x: x0 + CGFloat(i) * pitch, y: midY - h / 2, width: barW, height: h),
                         xRadius: barW / 2, yRadius: barW / 2).fill()
        }
    }

    // MARK: Pill

    /// Hit target `i` (0 gear, 1 record, 2 expand): 30pt discs 40pt apart, centered.
    func actionButtonRect(_ i: Int) -> NSRect {
        let s = Self.actionHit
        return NSRect(x: pillRect.midX + CGFloat(i - 1) * Self.actionPitch - s / 2,
                      y: pillRect.midY - s / 2, width: s, height: s)
    }

    func actionButton(at p: NSPoint) -> Int? {
        (0..<3).first { actionButtonRect($0).contains(p) }
    }

    /// The Stop button in rec: 30pt disc, 4pt in from the left edge.
    var discRect: NSRect {
        let d = Self.discSize
        return NSRect(x: pillRect.minX + 4, y: pillRect.minY + (pillRect.height - d) / 2, width: d, height: d)
    }

    /// Pill states never touch the blur: idle is a bare hairline, everything
    /// else is the same black as the notch so the two read as one shape.
    private func drawPill() {
        let b = pillRect
        let r = radius
        let capsule = NSBezierPath(roundedRect: b, xRadius: r, yRadius: r)
        // k: how "expanded" the look is. Idle is 0, any black state is 1, and a
        // morph glides between them so the fill and contents crossfade with
        // the shape instead of snapping on the first frame.
        let toIdle = pill == .idle, fromIdle = morphFromPill == .idle
        let shown: PillState = toIdle ? morphFromPill : pill
        // Only a morph that has idle at one end crossfades; black to black
        // (rec <-> mini, action -> rec) keeps the fill and contents solid.
        let k: CGFloat = toIdle ? (fromIdle ? 0 : 1 - morphT) : (fromIdle ? morphT : 1)
        if k < 1 {
            // Translucent capsule. The fill also keeps the interior hit-testable;
            // a fully transparent interior would only hover on the 1pt ring.
            NSColor(calibratedWhite: 1, alpha: 0.18 * (1 - k)).setFill(); capsule.fill()
            let ring = NSBezierPath(roundedRect: b.insetBy(dx: 0.5, dy: 0.5),
                                    xRadius: r - 0.5, yRadius: r - 0.5)
            NSColor(calibratedWhite: 1, alpha: 0.35 * (1 - k)).setStroke(); ring.lineWidth = 1; ring.stroke()
        }
        if k <= 0 || shown == .idle { return }
        capsule.addClip()
        NSColor(white: 0.04, alpha: k).setFill(); b.fill()
        // Contents arrive once the shape has room for them.
        let contentAlpha = max(0, min(1, (k - 0.35) / 0.65))
        if contentAlpha <= 0 { return }
        NSGraphicsContext.current?.cgContext.setAlpha(contentAlpha)
        switch shown {
        case .action:
            drawActionBar(arrival: contentAlpha)
        case .rec:
            drawDisc(busy: false); drawTicker()
        case .mini:
            drawMiniBars()
        case .busy:
            if pillMini { drawMiniBars() } else { drawDisc(busy: true); drawTicker() }
        case .idle:
            break
        }
    }

    /// Settings / Record / Expand. The hovered one is full white on a lit disc.
    /// `arrival` 0...1: the icons scale 0.8 -> 1 about the bar's center as they fade in.
    private func drawActionBar(arrival: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = pillRect
        let grow = 0.8 + 0.2 * arrival
        ctx.translateBy(x: b.midX, y: b.midY)
        ctx.scaleBy(x: grow, y: grow)
        ctx.translateBy(x: -b.midX, y: -b.midY)
        for i in 0..<3 {
            let hot = hover == i
            let color = NSColor(calibratedWhite: 1, alpha: hot ? 1 : 0.92)
            let box = actionButtonRect(i)
            let c = NSPoint(x: box.midX, y: box.midY)
            ctx.saveGState()
            if hot {
                // Lit disc under the hovered icon, Superwhisper style.
                NSColor(calibratedWhite: 1, alpha: 0.22).setFill()
                NSBezierPath(ovalIn: box).fill()
            }
            switch i {
            case 0:
                if let img = gearIcon { drawTinted(img, in: centered(img.size, at: c), color: color) }
            case 1:
                drawGlyph(center: c, size: 16, color: color)
            default:
                if let img = expandIcon { drawTinted(img, in: centered(img.size, at: c), color: color) }
            }
            ctx.restoreGState()
        }
    }

    private func centered(_ s: NSSize, at c: NSPoint) -> NSRect {
        NSRect(x: (c.x - s.width / 2).rounded(), y: (c.y - s.height / 2).rounded(),
               width: s.width, height: s.height)
    }

    /// The five bars from icon/icon.svg: a W, tall-short-mid-short-tall with
    /// the short pair on the baseline. `size` is the nominal box the mockup
    /// used (the bars span about 0.79 of it); coordinates are the SVG's.
    private static let glyphBars: [(x: CGFloat, y: CGFloat, h: CGFloat)] = [
        (287, 292, 440), (391, 530, 202), (495, 362, 291), (599, 530, 202), (703, 292, 440),
    ]
    private func drawGlyph(center c: NSPoint, size: CGFloat, color: NSColor) {
        let k = size * 1.8 / 1024
        color.setFill()
        for bar in Self.glyphBars {
            // SVG y grows downward; flip about the glyph's center (512, 512).
            NSRect(x: c.x + (bar.x - 512) * k, y: c.y - (bar.y + bar.h - 512) * k,
                   width: 34 * k, height: bar.h * k).fill()
        }
    }

    /// Rec: coral disc with the glyph in full coral. Busy: both go grey so
    /// the disc reads as "not a button right now".
    private func drawDisc(busy: Bool) {
        let r = discRect
        (busy ? NSColor(calibratedWhite: 1, alpha: 0.12) : Self.coral.withAlphaComponent(0.32)).setFill()
        NSBezierPath(ovalIn: r).fill()
        drawGlyph(center: NSPoint(x: r.midX, y: r.midY), size: 13,
                  color: busy ? NSColor(calibratedWhite: 1, alpha: 0.55) : Self.coral)
    }

    /// Rec ticker, centered in the width right of the disc. Alpha ramps
    /// 45% -> 100% left to right so the newest bar is the brightest.
    private func drawTicker() {
        let n = Self.recSlots
        let b = pillRect
        let minH: CGFloat = 2, maxH: CGFloat = 18
        let (levels, alphas) = self.levels(n: n)
        drawBarRow(n: n, pitch: Self.pitch, barW: Self.barW, centerX: (discRect.maxX + b.maxX) / 2, midY: b.midY,
                   height: { max(minH, levels[$0] * maxH) },
                   alpha: { state == .busy ? alphas[$0] : 0.45 + 0.55 * CGFloat($0) / CGFloat(n - 1) })
    }

    /// Mini: six live bars in a bell (middle tallest) driven by the eased
    /// level, not history. Busy runs the ripple across the same six.
    private func drawMiniBars() {
        let n = Self.miniSlots
        let b = pillRect
        let minH: CGFloat = 2, maxH: CGFloat = 12
        let live = liveLevel
        let (ripple, alphas) = state == .busy ? levels(n: n) : ([], [])
        drawBarRow(n: n, pitch: 4, barW: 2, centerX: b.midX, midY: b.midY,
                   height: { i in
                       let bell = CGFloat(sin(.pi * (Double(i) + 0.5) / Double(n)))
                       let lv = state == .busy ? ripple[i] : 0.15 + 0.85 * live * bell
                       return max(minH, lv * maxH)
                   },
                   alpha: { state == .busy ? alphas[$0] : 1 })
    }

}

/// The one-line label under a hovered action button ("Record  ⌥ Space").
/// Its own tiny child window because the bar is only 38pt tall; clicks pass
/// through it and it never takes focus.
final class HintPanel: NSPanel {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let bg = HintBackground()
        contentView = bg
        label.alignment = .center
        label.lineBreakMode = .byClipping
        bg.addSubview(label)
        alphaValue = 0
    }

    func show(_ text: NSAttributedString, under anchor: NSPoint, parent: NSWindow) {
        label.attributedStringValue = text
        // Let the field measure itself. NSAttributedString.size() is the bare
        // glyph run; the field draws with its own cell insets (and on Tahoe
        // its own font) and clipped the tail ("Expa", "Settin").
        label.sizeToFit()
        let ts = label.frame.size
        let size = NSSize(width: ceil(ts.width) + 32, height: ceil(ts.height) + 18)
        label.frame = NSRect(x: 16, y: 9, width: ceil(ts.width), height: ceil(ts.height))
        setFrame(NSRect(x: (anchor.x - size.width / 2).rounded(), y: anchor.y - size.height,
                        width: size.width, height: size.height), display: true)
        if self.parent == nil { parent.addChildWindow(self, ordered: .above) }
        hiding = false
        if alphaValue < 1 {
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().alphaValue = 1
            }
        }
    }

    private var hiding = false
    func hide(immediately: Bool = false) {
        guard alphaValue > 0 || isVisible else { return }
        if immediately {
            hiding = false
            alphaValue = 0
            parent?.removeChildWindow(self)
            orderOut(nil)
            return
        }
        guard !hiding else { return }
        hiding = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.hiding else { return }   // a show() won the race
            self.hiding = false
            self.parent?.removeChildWindow(self)
            self.orderOut(nil)
        })
    }
}

final class HintBackground: NSView {
    override func draw(_ rect: NSRect) {
        // Near-black rounded box with a hairline, like Superwhisper's.
        let r: CGFloat = 10
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: r, yRadius: r)
        NSColor(white: 0.05, alpha: 0.94).setFill(); path.fill()
        NSColor(calibratedWhite: 1, alpha: 0.12).setStroke(); path.lineWidth = 1; path.stroke()
    }
}

/// Frosted card. maskImage clips the blur; hitTest still uses the square
/// bounds, so corners would eat clicks on the tabs under a compact pill.
final class PillEffectView: NSVisualEffectView {
    let radius: CGFloat = WaveView.radius
    override func hitTest(_ point: NSPoint) -> NSView? {
        let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        if !path.contains(point) { return nil }
        return super.hitTest(point)
    }
}

/// Clear content view the blur and the wave both sit in, so pill mode can
/// hide the blur while the wave keeps drawing. Clicks outside the rounded
/// shape fall through, same as the effect view when it was the content view.
/// Its one tracking area feeds the pill's hover to the panel (the owner).
final class PillHostView: NSView {
    weak var shape: WaveView?
    private var tracker: NSTrackingArea?

    /// Autoresizing masks did not follow the window through a morph (the
    /// wave kept the 428x120 card bounds, so a 44pt pill drew with a 60pt
    /// radius: an eye shape, and the idle ring showed as two lines). Pin
    /// every subview to the host's bounds on each layout pass instead.
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        for v in subviews { v.frame = bounds }
    }
    override func layout() {
        super.layout()
        for v in subviews where v.frame != bounds { v.frame = bounds }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracker { removeTrackingArea(t) }
        guard let window else { return }
        let t = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: window, userInfo: nil)
        addTrackingArea(t)
        tracker = t
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let r = shape?.radius ?? WaveView.radius
        let local = superview.map { convert(point, from: $0) } ?? point
        let b = shape?.pillRect ?? bounds
        if !NSBezierPath(roundedRect: b, xRadius: r, yRadius: r).contains(local) { return nil }
        return super.hitTest(point)
    }
}

/// Invisible until the cursor is in this view's bounds. Alpha 0 still
/// hit-tests; isHidden would not. `.activeAlways` because the panel is
/// nonactivating and would never be key.
final class ChevronButton: NSButton {
    var lit: CGFloat = 0.55

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        focusRingType = .none
        contentTintColor = .white
        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        animator().alphaValue = lit
    }

    override func mouseExited(with event: NSEvent) {
        animator().alphaValue = 0
    }
}

final class WavePanel: NSPanel {
    let wave = WaveView()
    private let effect = PillEffectView()
    private let host = PillHostView()
    private let chevron = ChevronButton(frame: .zero)
    private var timer: Timer?
    private var compact = false
    private var mouseDownCompact = false
    /// show() .. hide(): the tick timer runs exactly for a take. Decides where pill mode lands.
    private var recordingActive: Bool { timer != nil }
    /// Last of rec / mini, so the next take opens in the shape it was left in.
    private var pillMiniPref: Bool {
        get { UserDefaults.standard.bool(forKey: "pillMini") }
        set { UserDefaults.standard.set(newValue, forKey: "pillMini") }
    }

    /// True when there is something on screen worth an Esc: the full card,
    /// or a pill in a take state. The always-on idle outline and the hover
    /// bar are not it, so Esc reaches the app underneath.
    var showsResult: Bool {
        isVisible && !(compact && (wave.pill == .idle || wave.pill == .action))
    }

    // Pill buttons, wired by main.swift. Unset closures are a no-op. Record
    // and the rec disc (Stop) are one toggle; the app decides what stop means.
    var onToggleRecord: (() -> Void)?
    var onSettings: (() -> Void)?
    /// Shown in the Record hint ("Record  ⌥ Space"); main.swift keeps it current.
    var recordHotkey = ""
    private let hint = HintPanel()

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: WaveView.fullSize),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        ignoresMouseEvents = false
        hidesOnDeactivate = false   // the settings window can make us active; the card must survive us going inactive again
        isMovableByWindowBackground = true   // grab anywhere on the card and drag
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        // Frosted-glass card. layer.cornerRadius does not clip the material, so
        // the blur would fill the window's square and show as a halo outside the
        // pill. maskImage on the contentView clips the blur and shapes the
        // window shadow to the same rounded rect.
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .vibrantDark)
        effect.maskImage = Self.roundedMask(radius: WaveView.radius)
        // The blur is a subview of a clear host rather than the content view
        // itself so pill mode can hide it (bare outline / solid black) while
        // the wave keeps drawing on top.
        host.shape = wave
        contentView = host
        effect.frame = host.bounds
        effect.autoresizingMask = [.width, .height]
        host.addSubview(effect)
        wave.wantsLayer = true
        wave.layer?.cornerRadius = WaveView.radius
        wave.layer?.masksToBounds = true
        wave.frame = host.bounds
        wave.autoresizingMask = [.width, .height]
        host.addSubview(wave)

        chevron.target = self
        chevron.action = #selector(toggleCompact)
        chevron.image = Self.chevronImage()
        chevron.toolTip = "Collapse"
        wave.addSubview(chevron)
        layoutChevron()

        // If the display layout shifts while the panel is up (wake, monitor
        // plug/unplug, resolution change), put it back somewhere visible.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isVisible else { return }
            self.place()
        }
    }

    private func keycaps(_ hotkey: String) -> [(String, String?)] {
        hotkey.split(separator: "+").map { ("", keycap(String($0))) }
    }

    func show(mode: Mode, hotkey: String, footer: String? = nil, closeLabel: String = "Close") {
        wave.reset()
        wave.footerDim = false
        wave.footerLeft = footer ?? (mode == .cleanup ? "Cleanup" : "Whisper")
        wave.footerRight = [("Stop", nil)] + keycaps(hotkey) + [(closeLabel, "esc")]
        schedule(fps: 60)   // the running timer is what marks the take active
        if UserDefaults.standard.bool(forKey: "panelCompact") {
            // Pill mode: morph in place from idle (or whatever shape is up)
            // instead of fading a fresh window in.
            if !compact { setCompact(true, animated: false) }
            alphaValue = 1
            setPill(pillStateForTake(), animated: isVisible)
            bringUp()
        } else {
            // Size before place/orderFront so the first frame is already the
            // saved mode (no 428x120 flash then shrink).
            setCompact(false, animated: false)
            wave.needsDisplay = true
            // The card fades in quickly rather than popping.
            let fadeIn = !isVisible
            alphaValue = fadeIn ? 0 : 1
            bringUp()
            if fadeIn {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.13
                    self.animator().alphaValue = 1
                }
            }
        }
        // Right after a wake the window server can drop the panel somewhere
        // stale; one more place() after things settle brings it back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.isVisible else { return }
            self.place()
        }
    }

    /// Order front, re-tagging "show on every Space" first. The window server
    /// can drop that tag (seen after a sleep/wake, or after the card was
    /// dragged) and pin the panel to one Space, so the card only appeared on
    /// a desktop the user was not looking at while dictation kept working.
    private func bringUp() {
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        orderFrontRegardless()
        if !compact { invalidateShadow() }
    }

    func transcribing(status: String? = nil) {
        wave.state = .busy
        wave.footerDim = true
        if let status { wave.footerLeft = status }
        wave.footerRight = [("Close", "esc")]
        wave.needsDisplay = true
        if compact { setPill(.busy, animated: false) }
        schedule(fps: 30)
    }

    /// A cancelled take (Esc): the transcription still runs to completion,
    /// so the pill shows busy until finishTake's hide(); the card just goes.
    func cancelTake() {
        if compact { transcribing() } else { hide() }
    }

    /// Launch in pill mode: the hairline capsule goes up with nothing running.
    func showIdle() {
        guard !recordingActive else { return }
        setCompact(true, animated: false)   // lands on idle: no take is running
        bringUp()
    }

    /// Busy-state progress ("Transcribing…", "Loading model…"). Tick only
    /// dirties the bars, so this forces a full redraw for the footer word.
    func setFooterLeft(_ text: String) {
        wave.footerLeft = text
        wave.needsDisplay = true
        // The pill has no footer; the status rides in the hint under it.
        guard compact, wave.pill != .idle, wave.pill != .action, !text.isEmpty else { return }
        hint.show(hintRun(text), under: hintAnchor(x: wave.pillRect.midX), parent: self)
    }

    /// A repeating main-thread timer that keeps firing through menu tracking.
    private func repeating(_ interval: TimeInterval, _ body: @escaping () -> Void) -> Timer {
        let t = Timer(timeInterval: interval, repeats: true) { _ in body() }
        RunLoop.main.add(t, forMode: .common)
        return t
    }

    private func schedule(fps: Double) {
        timer?.invalidate()
        timer = repeating(1.0 / fps) { [weak self] in self?.wave.tick() }
    }

    func hide() {
        timer?.invalidate(); timer = nil
        guard isVisible else { return }
        if compact {
            // The pill never leaves the screen; it shrinks back to the outline.
            // Already there (or on the way): nothing to do. The bars keep
            // their last frame through the close; pillSettled resets them.
            if wave.pill == .idle { return }
            setPill(.idle, animated: true)
            return
        }
        // Quick whole-card fade on the way out.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            // A new show() or a chevron click into pill mode won the race.
            guard self.alphaValue == 0, !self.compact else { self.alphaValue = 1; return }
            self.orderOut(nil)
            self.alphaValue = 1
        })
    }

    func push(level: CGFloat) {
        wave.currentLevel = level
    }

    @objc private func toggleCompact() {
        setCompact(!compact, animated: true)
    }

    private func setCompact(_ on: Bool, animated: Bool) {
        stopHover()
        compact = on
        wave.compact = on
        UserDefaults.standard.set(on, forKey: "panelCompact")
        isMovableByWindowBackground = !on
        // Pill mode: no blur, no chevron, no layer clip (the draw clip follows
        // the live radius during a morph; the layer's would not). Where it
        // lands depends on whether a take is running.
        if on {
            wave.pillMini = pillMiniPref
            wave.pill = pillStateForTake()
            wave.morphFromPill = wave.pill
            wave.hover = nil
            wave.shape = targetShape
            wave.morphT = 1
            // A chevron click can land during the card's hide fade; the pill
            // must come up solid and stay ordered in.
            alphaValue = 1
            if !isVisible { orderFrontRegardless() }
        }
        // Hidden was not enough: a behind-window blur view keeps shaping the
        // window with its maskImage even when hidden, and that mask was
        // stretched from a stale radius (pointed, lens-shaped pills). In pill
        // mode the blur leaves the hierarchy entirely; the wave's own draw
        // clip is the only shape.
        if on {
            effect.maskImage = nil
            effect.removeFromSuperview()
        } else if effect.superview == nil {
            effect.frame = host.bounds
            host.addSubview(effect, positioned: .below, relativeTo: wave)
        }
        chevron.isHidden = on
        wave.layer?.masksToBounds = !on
        hasShadow = !on   // pill mode never carries a window shadow (toggling it flickers)
        applyChrome()
        chevron.toolTip = on ? "Expand" : "Collapse"
        chevron.alphaValue = 0
        layoutChevron()
        wave.needsDisplay = true
        let next = frame(for: currentSize)
        if animated, isVisible {
            // While the window itself animates, pill state changes wait
            // (setPill returns early) and hover is ignored (`morphing`).
            toggling = true
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.animator().setFrame(next, display: true)
            }, completionHandler: { [weak self] in
                guard let self else { return }
                self.toggling = false
                self.layoutChevron()
                self.invalidateShadow()
                self.syncChevronHover()
                // The window landed at pillBox drawing a box-filling capsule;
                // glide it into the state's real shape.
                if self.compact {
                    self.wave.shape = self.wave.bounds
                    self.morph(to: self.targetShape, animated: true)
                }
            })
        } else {
            setFrame(next, display: true)
            layoutChevron()
            invalidateShadow()
            syncChevronHover()
        }
    }

    private var currentSize: NSSize {
        compact ? WaveView.pillBox : WaveView.fullSize
    }
    private var toggling = false   // card <-> pill window animation in flight
    /// Any pill transition in flight: the window toggle or a capsule morph.
    private var morphing: Bool { toggling || !morphLink.isPaused }
    /// The capsule the current pill state wants, inside pillBox.
    private var targetShape: NSRect { WaveView.pillShape(wave.pill, mini: wave.pillMini) }
    private var mouseInWindow: NSPoint {
        convertFromScreen(NSRect(origin: NSEvent.mouseLocation, size: .zero)).origin
    }
    private func mouseInWave() -> NSPoint { wave.convert(mouseInWindow, from: nil) }
    /// Is the cursor over the drawn capsule (not just the bigger window)?
    private var cursorInPill: Bool { wave.pillRect.contains(mouseInWave()) }

    private func applyChrome() {
        if compact {
            // No layer clip in pill mode: drawPill clips to the live capsule.
            wave.layer?.cornerRadius = 0
            return
        }
        let r = WaveView.radius
        effect.maskImage = Self.roundedMask(radius: r)
        wave.layer?.cornerRadius = r
    }

    // MARK: Pill state

    /// Where pill mode lands: idle unless show() has run and hide() has not.
    private func pillStateForTake() -> PillState {
        guard recordingActive else { return .idle }
        if wave.state == .busy { return .busy }
        return wave.pillMini ? .mini : .rec
    }

    private func setPill(_ s: PillState, animated: Bool) {
        let opening = s == .action && wave.pill == .idle
        wave.morphFromPill = wave.pill
        wave.pill = s
        stopHover()
        if s == .action {
            // The bar closes from here, not from mouseExited: exit events
            // fired mid-morph flickered it. Close only once the cursor has
            // been off the capsule for a beat, so grazing the edge is free.
            var outsideSince: TimeInterval?
            hoverWatch = repeating(0.05) { [weak self] in
                guard let self, self.compact, self.wave.pill == .action, !self.morphing else { return }
                if self.cursorInPill { outsideSince = nil; return }
                let now = Date().timeIntervalSinceReferenceDate
                if outsideSince == nil { outsideSince = now }
                if now - outsideSince! >= 0.2 { self.setPill(.idle, animated: true) }
            }
        }
        if s == .rec { wave.pillMini = false }
        if s == .mini { wave.pillMini = true }
        wave.hover = nil
        wave.needsDisplay = true
        // Mid card->pill toggle: the state is set; the toggle's completion
        // morphs into it once the window has landed.
        if toggling { return }
        // The window stays put at pillBox; only the drawn capsule moves. Pick
        // a screen only when coming up, so a take does not follow the mouse
        // across monitors.
        if !isVisible || frame.size != WaveView.pillBox { setFrame(frame(for: WaveView.pillBox), display: false) }
        morph(to: targetShape, animated: animated, soft: opening)
    }

    private var hoverWatch: Timer?
    /// Pending hover label and the bar's close watch: torn down together by
    /// every transition that takes the bar away.
    private func stopHover() {
        dismissHint()
        hoverWatch?.invalidate(); hoverWatch = nil
    }

    /// Animate the capsule to `next`. `soft`: the hover-open springs (a
    /// longer, eased-out glide so the bar grows out of the outline); anything
    /// else eases in and out.
    private func morph(to next: NSRect, animated: Bool, soft: Bool = false) {
        if animated, isVisible {
            // Display-link driven, one frame per screen refresh, our easing.
            // Starts from wherever the capsule is right now, mid-flight included.
            morphFrom = wave.shape
            morphTo = next
            // Reset the clock before anything redraws: the pill state has
            // already flipped, and a stale morphT of 1 drew one frame of the
            // new state's look at the old state's size (a grey flash on close).
            wave.morphT = 0
            wave.needsDisplay = true
            morphSoft = soft
            morphStart = CACurrentMediaTime()
            morphLink.isPaused = false
        } else {
            morphLink.isPaused = true
            wave.morphT = 1
            wave.shape = next
            wave.needsDisplay = true
            pillSettled()
        }
    }

    /// One display link for the panel's life, paused between morphs.
    private lazy var morphLink: CADisplayLink = {
        let link = wave.displayLink(target: self, selector: #selector(morphTick(_:)))
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        return link
    }()
    private var morphFrom = NSRect.zero
    private var morphTo = NSRect.zero
    private var morphSoft = false
    private var morphStart: CFTimeInterval = 0

    @objc private func morphTick(_ link: CADisplayLink) {
        let dur: CFTimeInterval = morphSoft ? 0.46 : 0.28
        let t = min(1, max(0, (CACurrentMediaTime() - morphStart) / dur))
        // Open: underdamped spring, ~4% overshoot peaking around 0.28s, settled
        // by 0.46s (zeta 0.716, omega 16). Close: ease-in-out cubic, no bounce.
        let e: CGFloat
        if morphSoft {
            let zeta = 0.716, omega = 16.0
            let wd = omega * (1 - zeta * zeta).squareRoot()
            let sec = t * dur
            let env = exp(-zeta * omega * sec)
            e = CGFloat(1 - env * (cos(wd * sec) + (zeta * omega / wd) * sin(wd * sec)))
        } else {
            let x = CGFloat(t)
            e = x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
        }
        let f = NSRect(x: morphFrom.minX + (morphTo.minX - morphFrom.minX) * e,
                       y: morphFrom.minY + (morphTo.minY - morphFrom.minY) * e,
                       width: morphFrom.width + (morphTo.width - morphFrom.width) * e,
                       height: morphFrom.height + (morphTo.height - morphFrom.height) * e)
        wave.morphT = e
        wave.shape = t >= 1 ? morphTo : f
        wave.needsDisplay = true
        if t >= 1 {
            link.isPaused = true
            wave.morphT = 1
            pillSettled()
        }
    }

    /// After a morph: settle the bars, then act on wherever the cursor is
    /// now (mouse events during the morph were ignored).
    private func pillSettled() {
        guard compact else { return }
        if wave.pill == .idle, wave.state != .wave { wave.reset() }
        let inside = cursorInPill
        if wave.pill == .idle, inside { setPill(.action, animated: true); return }
        if wave.pill == .action, !inside { setPill(.idle, animated: true); return }
        guard wave.pill == .action else { return }
        setHover(wave.actionButton(at: mouseInWave()))
    }

    /// Hovered action button: highlight it and show its hint under the bar.
    private func setHover(_ h: Int?) {
        let changed = h != wave.hover
        if changed { wave.hover = h; wave.needsDisplay = true }
        guard let h, compact, wave.pill == .action else { dismissHint(immediately: false); return }
        if !changed, hint.isVisible || hintDelay != nil { return }
        // Only a lingering hover gets the label; a pass across the bar does not.
        dismissHint(immediately: false)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.compact, self.wave.pill == .action, self.wave.hover == h else { return }
            self.hintDelay = nil
            self.hint.show(self.hintText(h), under: self.hintAnchor(x: self.wave.actionButtonRect(h).midX), parent: self)
        }
        hintDelay = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hintDelaySeconds, execute: work)
    }
    private var hintDelay: DispatchWorkItem?
    private static let hintDelaySeconds: TimeInterval = 0.7
    /// Drop the hover label, pending or shown: at once when a transition takes
    /// the bar away, with its fade when the cursor merely leaves a button.
    private func dismissHint(immediately: Bool = true) {
        hintDelay?.cancel(); hintDelay = nil
        hint.hide(immediately: immediately)
    }

    /// One run of hint text: 13pt regular, white at `alpha`.
    private func hintRun(_ text: String, _ alpha: CGFloat = 0.95) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: alpha)])
    }

    /// Screen point for a hint's top center: `x` in wave coords, 4pt under the capsule.
    private func hintAnchor(x: CGFloat) -> NSPoint {
        let p = wave.convert(NSPoint(x: x, y: wave.pillRect.minY - 4), to: nil)
        return convertToScreen(NSRect(origin: p, size: .zero)).origin
    }

    private func hintText(_ i: Int) -> NSAttributedString {
        let out = NSMutableAttributedString()
        switch i {
        case 0: out.append(hintRun("Settings"))
        case 1:
            out.append(hintRun("Record"))
            let keys = keycaps(recordHotkey).compactMap { $0.1 }.joined(separator: " ")
            if !keys.isEmpty { out.append(hintRun("  " + keys, 0.55)) }
        default: out.append(hintRun("Expand window"))
        }
        return out
    }

    // Hover: moving onto the idle capsule opens the action bar (the tracking
    // area is the whole window, so mouseMoved does the capsule test); the
    // hover watch closes it. Recording states ignore the cursor.
    override func mouseExited(with event: NSEvent) {
        guard compact, !morphing, wave.pill == .action else { return }
        // The hover watch closes the bar after a short grace; an exit event
        // alone should not slam it shut. Just drop the highlight.
        if !cursorInPill { setHover(nil) }
    }

    override func mouseMoved(with event: NSEvent) {
        guard compact else { return }
        let p = wave.convert(event.locationInWindow, from: nil)
        if wave.pill == .idle {
            if !morphing, wave.pillRect.contains(p) { setPill(.action, animated: true) }
            return
        }
        guard wave.pill == .action else { return }
        setHover(wave.actionButton(at: p))
    }

    /// Pill clicks: the action bar's three buttons, the rec disc (Stop), and
    /// the rec/mini toggle everywhere else. Nothing here activates the app.
    private func pillClick(at p: NSPoint) {
        switch wave.pill {
        case .idle:
            setPill(.action, animated: true)
        case .action:
            switch wave.actionButton(at: p) {
            case 0: onSettings?()
            case 1: onToggleRecord?()
            case 2:
                if recordingActive {
                    setCompact(false, animated: true)
                } else {
                    // Nothing to show in the card yet: switch modes and put
                    // it away; the next take opens as the full card.
                    setCompact(false, animated: false)
                    hide()
                }
            default: break
            }
        case .rec, .mini:
            // The disc is Stop; anywhere else on the pill toggles rec <-> mini.
            if wave.pill == .rec, wave.discRect.contains(p) { onToggleRecord?(); return }
            pillMiniPref.toggle()
            setPill(pillMiniPref ? .mini : .rec, animated: true)
        case .busy:
            break
        }
    }

    /// After a toggle the cursor may already sit in the icon hitbox.
    private func syncChevronHover() {
        guard !compact else { return }   // hidden in pill mode
        let local = chevron.convert(mouseInWindow, from: nil)
        chevron.alphaValue = chevron.bounds.contains(local) ? chevron.lit : 0
    }

    /// Top-right corner of the card. Hidden in pill mode, so no layout there.
    private func layoutChevron() {
        guard !compact else { return }
        let s: CGFloat = 18
        let b = wave.bounds
        chevron.autoresizingMask = [.minXMargin, .minYMargin]
        chevron.frame = NSRect(x: b.maxX - s - 12, y: b.maxY - s - 10, width: s, height: s)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownCompact = compact
        super.mouseDown(with: event)
    }

    // Full card: wherever you drag it is where it comes back next time.
    // Pill: route the click by state. Do not write panelOrigin from the
    // top-dock frame or the next full show jumps to the menu bar.
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if mouseDownCompact {
            if compact { pillClick(at: wave.convert(event.locationInWindow, from: nil)) }
            return
        }
        if !compact, abs(frame.height - WaveView.fullSize.height) < 1 {
            UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: "panelOrigin")
        }
    }

    private func place() {
        setFrameOrigin(origin(for: frame.size))
    }

    private func frame(for size: NSSize) -> NSRect {
        NSRect(origin: origin(for: size), size: size)
    }

    private func origin(for size: NSSize) -> NSPoint {
        if compact {
            let mouse = NSEvent.mouseLocation
            let s = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
            // screen.frame, not visibleFrame: the pill box sits over the notch
            // and the menu bar, flush with the top. Each state's inset below
            // that edge lives in pillShape.
            return NSPoint(x: s.frame.midX - size.width / 2, y: s.frame.maxY - size.height)
        }
        // Preferred spot: wherever it was dragged last, else bottom-center
        // of the screen with the mouse.
        var screen: NSScreen?
        var o = NSPoint.zero
        if let saved = UserDefaults.standard.string(forKey: "panelOrigin") {
            o = NSPointFromString(saved)
            screen = NSScreen.screens.first { $0.visibleFrame.intersects(NSRect(origin: o, size: size)) }
        }
        if screen == nil {
            let mouse = NSEvent.mouseLocation
            let s = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
            o = NSPoint(x: s.visibleFrame.midX - size.width / 2, y: s.visibleFrame.minY + 90)
            screen = s
        }
        // Clamp the whole card onto that screen. A stale frame after a
        // sleep/wake once stranded the panel at x=2606 on a 1440-wide screen:
        // dictation kept working with no visualizer in sight.
        if let f = screen?.visibleFrame {
            o.x = min(max(o.x, f.minX), max(f.minX, f.maxX - size.width))
            o.y = min(max(o.y, f.minY), max(f.minY, f.maxY - size.height))
        }
        return o
    }

    /// Stretchable rounded-rect mask. capInsets of `radius` keep the corners
    /// unscaled so the pill stays circular at any size.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: radius * 2, height: radius * 2), flipped: false) { rect in
            NSColor.black.set()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        img.resizingMode = .stretch
        return img
    }

    private static func chevronImage() -> NSImage? {
        guard let icon = NSImage(systemSymbolName: "arrow.up.right.and.arrow.down.left",
                                 accessibilityDescription: nil) else { return nil }
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        let img = icon.withSymbolConfiguration(cfg) ?? icon
        let s = img.size
        // 90° CCW: (x, y) -> (-y, x), then shift by height so it sits in the new bounds.
        let rotated = NSImage(size: NSSize(width: s.height, height: s.width), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.translateBy(x: s.height, y: 0)
            ctx.rotate(by: .pi / 2)
            img.draw(in: NSRect(origin: .zero, size: s), from: .zero,
                     operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return true
        }
        rotated.isTemplate = true
        return rotated
    }

    private func keycap(_ tok: String) -> String {
        switch tok.lowercased() {
        case "cmd", "command", "lcmd", "rcmd", "meta": return "⌘"
        case "alt", "opt", "option", "lalt", "ralt", "lopt", "ropt", "loption", "roption": return "⌥"
        case "shift", "lshift", "rshift": return "⇧"
        case "ctrl", "control", "lctrl", "rctrl": return "⌃"
        case "space": return "Space"
        default: return tok.capitalized
        }
    }
}
