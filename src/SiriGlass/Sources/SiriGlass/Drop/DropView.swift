//
//  DropView.swift
//  SiriGlass
//
//  Draws one drop. This fork draws the glass itself (DropMetalView): it
//  captures what is behind the drop and bends it along the drop's outline,
//  with the ink and light of SiriGlass.metal laid over it, so it runs on
//  iOS 16 where there is no system Liquid Glass.
//
//  The drop is an overlay: nothing behind it is re-rendered or flattened,
//  so lists, maps, text fields and video keep working under it.
//

import SwiftUI

struct DropView: View {
    enum Placement { case island, orb }

    let placement: Placement
    let binding: Binding<SiriGlassState>?
    let fixed: SiriGlassState
    let audio: SiriGlassAudio

    @Environment(\.siriGlassTake) private var take
    @Environment(\.siriGlassProbe) private var probe
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.siriGlassCaption) private var caption

    @State private var engine = DropEngine()
    /// True once the drop is home and still: the timeline stops ticking.
    @State private var resting = true
    @State private var window: WindowMetrics?

    private var requested: SiriGlassState { binding?.wrappedValue ?? fixed }

    var body: some View {
        let paused = take == nil && resting && requested == .idle
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: nil, paused: paused)) { context in
                drop(at: context.date, in: proxy)
            }
        }
        .background {
            if placement == .island {
                WindowReader { window = $0 }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onDisappear {
            engine.stop()
            resting = true
        }
    }

    @ViewBuilder
    private func drop(at date: Date, in proxy: GeometryProxy) -> some View {
        let space = layout(in: proxy)
        let backdrop = placement == .orb ? (colorScheme == .light ? 1.0 : 0.35) : 0
        let out = engine.frame(at: date, requested: requested, audio: audio, writable: binding != nil,
                               take: take, layout: space.layout, backdrop: backdrop, card: cardTarget(space))
        let _ = commit(out)
        ZStack(alignment: .topLeading) {
            if placement == .orb {
                OrbShadow(frame: out.frame, strength: backdrop)
            }
            DropMetalView(drop: out.frame, size: space.size)
            if !out.glyphs.isEmpty, out.outline.count > 2 {
                // Never outside the glass, whatever it is doing.
                CaptionWordsView(glyphs: out.glyphs)
                    .mask(DropOutline(points: out.outline))
            }
        }
        .frame(width: space.size.width, height: space.size.height)
        .offset(space.offset)
    }

    /// Where the drop goes. Under the island its layer covers the top of the
    /// window, wherever this view sits in it; as an orb, this view's bounds.
    private func layout(in proxy: GeometryProxy) -> (layout: DropEngine.Layout, size: CGSize, offset: CGSize) {
        switch placement {
        case .island:
            let global = proxy.frame(in: .global)
            let metrics = window ?? WindowMetrics(size: CGSize(width: global.maxX, height: global.maxY),
                                                  safeAreaTop: proxy.safeAreaInsets.top + global.minY, isPhone: true)
            let island = SiriGlassIsland.override ?? DropGeometry.island(in: metrics)
            // Tall enough for the caption card at its deepest.
            let size = CGSize(width: metrics.size.width,
                              height: max(DropGeometry.reach, CaptionGeometry.maxBottom(island: island, windowHeight: Double(metrics.size.height)) + 24))
            return (.island(island), size, CGSize(width: -global.minX, height: -global.minY))
        case .orb:
            let size = proxy.size
            // The orb keeps the drop's proportions, with room to swell.
            let scale = max(min(size.width / DropGeometry.size.width, size.height / DropGeometry.size.height) / 1.08, 0.05)
            return (.orb(centre: CGPoint(x: size.width / 2, y: size.height / 2), scale: scale), size, .zero)
        }
    }

    /// The caption to grow the drop round, under the island only.
    private func cardTarget(_ space: (layout: DropEngine.Layout, size: CGSize, offset: CGSize)) -> DropEngine.CardTarget? {
        guard let caption, !caption.isEmpty, case .island(let island) = space.layout else { return nil }
        let deepest = CaptionGeometry.maxBottom(island: island, windowHeight: Double(window?.size.height ?? 0))
        return DropEngine.CardTarget(caption: caption, island: island, windowWidth: space.size.width, maxBottom: deepest)
    }

    /// Hands what the frame decided back to SwiftUI, after the update.
    private func commit(_ out: DropEngine.Output) {
        if placement == .island, SiriGlassCaptionGlass.frame != out.glassTarget {
            let frame = out.glassTarget
            DispatchQueue.main.async { SiriGlassCaptionGlass.frame = frame }
        }
        if placement == .island, SiriGlassCaptionGlass.current != out.glassNow {
            let frame = out.glassNow
            DispatchQueue.main.async { SiriGlassCaptionGlass.current = frame }
        }
        if placement == .island, SiriGlassAttachment.frame != out.attachmentFrame {
            let frame = out.attachmentFrame, radius = out.attachmentRadius
            DispatchQueue.main.async {
                SiriGlassAttachment.frame = frame
                SiriGlassAttachment.cornerRadius = radius
            }
        }
        probe?.record(out, state: engine.mode)
        if let request = out.request, let binding {
            DispatchQueue.main.async {
                if binding.wrappedValue == request.from { binding.wrappedValue = request.to }
            }
        }
        if out.resting != resting {
            let now = out.resting
            DispatchQueue.main.async { resting = now }
        }
    }
}

/// The soft shadow an orb casts on a light backdrop.
struct OrbShadow: View {
    let frame: DropFrame
    let strength: Double

    var body: some View {
        let scale = frame.scale
        let w = Double(frame.drop.z) * scale, h = Double(frame.drop.w) * scale
        let opacity = 0.24 * strength * Double(frame.presence)
        Ellipse()
            .fill(RadialGradient(colors: [.black.opacity(opacity), .black.opacity(opacity * 0.4), .black.opacity(0)],
                                 center: .center, startRadius: 0, endRadius: w * 0.86))
            .frame(width: w * 1.72, height: h * 0.24)
            .position(x: Double(frame.drop.x), y: Double(frame.drop.y) + h * 1.13)
            .opacity(frame.isVisible ? 1 : 0)
    }
}
