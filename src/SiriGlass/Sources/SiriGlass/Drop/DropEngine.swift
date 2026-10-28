//
//  DropEngine.swift
//  SiriGlass
//
//  The life of one drop, a frame at a time: when it was summoned, when it
//  started thinking, when it left, and what it is hearing. Every frame it
//  turns those into the shader's uniforms. Nothing animates on its own:
//  shape, light and voice are all functions of one clock, so a scripted
//  take can be slowed down for recording and still come out identical.
//

import SwiftUI
import UIKit

@MainActor
final class DropEngine {

    /// Where the drop is drawn.
    enum Layout {
        /// Hanging from the island (in the layer's space).
        case island(CGRect)
        /// On its own, centred, at `scale` times its size under the island.
        case orb(centre: CGPoint, scale: Double)
    }

    struct Output {
        var frame: DropFrame
        var outline: [CGPoint]
        /// A change the drop made by itself, for the binding: from, to.
        var request: (from: SiriGlassState, to: SiriGlassState)?
        /// Nothing left to animate: home, still, silent.
        var resting: Bool
        /// The caption's words as drawn this frame.
        var glyphs: [CaptionGlyph] = []
        /// Where the caption's card goes (window coordinates) once the glass
        /// has made room for it, and its corner radius.
        var attachmentFrame: CGRect?
        var attachmentRadius = 0.0
        /// Where the caption's glass is heading, while it is open.
        var glassTarget: CGRect?
        /// The glass as drawn this frame, across the status bar's band only
        /// (window coordinates), while a caption has it; nil otherwise.
        var glassNow: CGRect?
    }

    /// A caption for the drop to grow round, under `island` in a window
    /// `windowWidth` wide.
    struct CardTarget {
        var caption: SiriGlassCaption
        var island: CGRect
        var windowWidth: CGFloat
        /// How deep the glass may go (window coordinates).
        var maxBottom: Double = .infinity
    }

    // MARK: State

    /// What the drop is doing now.
    private(set) var mode: SiriGlassState = .idle
    private var summonedAt: Double?
    private var dismissedAt: Double?
    private var listeningSince = 0.0
    private var think = Ramp()
    /// Extra strand travel while thinking: the swirl.
    private var swirl = 0.0

    private var epoch: Date?
    private var lastClock: Double?

    private var drive = VoiceDrive()
    private var speech = SpeechEnd()
    /// A change the drop made that the binding hasn't caught up with.
    private var awaiting: (from: SiriGlassState, to: SiriGlassState)?

    // The audio source while listening.
    private var listeningTo: SiriGlassAudio?
    private var mic: MicListener?
    private var file: FileVoice?
    private var trackStart = 0.0

    // A caption: the drop grows to hold it while there is one, as wide and
    // deep as the words in it so far.
    private let reveal = CaptionReveal()
    private var card: CaptionGlass?
    private var cardOpen = Spring01()
    private var cardOpenedAt = 0.0
    private var textWidth = CaptionSpring(0)
    private var textHeight = CaptionSpring(CaptionGeometry.lineHeight)
    private var textScroll = CaptionSpring(0)
    /// The room made for a card (with the gap above it), its size scaled to
    /// fit, and when the glass had made that room (the card shows from then).
    private var attachmentRoom = CaptionSpring(0)
    private var attachmentSize: CGSize?
    private var attachmentRadius = 20.0
    private var attachmentGap = 0.0
    private var attachmentSettledAt: Double?
    private var attachmentClosingAt: Double?
    private var glassTarget: CGRect?
    private var cardIsland = CGRect.zero
    private var cardWindowWidth: CGFloat = 0

    static let trace = ProcessInfo.processInfo.environment["SIRIGLASS_TRACE"] == "1"

    /// Shows only the glass (debug).
    var glassOnly = false

    // MARK: Timing

    /// How long a summoned drop takes to settle, and to go home.
    nonisolated static let leaveTime = 0.5
    nonisolated static let restAfterLeaving = 0.65
    nonisolated static let thinkTime = 0.35

    // MARK: - One frame

