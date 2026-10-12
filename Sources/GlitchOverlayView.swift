import AppKit
import QuartzCore

/// Private QuartzCore primitives.
///
/// `CABackdropLayer` is what `NSVisualEffectView` is built on: it samples the
/// composited content behind the window inside WindowServer and applies
/// `CAFilter`s to it. The pixels are never handed to this process, so macOS does
/// not treat it as screen capture and never asks for Screen Recording.
///
/// These are private APIs: undocumented, and liable to change in any macOS
/// release. Every lookup fails soft, so a missing symbol degrades to the painted
/// overlay instead of crashing.
enum PrivateCA {
    static let backdropClass = NSClassFromString("CABackdropLayer") as? CALayer.Type
    private static let filterClass: AnyClass? = NSClassFromString("CAFilter")

    static func makeBackdrop() -> CALayer? { backdropClass?.init() }

    /// Named so values can be animated via `filters.<name>.<inputKey>` key paths.
    static func filter(_ type: String, name: String) -> NSObject? {
        guard let cls = filterClass as AnyObject? else { return nil }
        let sel = NSSelectorFromString("filterWithType:")
        guard cls.responds(to: sel),
              let filter = cls.perform(sel, with: type)?.takeUnretainedValue() as? NSObject
        else { return nil }
        filter.setValue(name, forKey: "name")
        return filter
    }

    /// A backdrop's output comes back about 96.5% opaque, so ~3.5% of the
    /// unfiltered screen shows through as a ghost (live probe: 247 where 255 was
    /// expected, 9.7 where 0 was). This colour matrix leaves RGB alone and sets
    /// alpha to 1; with it the same probe read exactly 255 and 0.
    static func opaqueAlpha() -> NSObject? {
        guard let filter = filter("colorMatrix", name: "opaque") else { return nil }
        var matrix: [Float] = [
            1, 0, 0, 0, 0,
            0, 1, 0, 0, 0,
            0, 0, 1, 0, 0,
            0, 0, 0, 0, 1,
        ]
        let value = NSValue(bytes: &matrix, objCType: "{CAColorMatrix=ffffffffffffffffffff}")
        filter.setValue(value, forKey: "inputColorMatrix")
        return filter
    }
}

/// `random_f` from `reference/common.metal`:
/// `fract(sin(dot(x, float2(12.9898, 78.233))) * 43758.5453123)`.
///
/// Used for the handful of per-frame scalars (the channel split) and for building
/// the colour table, where a last-bit difference from Metal's `sin` is invisible.
/// The per-pixel jitter field is generated on the GPU instead: see `JitterMap`.
@inline(__always)
func shaderHash(_ x: Float, _ y: Float) -> Float {
    let s = sinf(x * 12.9898 + y * 78.233) * 43758.5453123
    return s - floorf(s)
}

/// The geometry of `reference/03-shaky.metal`, expressed for the private filters.
///
/// Filter behaviour, measured with offscreen `CARenderer` probes, in the layer's
/// y-up coordinates:
/// - `displacementMap`: `out(p) = src(p + amount * (map - offset))`, red channel
///   on x, green on y. The map is stretched over the layer with its first image
///   row at the top, bilinearly interpolated, and its blue channel multiplies the
///   output, so blue must be 255. Samples outside the layer clamp to the edge.
/// - `chromaticAberration`: moves one channel's content by its offset.
/// - Filters apply in array order. Splitting before warping gives
///   `out_c(p) = src(p + jitter(p) + d_c)`: one jitter field shared by all three
///   channels, as in the shader.
enum ShakyGeometry {
    /// `uv += -0.10`, wrapped by `fract`.
    static let globalShift: CGFloat = -0.10
    /// Jitter blocks per axis: `floor_to_nearest2(uv, float2(0.01))`.
    static let blocks = 100
    /// Jitter reach in UV: `random_f(...) * 0.005`.
    static let jitterUV: CGFloat = 0.005
    /// Texels per block in the map. Interpolation softens block edges into a ramp
    /// about 1/6 of a block wide; the shader's edges are hard.
    static let texelsPerBlock = 6
    /// `floor_to_nearest(t, 0.3)`: the split re-rolls every 0.3s.
    static let splitStep: Float = 0.3

    /// One pane per region of the `fract` wrap: sampling offset in points, and
    /// the region it covers, both in layer y-up coordinates.
    static func panes(size: CGSize) -> [(sample: CGPoint, region: CGRect)] {
        let w = size.width, h = size.height
        let sx = globalShift * w, sy = globalShift * h   // both negative
        let ex = -sx, ey = -sy                            // wrapped strip widths
        return [
            (CGPoint(x: sx, y: sy), CGRect(x: ex, y: ey, width: w - ex, height: h - ey)),
            (CGPoint(x: sx + w, y: sy), CGRect(x: 0, y: ey, width: ex, height: h - ey)),
            (CGPoint(x: sx, y: sy + h), CGRect(x: ex, y: 0, width: w - ex, height: ey)),
            (CGPoint(x: sx + w, y: sy + h), CGRect(x: 0, y: 0, width: ex, height: ey)),
        ]
    }

