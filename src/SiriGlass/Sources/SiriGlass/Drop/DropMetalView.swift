//
//  DropMetalView.swift
//  SiriGlass
//
//  iOS 16 backport of the drop's glass and ink. SwiftUI's shaders and the
//  system's Liquid Glass need iOS 17 and 26, so the drop is drawn by one
//  Metal pass instead: each frame the view captures what is behind it, and
//  SiriGlass.metal bends that along the drop's outline and paints the ink
//  and light over it.
//

import MetalKit
import SwiftUI
import UIKit

/// Mirrors `SGUniforms` in SiriGlass.metal.
struct DropUniforms {
    var island = SIMD4<Float>(), drop = SIMD4<Float>(), form = SIMD4<Float>(), amps = SIMD4<Float>()
    var phases = SIMD4<Float>(), light = SIMD4<Float>(), extra = SIMD4<Float>()
    /// Thickness (pt), refractive index, dispersion, shift scale (pt).
    var glass = SIMD4<Float>(14, 1.5, 4, 18)
    /// The layer's size (pt), and the caption's corner radius.
    var size = SIMD4<Float>()
    /// A card set into the glass: its frame, and corner radius and openness.
    var hole = SIMD4<Float>()
    var holeStyle = SIMD4<Float>()
}

extension DropFrame {
    func uniforms(size: CGSize) -> DropUniforms {
        DropUniforms(
            island: SIMD4(Float(island.minX), Float(island.minY), Float(island.width), Float(island.height)),
            drop: drop, form: SIMD4(exponent, presence, neck, time), amps: amps, phases: phases,
            light: light, extra: extra, size: SIMD4(Float(size.width), Float(size.height), cornerRadius, inkFade),
            hole: SIMD4(Float(hole.minX), Float(hole.minY), Float(hole.width), Float(hole.height)),
            holeStyle: SIMD4(holeRadius, holeOpen, 0, 0))
    }
}

struct DropMetalView: UIViewRepresentable {
    let drop: DropFrame
    let size: CGSize

    func makeUIView(context: Context) -> DropCanvas { DropCanvas() }

    func updateUIView(_ canvas: DropCanvas, context: Context) {
        canvas.render(drop.uniforms(size: size), visible: drop.isVisible)
    }
}

final class DropCanvas: MTKView {
    private let queue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?
    private var uniforms = DropUniforms()
    private var visible = false
    private var backdrop: MTLTexture?
    private var captured = -Double.infinity
    private var pixels = [UInt8]()
    /// Debug: average milliseconds a backdrop capture takes (SIRIGLASS_PERF=1 logs it).
    private var spent = 0.0, captures = 0

    init() {
        let device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        var made: MTLRenderPipelineState?
        var compiled: MTLLibrary?
        do { compiled = try device?.makeLibrary(source: siriGlassShaderSource, options: nil) }
        catch { NSLog("SiriGlass: shader failed to compile: \(error)") }
        if let device, let library = compiled {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "siriGlassVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "siriGlassFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            made = try? device.makeRenderPipelineState(descriptor: descriptor)
        }
        pipeline = made
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        isOpaque = false
        backgroundColor = .clear
        isPaused = true
        enableSetNeedsDisplay = false
        framebufferOnly = true
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        contentScaleFactor = min(UIScreen.main.scale, 3)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    func render(_ next: DropUniforms, visible: Bool) {
        uniforms = next
        let wasVisible = self.visible
        self.visible = visible
        guard bounds.width > 1, bounds.height > 1 else { return }
        // While a caption is up, keep the picture taken before it: a fresh
        // capture would hold the caption's own words, and the glass would
        // bend them back at itself. Unless the host's picture leaves the
        // glass out: then it follows the screen (an app opening under it).
        if visible, !wasVisible || next.light.w < 0.001 || SiriGlassBackdrop.excludesGlass {
            refreshBackdrop(force: !wasVisible || SiriGlassBackdrop.requestedAt > captured)
        }
        guard visible || wasVisible else { return }   // once cleared, nothing to redraw
        drawableSize = CGSize(width: bounds.width * contentScaleFactor, height: bounds.height * contentScaleFactor)
        draw()
    }

    /// Seconds between captures. A capture is software-rendered on the main
    /// thread (~15 ms for the island strip even on a Mac), so doing it every
    /// frame made the drop stutter; what is behind a drop that lasts a few
    /// seconds barely changes, so it refreshes twice a second.
    private static let backdropInterval: Double = {
        ProcessInfo.processInfo.environment["SIRIGLASS_BACKDROP_HZ"].flatMap(Double.init).map { 1 / max($0, 0.1) } ?? 0.5
    }()

    /// Captures the window behind this view, without this view, at 1x: the
    /// glass only bends it, so detail is lost on it.
    private func refreshBackdrop(force: Bool) {
        let now = CACurrentMediaTime()
        let provided = SiriGlassBackdrop.provider
        let interval = provided == nil ? Self.backdropInterval : SiriGlassBackdrop.refreshInterval
        if provided != nil && !force && (interval <= 0 || now - captured < interval) { return }
        guard force || now - captured > interval, let device, let window else { return }
        captured = now
        let scale: CGFloat = 1
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        guard width > 0, height > 0 else { return }
        if backdrop?.width != width || backdrop?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = .shaderRead
            backdrop = device.makeTexture(descriptor: descriptor)
        }
        guard let backdrop else { return }

        let started = CACurrentMediaTime()
        if pixels.count != width * height * 4 { pixels = [UInt8](repeating: 0, count: width * height * 4) }
        else { pixels.withUnsafeMutableBytes { _ = memset($0.baseAddress!, 0, $0.count) } }
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)
            else { return false }
            // UIKit's top-left origin, then this view's corner at the context's.
            let origin = convert(bounds.origin, to: window)
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
            context.translateBy(x: -origin.x, y: -origin.y)
            context.clip(to: CGRect(origin: origin, size: bounds.size))
            if let image = provided?() {
                // The host's picture of the whole screen, drawn in points.
                let size = window.bounds.size
                context.saveGState()
                context.translateBy(x: 0, y: size.height)
                context.scaleBy(x: 1, y: -1)
                context.draw(image, in: CGRect(origin: .zero, size: size))
                context.restoreGState()
                return true
            }
            let hidden = layer.isHidden
            layer.isHidden = true
            window.layer.render(in: context)
            layer.isHidden = hidden
            return true
        }
        guard drawn else { return }
        pixels.withUnsafeBytes {
            backdrop.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                             withBytes: $0.baseAddress!, bytesPerRow: width * 4)
        }
        if ProcessInfo.processInfo.environment["SIRIGLASS_PERF"] == "1" {
            spent += CACurrentMediaTime() - started
            captures += 1
            if captures % 40 == 0 { NSLog("SiriGlass capture avg %.2f ms (%dx%d)", spent / Double(captures) * 1000, width, height) }
        }
    }

    override func draw(_ rect: CGRect) {
        guard let queue, let pipeline, let backdrop, let pass = currentRenderPassDescriptor,
              let drawable = currentDrawable, let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        if visible {
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<DropUniforms>.stride, index: 0)
            encoder.setFragmentTexture(backdrop, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}
