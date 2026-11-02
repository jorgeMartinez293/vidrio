import AppKit

/// Translucent blur shown behind terminal text.
///
/// On macOS 26+ this is Liquid Glass (`NSGlassEffectView`). A behind-window
/// `NSVisualEffectView` loses its blur while its window is dragged in
/// Mission Control: the window server paints it as a flat gray sheet for
/// the whole drag, which flickers in and out and washes out the text on
/// top. Glass keeps rendering correctly there. Older systems have no glass
/// and fall back to the visual effect view, so `BlurMaterial` only picks
/// a material on those; on macOS 26+ it just turns the blur on or off.
///
/// Corners are clipped by this view's own layer (`cornerRadius`,
/// `maskedCorners`), so callers shape it the same way on every system.
final class BackdropView: NSView {
    /// Darkens the glass to the HUD material's look. A plain layer over
    /// untinted glass matches it far better than `tintColor`, which makes
    /// the regular style lighter, or the clear style, which barely blurs.
    private static let glassDimming = NSColor.black.withAlphaComponent(0.5)

    private let effectView: NSView

    override init(frame frameRect: NSRect) {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            // Shape comes from this view's clipping instead, which also
            // supports rounding only some corners.
            glass.cornerRadius = 0
            effectView = glass
        } else {
            let blur = NSVisualEffectView()
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.material = .hudWindow
            effectView = blur
        }
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        effectView.frame = bounds
        effectView.autoresizingMask = [.width, .height]
        addSubview(effectView)

        if #available(macOS 26.0, *) {
            let dimming = NSView(frame: bounds)
            dimming.wantsLayer = true
            dimming.layer?.backgroundColor = Self.glassDimming.cgColor
            dimming.autoresizingMask = [.width, .height]
            addSubview(dimming)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var cornerRadius: CGFloat {
        get { layer?.cornerRadius ?? 0 }
        set { layer?.cornerRadius = newValue }
    }

    var maskedCorners: CACornerMask {
        get { layer?.maskedCorners ?? [] }
        set { layer?.maskedCorners = newValue }
    }

    /// Shows the blur for `material`, or hides it for `.none`.
    func apply(_ material: BlurMaterial) {
        guard let nsMaterial = material.material else {
            isHidden = true
            return
        }
        isHidden = false
        (effectView as? NSVisualEffectView)?.material = nsMaterial
    }

    /// Whether `BlurMaterial` picks between materials on this system, or
    /// only turns the blur on and off (Liquid Glass).
    static var supportsMaterials: Bool {
        if #available(macOS 26.0, *) { return false }
        return true
    }
}