    func frame(at date: Date, requested: SiriGlassState, audio: SiriGlassAudio, writable: Bool,
               take: TakeContext?, layout: Layout, backdrop: Double, card target: CardTarget? = nil) -> Output {
        let clock: Double
        if let take {
            clock = take.take.clock(at: date)
        } else {
            if epoch == nil { epoch = date }
            clock = max(date.timeIntervalSince(epoch!), 0)
        }
        let dt = lastClock.map { min(max(clock - $0, 0), 0.1) } ?? 0
        lastClock = clock

        var request: (from: SiriGlassState, to: SiriGlassState)?
        if let take {
            follow(take, clock: clock)
        } else {
            if case .file(let url, _) = audio.source { FileVoice.prepare(url) }
            // The host's word, unless it is still catching up with a change
            // the drop made itself.
            if let pending = awaiting, requested != pending.from || requested == pending.to { awaiting = nil }
            if awaiting == nil, requested != mode { apply(requested, at: clock, audio: audio) }
            if mode == .listening, audio != listeningTo {
                stopAudio()
                startAudio(audio, at: clock)
            }
            request = advance(clock: clock, dt: dt, autoListen: writable && audio.listensLikeSiri)
        }

        follow(card: target, clock: clock, dt: dt)
        let frame = render(clock: clock, layout: layout, backdrop: backdrop)
        let outline = frame.isVisible ? DropField(frame).outline() : []
        let home = dismissedAt.map { clock - $0 > Self.restAfterLeaving } ?? (summonedAt == nil)
        let resting = take == nil && mode == .idle && home && drive.levels.loudness < 0.001
            && reveal.isEmpty && card == nil
        var out = Output(frame: frame, outline: outline, request: request, resting: resting)
        if card != nil, frame.isVisible {
            // The words show once the glass is most of the way open, and
            // with the drop.
            let open = min(max((cardOpen.value(at: clock) - 0.45) / 0.4, 0), 1)
            let fade = Self.easeInOut(open) * Double(frame.presence)
            let origin = CGPoint(x: Double(cardWindowWidth) / 2 - max(textWidth.value, 0) / 2,
                                 y: CaptionGeometry.textTop(island: cardIsland))
            out.glyphs = reveal.glyphs(at: clock, origin: origin, scroll: textScroll.value, fadeAll: fade)
        }
        out.glassTarget = cardOpen.to > 0 ? glassTarget : nil
        if card != nil, frame.isVisible, outline.count > 2 {
            // How far across the status bar the glass reaches right now, so
            // it can make way step by step, as it does for the island.
            let band = Double(cardIsland.maxY) + 4
            var low = Double.infinity, high = -Double.infinity, bottom = 0.0
            for p in outline where Double(p.y) <= band {
                low = min(low, Double(p.x)); high = max(high, Double(p.x))
            }
            for p in outline { bottom = max(bottom, Double(p.y)) }
            if high > low { out.glassNow = CGRect(x: low, y: 0, width: high - low, height: bottom) }
        }
        if let rect = attachmentRect(), attachmentSettledAt != nil, attachmentClosingAt == nil, cardOpen.to > 0 {
            out.attachmentFrame = rect
            out.attachmentRadius = attachmentRadius
        }
        return out
    }

    /// Where the card sits now: under the words, across the glass.
    private func attachmentRect() -> CGRect? {
        guard let size = attachmentSize else { return nil }
        let x = Double(cardWindowWidth) / 2 - Double(size.width) / 2
        let y = CaptionGeometry.textTop(island: cardIsland) + max(textHeight.value, 0) + attachmentGap
        return CGRect(x: x, y: y, width: Double(size.width), height: Double(size.height))
    }

