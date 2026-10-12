import CoreGraphics
import Metal

/// Builds the displacement map for `GlitchOverlayView` on the GPU, evaluating the
/// original `random_f` from `reference/common.metal` in Metal.
///
/// The hash is `fract(sin(dot(x, float2(12.9898, 78.233))) * 43758.5453123)`:
/// ordinary float noise, but `sin` of a large argument amplifies any last-bit
/// difference across the whole output range. Swift's `sinf` and Metal's `sin`
/// disagree often enough that a CPU map reproduced only 72-77% of the original's
/// jitter blocks. Running the same expression on the GPU makes them identical.
///
/// Red carries the hash and green the same hash scaled by the layer's aspect, so
/// one scalar `inputAmount` displaces both axes by `0.005 * hash` in UV. Blue
/// must be 255: `displacementMap` multiplies its output by the map's blue channel.
final class JitterMap {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    /// Rotating buffers so a map still being read by the GPU is never overwritten.
    private var buffers: [MTLBuffer]
    private var contexts: [CGContext]
    private var index = 0

    let side: Int

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // Verbatim from reference/common.metal.
    float hash_1d(float2 x) { return fract(sin(dot(x, float2(12.9898, 78.233))) * 43758.5453123); }
    float random_f(float2 uv) { return hash_1d(uv); }
    float2 floor_to_nearest2(float2 value, float2 step) { return floor(value / step) * step; }

    kernel void jitterMap(device uchar4 *out [[buffer(0)]],
                          constant float &t [[buffer(1)]],
                          constant float &aspect [[buffer(2)]],
                          constant uint &side [[buffer(3)]],
                          constant uint &cell [[buffer(4)]],
                          constant float &shift [[buffer(5)]],
                          uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= side || gid.y >= side) return;
        uint blocks = side / cell;
        uint bx = gid.x / cell;
        // Image row 0 is the layer's top; UV y runs bottom-up.
        uint by = blocks - 1 - gid.y / cell;
        // 03-shaky samples at uv + shift, then quantises with floor_to_nearest2.
        float2 uv = (float2(float(bx), float(by)) + 0.5) / float(blocks) + shift;
        float h = random_f(float2(floor_to_nearest2(uv, float2(1.0 / float(blocks))) + t));
        out[gid.y * side + gid.x] = uchar4(uchar(round(h * 255.0)),
                                           uchar(round(h * aspect * 255.0)),
                                           255, 255);
    }
    """

    /// `colorSpace` tags the generated images: it must be the display's own, or
    /// WindowServer colour-converts the map and the warp lands in the wrong place
    /// (measured: 5pt off on a Display P3 screen).
    init?(blocks: Int, texelsPerBlock: Int, colorSpace: CGColorSpace) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.source, options: nil),
              let function = library.makeFunction(name: "jitterMap"),
              let pipeline = try? device.makeComputePipelineState(function: function)
        else { return nil }

        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.side = blocks * texelsPerBlock

        var buffers: [MTLBuffer] = []
        var contexts: [CGContext] = []
        for _ in 0..<3 {
            guard let buffer = device.makeBuffer(length: side * side * 4, options: .storageModeShared),
                  let ctx = CGContext(
                      data: buffer.contents(), width: side, height: side, bitsPerComponent: 8,
                      bytesPerRow: side * 4, space: colorSpace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return nil }
            buffers.append(buffer)
            contexts.append(ctx)
        }
        self.buffers = buffers
        self.contexts = contexts
    }

    /// The map for time `t`. `shift` is the shader's UV offset (-0.10).
    func image(t: Float, aspect: Float, shift: Float, cell: Int) -> CGImage? {
        index = (index + 1) % buffers.count
        let buffer = buffers[index]
        var t = t, aspect = aspect, shift = shift
        var side = UInt32(self.side), cell = UInt32(cell)

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.setBytes(&t, length: 4, index: 1)
        encoder.setBytes(&aspect, length: 4, index: 2)
        encoder.setBytes(&side, length: 4, index: 3)
        encoder.setBytes(&cell, length: 4, index: 4)
        encoder.setBytes(&shift, length: 4, index: 5)
        let threads = MTLSize(width: self.side, height: self.side, depth: 1)
        let group = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreads(threads, threadsPerThreadgroup: group)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return contexts[index].makeImage()
    }
}