    static func amount(size: CGSize) -> CGFloat { jitterUV * size.width }

    /// `inputOffset` that makes a pane sample at `sample` points from each pixel.
    static func offset(sample: CGPoint, size: CGSize) -> CGPoint {
        let a = amount(size: size)
        return CGPoint(x: -sample.x / a, y: -sample.y / a)
    }

    /// Channel shifts at time `t`, in points of content movement.
    /// Red samples at `uv + dr`, green at `uv - dg`, blue is unshifted. The
    /// per-row `sin(uv.y + t)` term is taken at mid-screen: it moves content by
    /// under 0.01pt, and the filter cannot vary it per row.
    static func split(t: Float, size: CGSize) -> (red: CGPoint, green: CGPoint) {
        let stepped = floorf(t / splitStep) * splitStep
        let ar = shaderHash(stepped * 0.189, stepped * 0.189)
        let ag = shaderHash(stepped * 0.287, stepped * 0.287)
        let wobble = sinf(0.5 + t) * 0.003
        let dr = CGFloat(0.002 + (ar + wobble) * 0.02)
        let dg = CGFloat(0.002 + (ag + wobble) * 0.02)
        return (CGPoint(x: -dr * size.width, y: -dr * size.height),
                CGPoint(x: dg * size.width, y: dg * size.height))
    }

}

/// The colour half of `reference/03-shaky.metal`, as a lookup table:
///
/// ```metal
/// color = rgb2hsv(color);
/// color.r = fract(color.b + random_f(float2(floor_to_nearest(color.g, 0.05))));
/// color = hsv2rgb(color);
/// ```
///
/// The remap is a pure function of the 8-bit colour, so a 256³ table has an entry
/// for every input and never interpolates across the hue wrap or the saturation
/// steps. Smaller tables blur those jumps (mean error 11/255 at 64³, 0.2 at 256³).
///
/// The private `lut` filter takes a vertical strip `n` wide and `n * n` tall:
/// image row `b * n + g`, column `r`. The table is 64 MB and takes a few hundred
/// milliseconds to build, so it is built once, off the main thread, and shared.
///
/// WindowServer colour-converts the table's output from its tagged colour space
/// into the display's. The original wrote its results to the display with no
/// conversion, so the table must be tagged with the display's own colour space.
/// Tagged sRGB on a Display P3 screen, saturated colours came back measurably
/// washed out (want 0.07 0.75 0.45, got 0.35 0.74 0.48).
enum ShakyColor {
    static let size = 256

    private static let provider: CGDataProvider? = {
        let n = size
        var data = Data(count: n * n * n * 4)
        data.withUnsafeMutableBytes { raw in
            let px = raw.bindMemory(to: UInt8.self).baseAddress!
            let top = Float(n - 1)
            for b in 0..<n {
                for g in 0..<n {
                    var i = (b * n + g) * n * 4
                    for r in 0..<n {
                        let c = remap(Float(r) / top, Float(g) / top, Float(b) / top)
                        px[i] = UInt8((c.r * 255).rounded())
                        px[i + 1] = UInt8((c.g * 255).rounded())
                        px[i + 2] = UInt8((c.b * 255).rounded())
                        px[i + 3] = 255
                        i += 4
                    }
                }
            }
        }
        return CGDataProvider(data: data as CFData)
    }()

    /// Builds the shared table on first use; call off the main thread to prewarm.
    static func prewarm() { _ = provider }