    /// Opens the glass for a caption and grows it with the words as they
    /// come in; folds it back into the drop when the caption goes.
    private func follow(card target: CardTarget?, clock: Double, dt: Double) {
        let lh = CaptionGeometry.lineHeight
        if let target {
            cardIsland = target.island
            cardWindowWidth = target.windowWidth
            if cardOpen.to < 1 {
                // Opening, or back before it had folded away.
                let reopening = card != nil && cardOpen.value(at: clock) > 0.05
                cardOpen.set(1, at: clock)
                if !reopening {
                    textWidth.snap(0)
                    textHeight.snap(lh)
                    textScroll.snap(0)
                }
                cardOpenedAt = reopening ? clock - 1 : clock
            }
            let maxWidth = CaptionGeometry.maxTextWidth(island: target.island, windowWidth: target.windowWidth)
            // The first words wait for the glass to open round them.
            reveal.update(target.caption, maxWidth: maxWidth, at: clock, notBefore: cardOpenedAt + 0.24)
            // A card: scaled to the glass's inner width, never up.
            if let natural = target.caption.attachment, natural.width > 1, natural.height > 1 {
                let w = CaptionGeometry.attachmentWidth(island: target.island, windowWidth: target.windowWidth)
                var k = min(1, w / Double(natural.width))
                // And never deeper than the glass may go: a tall card (a long
                // list) is scaled down to fit under the words, whole, so all
                // of it can be seen and touched.
                let ext = reveal.extent(at: clock)
                let lines = reveal.isEmpty ? 0 : min(max(ext.lines, 1), CaptionGeometry.maxLines)
                let room = target.maxBottom - CaptionGeometry.textTop(island: target.island)
                    - Double(lines) * lh - (lines > 0 ? CaptionGeometry.attachmentGap : 0) - CaptionGeometry.attachmentMargin
                if room > 80 { k = min(k, room / Double(natural.height)) }
                // In steps, so a growing answer does not set it moving all the time.
                k = (k * 100).rounded(.down) / 100
                let size = CGSize(width: Double(natural.width) * k, height: Double(natural.height) * k)
                if attachmentSize.map({ abs($0.height - size.height) > 0.5 || abs($0.width - size.width) > 0.5 }) ?? true {
                    attachmentSize = size
                    attachmentSettledAt = nil
                }
                attachmentRadius = target.caption.attachmentRadius * k
                attachmentClosingAt = nil
            } else if attachmentSize != nil, attachmentClosingAt == nil {
                attachmentClosingAt = clock
            }
        } else if cardOpen.to > 0 {
            // The words (and the card) go first; the glass folds a beat later.
            reveal.clear(at: clock)
            if attachmentSize != nil, attachmentClosingAt == nil { attachmentClosingAt = clock }
            cardOpen.set(0, at: clock + 0.12)
        }
        guard cardOpen.to > 0 || card != nil else { return }
        if cardOpen.to == 0, clock - cardOpen.at > 1.0, reveal.isEmpty {
            card = nil
            glassTarget = nil
            attachmentSize = nil
            attachmentClosingAt = nil
            attachmentSettledAt = nil
            attachmentRoom.snap(0)
            return
        }
        // A card that went: its hole closes (0.15 s), then its room.
        if let closing = attachmentClosingAt, clock - closing > 0.15, cardOpen.to > 0 {
            attachmentSize = nil
            attachmentClosingAt = nil
            attachmentSettledAt = nil
        }

        // The glass follows the words that are in (or about to be): as wide
        // as its widest line until a line wraps, then the screen's width;
        // as deep as its lines, up to six; past that the text scrolls.
        let maxWidth = CaptionGeometry.maxTextWidth(island: cardIsland, windowWidth: cardWindowWidth)
        let extent = reveal.extent(at: clock)
        let hasWords = !reveal.isEmpty
        if cardOpen.to > 0 {
            let lines = max(extent.lines, 1)
            // A card takes the glass's full width; with no words, no line.
            let wide = attachmentSize != nil
            textWidth.step(to: extent.lines > 1 || wide ? maxWidth : extent.width, dt: dt)
            if Self.trace { print(String(format: "TRACE t=%.2f ext=%.0f/%d tw=%.0f open=%.2f to=%.0f", clock, extent.width, extent.lines, textWidth.value, cardOpen.value(at: clock), cardOpen.to)) }
            textHeight.step(to: wide && !hasWords ? 0 : Double(min(lines, CaptionGeometry.maxLines)) * lh, dt: dt)
            let lastTop = max(lines - CaptionGeometry.maxLines, 0)
            let top = lastTop
            textScroll.step(to: Double(top) * lh, dt: dt, response: 0.5, damping: 0.92)
            attachmentGap = hasWords ? CaptionGeometry.attachmentGap : 0
            let room = attachmentSize.map { attachmentGap + Double($0.height) } ?? 0
            attachmentRoom.step(to: room, dt: dt, response: 0.48, damping: 0.86)
            // Room made (and still): the card can go in.
            if let size = attachmentSize, attachmentSettledAt == nil,
               abs(attachmentRoom.value - (attachmentGap + Double(size.height))) < 1.5, abs(attachmentRoom.velocity) < 20 {
                attachmentSettledAt = clock
            }
        }
        let roomTarget = attachmentSize.map { attachmentGap + Double($0.height) } ?? 0
        // Where the glass is heading (not where it is mid-spring), for the
        // status bar to get out of its way in good time.
        if cardOpen.to > 0 {
            let lines = max(extent.lines, 1)
            let target = CaptionGeometry.glass(
                island: cardIsland, windowWidth: cardWindowWidth,
                textWidth: extent.lines > 1 || attachmentSize != nil ? maxWidth : extent.width,
                textHeight: attachmentSize != nil && !hasWords ? 0 : Double(min(lines, CaptionGeometry.maxLines)) * lh,
                attachment: roomTarget, attachmentShare: roomTarget > 0 ? 1 : 0)
            glassTarget = CGRect(x: Double(target.centre.x) - target.halfWidth, y: Double(target.centre.y) - target.halfHeight,
                                 width: target.halfWidth * 2, height: target.halfHeight * 2)
        } else {
            glassTarget = nil
        }
        let share = roomTarget > 0 ? min(max(attachmentRoom.value / roomTarget, 0), 1)
                                   : min(max(attachmentRoom.value / 60, 0), 1)
        card = CaptionGeometry.glass(island: cardIsland, windowWidth: cardWindowWidth,
                                     textWidth: min(max(textWidth.value, 0), maxWidth + 8),
                                     textHeight: max(textHeight.value, hasWords || attachmentSize == nil ? lh * 0.6 : 0),
                                     attachment: max(attachmentRoom.value, 0), attachmentShare: share)
    }

