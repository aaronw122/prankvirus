import AppKit
import QuartzCore

/// Second effect: the whole display, menu bar and Dock included, pushed sideways.
///
/// One `CABackdropLayer` resamples everything behind the window, offset by a
/// fixed distance. Nothing else changes, so it reads as the Mac's own picture
/// having slipped. The strip uncovered on the left is solid black.
final class ShiftOverlayView: NSView {
    /// Points the picture moves right.
    static let shift: CGFloat = 300

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        guard let backdrop = PrivateCA.makeBackdrop(),
              let warp = PrivateCA.filter("displacementMap", name: "warp"),
              let map = Self.zeroMap()
        else {
            log("CABackdropLayer unavailable; shift effect disabled")
            return
        }
        backdrop.frame = bounds
        backdrop.setValue(true, forKey: "windowServerAware")
        backdrop.setValue(true, forKey: "allowsSubstituteColor")
        backdrop.setValue(1.0, forKey: "scale")
        // Off, or the unshifted desktop shows through faintly underneath.
        backdrop.setValue(false, forKey: "allowsGroupBlending")
        backdrop.setValue(false, forKey: "allowsInPlaceFiltering")

        // displacementMap computes out(p) = src(p + amount * (map - offset)).
        // A zero map turns that into a constant: out(p) = src(p - amount * offset).
        let amount: CGFloat = 50
        warp.setValue(map, forKey: "inputMaskImage")
        warp.setValue(amount, forKey: "inputAmount")
        warp.setValue(CGPoint(x: Self.shift / amount, y: 0), forKey: "inputOffset")
        // Without the opaque-alpha stage ~3.5% of the unshifted screen ghosts through.
        backdrop.filters = [warp] + (PrivateCA.opaqueAlpha().map { [$0] } ?? [])
        layer?.addSublayer(backdrop)

        // The filter fills the uncovered strip on the left by stretching the
        // screen's edge pixels into streaks. Cover it so nothing shows there.
        let strip = CALayer()
        strip.frame = CGRect(x: 0, y: 0, width: Self.shift, height: bounds.height)
        strip.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer?.addSublayer(strip)
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override var isOpaque: Bool { false }

    /// Zero displacement on both axes. Blue must be 255: the filter multiplies
    /// its output by the map's blue channel.
    private static func zeroMap() -> CGImage? {
        let side = 4
        var px = [UInt8](repeating: 0, count: side * side * 4)
        for i in 0..<(side * side) {
            px[i * 4 + 2] = 255
            px[i * 4 + 3] = 255
        }
        return px.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8,
                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }
}