    /// The table tagged with `space`, the colour space of the display it will
    /// filter. Cheap after the first call: every tag shares one 64 MB buffer.
    static func lut(for space: CGColorSpace) -> CGImage? {
        guard let provider else { return nil }
        let n = size
        return CGImage(width: n, height: n * n, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: n * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    /// `rgb2hsv` and `hsv2rgb` from `common.metal`, with 03-shaky's hue rewrite.
    static func remap(_ r: Float, _ g: Float, _ b: Float) -> (r: Float, g: Float, b: Float) {
        @inline(__always) func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
        @inline(__always) func step(_ edge: Float, _ x: Float) -> Float { x < edge ? 0 : 1 }

        // rgb2hsv: only saturation and value are needed; the hue is replaced.
        let s1 = step(b, g)
        let px = mix(b, g, s1), py = mix(g, b, s1)
        let s2 = step(px, r)
        let qx = mix(px, r, s2), qy = py, qw = mix(r, px, s2)
        let d = qx - min(qw, qy)
        let e: Float = 1.0e-10
        let s = d / (qx + e)
        let v = qx

        let stepped = floorf(s / 0.05) * 0.05
        let hRaw = v + shaderHash(stepped, stepped)
        let h = hRaw - floorf(hRaw)

        // hsv2rgb
        @inline(__always) func channel(_ k: Float) -> Float {
            let f = h + k
            let p = abs((f - floorf(f)) * 6 - 3)
            return v * mix(1, max(0, min(1, p - 1)), s)
        }
        return (channel(1), channel(2.0 / 3.0), channel(1.0 / 3.0))
    }
}

/// Full-screen overlay reproducing `reference/03-shaky.metal` on the real desktop:
/// block jitter, RGB split and hue remap, at the original's 60 fps.
final class GlitchOverlayView: NSView {
    private var panes: [(layer: CALayer, sample: CGPoint)] = []
    private let jitter: JitterMap?

    /// `colorSpace` is the colour space of the display this view covers. Both the
    /// colour table and the jitter map are tagged with it, so WindowServer applies
    /// no conversion, exactly as the original wrote shader output to the screen.
    init(frame frameRect: NSRect, colorSpace: CGColorSpace) {
        jitter = JitterMap(blocks: ShakyGeometry.blocks,
                           texelsPerBlock: ShakyGeometry.texelsPerBlock,
                           colorSpace: colorSpace)
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        if jitter == nil { log("Metal unavailable; glitch overlay disabled") }
        buildPanes(colorSpace: colorSpace)
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:colorSpace:)") }

    override var isOpaque: Bool { false }

    // The jitter map is generated on the GPU; see JitterMap.

    private func buildPanes(colorSpace: CGColorSpace) {
        // Shared backdrop group so the wrap panes sample the desktop, not each
        // other's filtered output.
        let group = UUID().uuidString
        for (sample, region) in ShakyGeometry.panes(size: bounds.size) {
            guard let backdrop = PrivateCA.makeBackdrop() else {
                log("CABackdropLayer unavailable; painted overlay only")
                return
            }
            backdrop.frame = bounds
            backdrop.setValue(true, forKey: "windowServerAware")
            backdrop.setValue(group, forKey: "groupName")
            // Protected content substitutes a colour instead of drawing black.
            backdrop.setValue(true, forKey: "allowsSubstituteColor")
            // Off: with group blending on, the unfiltered desktop bled through the
            // overlay (a live probe read 10/255 at a spot that should be 0, and 19
            // where 255 was expected); off, it read 0 and 255 exactly.
            backdrop.setValue(false, forKey: "allowsGroupBlending")
            backdrop.setValue(1.0, forKey: "scale")
            backdrop.setValue(false, forKey: "allowsInPlaceFiltering")

            var filters: [NSObject] = []
            if let split = PrivateCA.filter("chromaticAberration", name: "split") {
                split.setValue(true, forKey: "inputExtendEdges")
                filters.append(split)
            }
            if let warp = PrivateCA.filter("displacementMap", name: "warp") {
                warp.setValue(ShakyGeometry.amount(size: bounds.size), forKey: "inputAmount")
                warp.setValue(ShakyGeometry.offset(sample: sample, size: bounds.size),
                              forKey: "inputOffset")
                filters.append(warp)
            }
            // Last, as in the shader: the hue remap reads the split, warped colour.
            if let remap = PrivateCA.filter("lut", name: "remap"),
               let table = ShakyColor.lut(for: colorSpace) {
                remap.setValue(table, forKey: "inputColorMap")
                filters.append(remap)
            }
            if let opaque = PrivateCA.opaqueAlpha() { filters.append(opaque) }
            backdrop.filters = filters

            let cover = CALayer()
            cover.frame = region
            cover.backgroundColor = CGColor(gray: 1, alpha: 1)
            backdrop.mask = cover

            layer?.addSublayer(backdrop)
            panes.append((backdrop, sample))
        }
    }

    var time: TimeInterval = 0 {
        didSet { animate(Float(time)) }
    }

    private func animate(_ t: Float) {
        guard !panes.isEmpty, let jitter, bounds.width > 0 else { return }
        guard let map = jitter.image(t: t,
                                     aspect: Float(bounds.height / bounds.width),
                                     shift: Float(ShakyGeometry.globalShift),
                                     cell: ShakyGeometry.texelsPerBlock) else { return }
        let split = ShakyGeometry.split(t: t, size: bounds.size)

        // Parameters change every frame; implicit animations would smear them.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for pane in panes {
            pane.layer.setValue(map, forKeyPath: "filters.warp.inputMaskImage")
            pane.layer.setValue(split.red, forKeyPath: "filters.split.inputRedOffset")
            pane.layer.setValue(split.green, forKeyPath: "filters.split.inputGreenOffset")
            pane.layer.setValue(CGPoint.zero, forKeyPath: "filters.split.inputBlueOffset")
        }
        CATransaction.commit()
    }
}