    /// Leaving the screen: the microphone goes off and the drop goes home
    /// with nothing pending.
    func stop() {
        stopAudio()
        mode = .idle
        summonedAt = nil
        dismissedAt = nil
        think = Ramp()
        awaiting = nil
        drive = VoiceDrive()
    }

    // MARK: - Changes of state

    private func apply(_ target: SiriGlassState, at now: Double, audio: SiriGlassAudio) {
        guard target != mode else { return }
        let old = mode
        mode = target
        switch target {
        case .listening:
            if old == .idle { summon(at: now) }
            think.set(0, at: now)
            listeningSince = now
            speech = SpeechEnd()
            startAudio(audio, at: now)
        case .thinking:
            if old == .idle { summon(at: now) }
            think.set(1, at: now)
            stopAudio()
        case .idle:
            dismissedAt = now
            stopAudio()
            UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6)
        }
    }

    /// Out of the island. Called back while still on its way home, it
    /// carries on from the size it has rather than starting over.
    private func summon(at now: Double) {
        var since = 0.0
        if let dismissedAt, let summonedAt, now - dismissedAt < Self.leaveTime {
            let current = Self.fill(now - summonedAt) * Self.leave(now - dismissedAt)
            while since < 0.6 && Self.fill(since) < current { since += 0.005 }
        }
        summonedAt = now - since
        dismissedAt = nil
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.9)
    }

    /// Listens for a frame; returns the change it made by itself, if any.
    private func advance(clock: Double, dt: Double, autoListen: Bool) -> (from: SiriGlassState, to: SiriGlassState)? {
        var raw = SiriGlassLevels()
        var request: (from: SiriGlassState, to: SiriGlassState)?
        if mode == .listening {
            raw = levels(at: clock)
            if autoListen, let verdict = speech.hear(raw.loudness, dt: dt, listening: clock - listeningSince) {
                let target: SiriGlassState = verdict == .finished ? .thinking : .idle
                apply(target, at: clock, audio: listeningTo ?? .microphone)
                awaiting = (.listening, target)
                request = awaiting
                raw = SiriGlassLevels()
            }
        }
        drive.advance(toward: raw, dt: dt)
        swirl += think.value(at: clock) * dt
        return request
    }

    /// A scripted take: every change at its cue, the voice from its file.
    private func follow(_ take: TakeContext, clock: Double) {
        let cues = take.cues
        summonedAt = cues.listen ?? cues.think
        dismissedAt = cues.idle
        think = Ramp(from: 0, to: 1, at: cues.think ?? .infinity)
        mode = cues.state(at: clock)
        drive = take.take.voice?.drive(at: clock) ?? VoiceDrive.resting(at: clock)
        swirl = cues.think.map { max(clock - $0 - Self.thinkTime / 2, 0) } ?? 0
        glassOnly = take.take.showsOnlyGlass
    }

    // MARK: - Audio

    private func startAudio(_ audio: SiriGlassAudio, at now: Double) {
        listeningTo = audio
        switch audio.source {
        case .microphone:
            let mic = self.mic ?? MicListener()
            self.mic = mic
            Task { @MainActor [weak self] in
                let ok = await mic.start()
                // Sent away, or the screen left, while permission was asked.
                if ok, self?.mode != .listening || self?.listeningTo?.source != .microphone { mic.stop() }
            }
        case .file(let url, let muted):
            let voice = FileVoice(url: url, muted: muted)
            trackStart = now + 0.1
            voice.play(after: 0.1)
            file = voice
        case .feed:
            audio.feed?.stream.reset()
        }
    }

    private func stopAudio() {
        mic?.stop()
        file?.stop()
        file = nil
        listeningTo = nil
    }

    private func levels(at clock: Double) -> SiriGlassLevels {
        guard let listeningTo else { return SiriGlassLevels() }
        switch listeningTo.source {
        case .microphone: return mic?.levels() ?? SiriGlassLevels()
        case .file: return file?.levels(at: clock - trackStart) ?? SiriGlassLevels()
        case .feed: return listeningTo.feed?.stream.levels() ?? SiriGlassLevels()
        }
    }

    // MARK: - Shape and light from the clock

    private func render(clock: Double, layout: Layout, backdrop: Double) -> DropFrame {
        var f = DropFrame()
        f.clock = clock
        f.time = Float(clock.truncatingRemainder(dividingBy: 1000))
        if case .island(let island) = layout { f.island = island }

        guard let summonedAt, clock >= summonedAt else { return f }
        let since = clock - summonedAt
        let level = Double(drive.levels.loudness)

        // Out of the island like a drop: a small bead forms at the island's
        // foot and drips down while it swells, joined to the island by a
        // liquid neck, then hangs there. Both springs overshoot a little, so
        // it lands with some weight and settles. It lengthens first and
        // fills out a beat later, so mid-drip it is a round-bottomed
        // teardrop rather than a box.
        let drip = Self.spring(since, delay: 0.0, frequency: 2.3, damping: 0.78)
        let lengthen = Self.spring(since, delay: 0.03, frequency: 2.0, damping: 0.62)
        let fill = Self.fill(since)

        // Back in: a small swell, then a quick pull home.
        let leave = dismissedAt.map { clock >= $0 ? Self.leave(clock - $0) : 1 } ?? 1
        // Thinking draws it in a little, as if it were concentrating.
        let thinking = think.value(at: clock)
        let concentrate = 1 - 0.07 * thinking

        // Listening, it breathes and swells with the voice. Under the island
        // it hangs from its top, so it grows downward and outward and the
        // island never shows through; the orb swells about its middle.
        let breath = 1 + 0.006 * sin(clock * 2 * .pi * 0.38)
        // A wider island (a live activity) gets a wider drop, lifted higher,
        // so the drop's own arc covers the island's top corners. The plain
        // island keeps the original lift and margin.
        var baseHalfW = DropGeometry.halfWidth
        var lift = DropGeometry.lift
        if case .island(let rect) = layout {
            let wide = DropGeometry.wideIsland(width: rect.width)
            lift = wide.lift
            baseHalfW = max(baseHalfW, rect.width / 2 + wide.margin)
        }
        let settledHalfW = baseHalfW * (1 + 0.034 * level) * breath * concentrate
        let settledHalfH = (DropGeometry.bottom - DropGeometry.top) / 2 * (1 + 0.028 * level) * breath * concentrate
        // The drop keeps its height; a wider island moves the whole drop up.
        let top = DropGeometry.top - (lift - DropGeometry.lift)
        let seedHalfW = 16.0, seedHalfH = 13.0

        let kDrip = drip * leave, kLength = lengthen * leave, kFill = fill * leave
        var halfW = Self.mix(seedHalfW, settledHalfW, kFill)
        var halfH = Self.mix(seedHalfH, settledHalfH, kLength)
        let grown = min(max(kFill, 0), 1)
        let presence = min(max((drip * leave + lengthen * leave) * 2.5, 0), 1)

        var centre: CGPoint, scale = 1.0, island: CGRect, neck: Double
        switch layout {
        case .island(let rect):
            // Out of the island, hanging from it. The bead it grows from is
            // tucked into the island's foot.
            let foot = CGPoint(x: rect.midX, y: rect.midY + 3)
            centre = CGPoint(x: foot.x, y: Self.mix(foot.y, top + settledHalfH, kDrip))
            island = rect
            // A wide, gooey neck until the bead has swallowed the island;
            // nearly none once it hangs free.
            neck = 1 + 17 * (1 - Self.easeInOut(min(max((grown - 0.78) / 0.22, 0), 1)))
        case .orb(let at, let size):
            // On its own: it blooms from a point.
            centre = at
            scale = size
            island = CGRect(x: at.x - 1, y: at.y - 1, width: 2, height: 2)
            neck = 1
        }

        // A caption: the drop grows into a rounded rect across the top of the
        // screen, as deep as the words need, springing there (a little past,
        // then back). It goes home with the drop.
        var cardBlend = 0.0
        var waterline = 0.07 * halfH
        if case .island = layout, let card {
            let e = cardOpen.value(at: clock) * leave
            if e > 0.0005 {
                let c = min(max(e, 0), 1)
                centre = CGPoint(x: Self.mix(centre.x, card.centre.x, c), y: Self.mix(centre.y, card.centre.y, e))
                halfW = Self.mix(halfW, card.halfWidth * breath, e)
                halfH = Self.mix(halfH, card.halfHeight * breath, e)
                waterline = Self.mix(0.07 * halfH, card.waterline * breath, c)
                cardBlend = c
            }
        }

        // The shader works in the drop's design space around its centre, so
        // the island goes over in those terms too.
        f.island = CGRect(x: centre.x + (island.minX - centre.x) / scale, y: centre.y + (island.minY - centre.y) / scale,
                          width: island.width / scale, height: island.height / scale)
        f.drop = SIMD4(Float(centre.x), Float(centre.y), Float(max(halfW, 1)), Float(max(halfH, 1)))
        f.exponent = Float(Self.mix(2.0, 2.4, grown))
        f.cornerRadius = Float(card?.cornerRadius ?? 0)
        f.inkFade = Float(card?.inkFade ?? 22)
        // The card shows through the glass a beat after there was room for
        // it (Siri has put it in place by then), and goes first.
        if let rect = attachmentRect(), let settled = attachmentSettledAt, cardBlend > 0.5 {
            // A beat for Siri to put its card in place first.
            var open = min(max((clock - settled - 0.2) / 0.25, 0), 1)
            if let closing = attachmentClosingAt { open *= 1 - min(max((clock - closing) / 0.15, 0), 1) }
            f.hole = rect
            f.holeRadius = Float(attachmentRadius)
            f.holeOpen = Float(open * open * (3 - 2 * open))
        }
        f.neck = Float(neck)
        f.presence = Float(presence)
        f.extra = SIMD4(Float(grown), glassOnly ? 1 : 0, Float(scale), Float(backdrop))

        // The line lights from the middle once the drop is out, and goes
        // dark first on the way back in.
        var ignite = Self.easeInOut(min(max((since - 0.16) / 0.42, 0), 1))
        if let dismissedAt, clock >= dismissedAt {
            ignite *= 1 - Self.easeInOut(min(max((clock - dismissedAt) / 0.22, 0), 1))
        }

        // Strand heights: a small idle swell plus each band's share of the
        // voice. Thinking, they settle into one steady lens of light that
        // swirls slowly round itself.
        let lv = drive.levels
        let a1 = Self.mix(2.8 + 11.0 * Double(lv.low), 7.5, thinking)
        let a2 = Self.mix(1.7 + 7.0 * Double(lv.mid), 3.0, thinking)
        let a3 = Self.mix(1.1 + 5.0 * Double(lv.high), 1.8, thinking)
        // The voice's light gives way to the words.
        ignite *= 1 - cardBlend
        f.amps = SIMD4(Float(a1 * ignite), Float(a2 * ignite), Float(a3 * ignite), Float(level * (1 - thinking)))
        let p = drive.phases + VoiceDrive.restSpeed * 1.6 * swirl
        func wrap(_ x: Double) -> Float { Float(x.truncatingRemainder(dividingBy: 2 * .pi)) }
        f.phases = SIMD4(wrap(p.x), wrap(p.y), wrap(p.z), wrap(p.w))
        f.light = SIMD4(Float(ignite), Float(thinking), Float(waterline), Float(cardBlend))
        return f
    }

    // MARK: - Curves

    /// How full the bead is `t` seconds after it was summoned.
    nonisolated static func fill(_ t: Double) -> Double { spring(t, delay: 0.09, frequency: 1.7, damping: 0.6) }

    /// 1 while out, through a small swell, to 0 home, `t` seconds after it
    /// was sent away.
    nonisolated static func leave(_ t: Double) -> Double {
        let u = t / leaveTime
        guard u < 1 else { return 0 }
        let puff = 0.035 * sin(min(u / 0.28, 1) * .pi)
        return (1 + puff) * (1 - easeInOut(min(max((u - 0.12) / 0.88, 0), 1)))
    }

    /// A damped spring from 0 to 1, started `delay` seconds in.
    nonisolated static func spring(_ t: Double, delay: Double, frequency: Double, damping: Double) -> Double {
        let t = t - delay
        guard t > 0 else { return 0 }
        let w0 = 2 * .pi * frequency
        let wd = w0 * (1 - damping * damping).squareRoot()
        let decay = exp(-damping * w0 * t)
        return 1 - decay * (cos(wd * t) + damping * w0 / wd * sin(wd * t))
    }

    nonisolated static func easeInOut(_ t: Double) -> Double { t * t * (3 - 2 * t) }

    nonisolated static func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
}

/// A value easing from one level to another over `thinkTime`.
struct Ramp: Equatable {
    var from = 0.0
    var to = 0.0
    var at = 0.0

    func value(at t: Double) -> Double {
        let u = min(max((t - at) / DropEngine.thinkTime, 0), 1)
        return DropEngine.mix(from, to, DropEngine.easeInOut(u))
    }

    mutating func set(_ target: Double, at t: Double) {
        guard target != to else { return }
        from = value(at: t)
        to = target
        at = t
    }
}

/// A spring from one level to another; changed mid-way, it carries on
/// from where it is.
struct Spring01: Equatable {
    var from = 0.0
    var to = 0.0
    var at = 0.0

    func value(at t: Double) -> Double {
        DropEngine.mix(from, to, DropEngine.spring(t - at, delay: 0, frequency: 1.45, damping: 0.74))
    }

    mutating func set(_ target: Double, at t: Double) {
        guard target != to else { return }
        from = value(at: t)
        to = target
        at = t
    }
}
