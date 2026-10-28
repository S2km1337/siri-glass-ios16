//
//  IslandCaption.swift
//  SiriGlass
//
//  iOS 27 shows what you said and Siri's short answer in the Dynamic
//  Island itself, not at the bottom of the screen: the drop of Liquid
//  Glass that hangs from the island grows into a rounded rect across the
//  top of the screen, drawn the same way as the drop (the island's black at
//  its top, thinning behind the words into smoked glass, a clear lens along
//  its rim).
//
//  It grows with the words. The first word opens the drop into a short
//  capsule a little wider than the island; each word after it widens the
//  capsule on both sides, until it reaches the screen's width and the
//  words wrap, and it deepens a line at a time. Every word comes in on its
//  own, as iOS's Siri text does: out of a blur, rising a little, one after
//  the other; words Siri takes back dissolve upward. Past six lines the
//  text scrolls, its top line fading out under the island.
//

import SwiftUI
import UIKit

/// What the island says.
public struct SiriGlassCaption: Equatable, Sendable {
    public enum Role: String, Sendable { case user, siri }

    public var text: String
    public var role: Role
    /// A card that goes in the glass under the words (Siri's own result:
    /// weather, a calendar…), at its natural size, and its corner radius.
    /// The glass makes room for it and leaves it showing through; where it
    /// goes is in `SiriGlassAttachment.frame`.
    public var attachment: CGSize?
    public var attachmentRadius: Double

    public init(_ text: String, role: Role, attachment: CGSize? = nil, attachmentRadius: Double = 20) {
        self.text = text
        self.role = role
        self.attachment = attachment
        self.attachmentRadius = attachmentRadius
    }

    /// Nothing to show.
    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachment == nil
    }
}

/// Where a caption's glass is going (window coordinates), so a host can
/// move the status bar out of its way as the Dynamic Island does when it
/// expands; nil when there is no caption glass, or it is folding away.
public enum SiriGlassCaptionGlass {
    @MainActor public internal(set) static var frame: CGRect?
    /// Where the glass is this frame, across the status bar's band (its
    /// widest there), down to its bottom; nil when there is none.
    @MainActor public internal(set) static var current: CGRect?
}

/// Where the glass wants a caption's card, once it has made room for it.
public enum SiriGlassAttachment {
    /// The card's frame in window coordinates and its corner radius (the
    /// card scaled to fit), or nil while there is no room for one yet.
    @MainActor public internal(set) static var frame: CGRect?
    @MainActor public internal(set) static var cornerRadius: Double = 0
}

extension View {
    /// Grows the `.siriGlass` drop into a card of Liquid Glass across the
    /// top of the screen holding `caption`, as iOS 27's Siri does; `nil`
    /// folds it back into the drop. The drop has to be out (not idle) for
    /// the card to show.
    public func siriGlassCaption(_ caption: SiriGlassCaption?) -> some View {
        environment(\.siriGlassCaption, caption)
    }
}

private struct SiriGlassCaptionKey: EnvironmentKey {
    static let defaultValue: SiriGlassCaption? = nil
}

extension EnvironmentValues {
    var siriGlassCaption: SiriGlassCaption? {
        get { self[SiriGlassCaptionKey.self] }
        set { self[SiriGlassCaptionKey.self] = newValue }
    }
}

// MARK: - Measurements

/// Measured off Apple's iOS 27 Siri still (1.27 px/pt): the glass is inset
/// about as far as the island's top on every side; the words start at the
/// island's foot, as far below the glass's top edge as the glass's bottom
/// edge is below the last line; 20 pt type on 25 pt lines, 38 pt in from
/// the glass's sides.
enum CaptionGeometry {
    static let fontSize = 20.0
    static let font = UIFont.systemFont(ofSize: fontSize, weight: .regular)
    static let lineHeight = 25.0
    static let maxLines = 6
    /// Text starts this far under the island's bottom edge.
    static let gapUnderIsland = 1.0
    static let sidePadding = 38.0
    /// The narrowest the glass gets: this much wider than the island on
    /// each side, so even one short word reads as the island grown.
    static let minimumMargin = 30.0
    /// The waterline, this far above the glass's bottom edge: under it is
    /// the rim's lens.
    static let lensDepth = 18.0
    /// A card in the glass: this far in from the glass's sides and bottom
    /// edge, and this far under the words.
    static let attachmentMargin = 12.0
    static let attachmentGap = 14.0

    /// How wide a card in the glass is, in a window `width` wide.
    static func attachmentWidth(island: CGRect, windowWidth width: CGFloat) -> Double {
        (Double(width) / 2 - inset(island: island) - attachmentMargin) * 2
    }

    /// The display's own corner radius (55 on an iPhone 14 Pro).
    @MainActor static var displayRadius: Double {
        let key = ["_display", "CornerRadius"].joined()
        if UIScreen.main.responds(to: NSSelectorFromString(key)),
           let r = UIScreen.main.value(forKey: key) as? Double, r > 0 { return r }
        return 55
    }

    /// The glass's inset from the screen's edges: the island's from the top.
    static func inset(island: CGRect) -> Double {
        min(max(Double(island.minY), 8), 14)
    }

    /// The widest the words run in a window `width` wide.
    static func maxTextWidth(island: CGRect, windowWidth width: CGFloat) -> Double {
        max(Double(width) - inset(island: island) * 2 - sidePadding * 2, 80)
    }

    /// The narrowest the glass's half width gets.
    static func minimumHalfWidth(island: CGRect, windowWidth width: CGFloat) -> Double {
        min(Double(island.width) / 2 + minimumMargin, Double(width) / 2 - inset(island: island))
    }

    /// Where the words start.
    static func textTop(island: CGRect) -> Double { Double(island.maxY) + gapUnderIsland }

    /// The deepest a caption's glass can reach under `island`.
    static func maxBottom(island: CGRect, windowHeight: Double = 0) -> Double {
        let top = textTop(island: island)
        // Room for a card as tall as most of the screen.
        return max(top + Double(maxLines) * lineHeight + (top - inset(island: island)), windowHeight * 0.86)
    }

    /// The glass round a block of text `textWidth` x `textHeight`.
    @MainActor static func glass(island: CGRect, windowWidth width: CGFloat,
                                 textWidth: Double, textHeight: Double,
                                 attachment: Double = 0, attachmentShare: Double = 0) -> CaptionGlass {
        let inset = inset(island: island)
        let top = textTop(island: island)
        let halfW = min(max(textWidth / 2 + sidePadding, minimumHalfWidth(island: island, windowWidth: width)),
                        Double(width) / 2 - inset)
        // As much glass under the words as over them; with a card, the card
        // sits close to the bottom edge instead.
        let share = min(max(attachmentShare, 0), 1)
        let bottom = top + textHeight + attachment + ((top - inset) * (1 - share) + attachmentMargin * share)
        let halfH = (bottom - inset) / 2
        let cy = inset + halfH
        let waterline = bottom - lensDepth
        // The black holds through the first line, then thins all the way
        // down to the waterline.
        let fadeFrom = top + lineHeight * 0.6
        return CaptionGlass(centre: CGPoint(x: Double(width) / 2, y: cy), halfWidth: halfW, halfHeight: halfH,
                            cornerRadius: max(displayRadius - inset, 12),
                            waterline: waterline - cy, inkFade: max(waterline - fadeFrom, 22))
    }
}

/// The glass a caption grows the drop into: a rounded rect, its corners
/// parallel to the screen's.
struct CaptionGlass: Equatable {
    var centre: CGPoint
    var halfWidth: Double
    var halfHeight: Double
    var cornerRadius: Double
    /// The waterline, below the centre (pt).
    var waterline: Double
    /// How far above the waterline the ink starts to fade (pt).
    var inkFade: Double
}

// MARK: - Typesetting

/// One piece of text that comes in on its own: a word, or in Chinese,
/// Japanese and Korean a character (with any punctuation that must not
/// start or end a line kept on it).
struct CaptionToken: Equatable {
    var text: String
    var spaceAfter: Bool
}

enum CaptionTypesetter {
    /// Splits text into tokens. Latin words run up to a space; each CJK
    /// character stands alone; closing punctuation sticks to what is before
    /// it and opening punctuation to what is after, so neither is left alone
    /// at a line's edge.
    static func tokens(_ text: String) -> [CaptionToken] {
        var out: [CaptionToken] = []
        var word = ""
        var opening = ""
        func flush(space: Bool) {
            if !word.isEmpty {
                out.append(CaptionToken(text: opening + word, spaceAfter: space))
                word = ""; opening = ""
            } else if space, !out.isEmpty {
                out[out.count - 1].spaceAfter = true
            }
        }
        for ch in text {
            if ch.isWhitespace || ch.isNewline {
                flush(space: true)
            } else if closing.contains(ch) {
                if !word.isEmpty { word.append(ch) }
                else if !out.isEmpty, !out[out.count - 1].spaceAfter { out[out.count - 1].text.append(ch) }
                else { word.append(ch) }
            } else if openingSet.contains(ch) {
                flush(space: false)
                opening.append(ch)
            } else if isCJK(ch) {
                flush(space: false)
                out.append(CaptionToken(text: opening + String(ch), spaceAfter: false))
                opening = ""
            } else {
                word.append(ch)
            }
        }
        flush(space: false)
        if !opening.isEmpty { out.append(CaptionToken(text: opening, spaceAfter: false)) }
        return out
    }

    private static let closing: Set<Character> = Set("，。！？、；：”’）》」』】〉…—,.!?;:)]}%")
    private static let openingSet: Set<Character> = Set("“‘（《「『【〈([{")

    private static func isCJK(_ ch: Character) -> Bool {
        guard let v = ch.unicodeScalars.first?.value else { return false }
        return (0x2E80...0x9FFF).contains(v) || (0xAC00...0xD7AF).contains(v) || (0xF900...0xFAFF).contains(v)
            || (0xFF00...0xFFEF).contains(v) || (0x20000...0x2FA1F).contains(v)
    }

    @MainActor private static var widths: [String: Double] = [:]

    /// A token's width in the caption's font.
    @MainActor static func width(_ text: String) -> Double {
        if let w = widths[text] { return w }
        if widths.count > 4000 { widths.removeAll() }
        let w = ceil((text as NSString).size(withAttributes: [.font: CaptionGeometry.font]).width * 2) / 2
        widths[text] = w
        return w
    }

    @MainActor static var spaceWidth: Double { width(" ") }

    /// Where a token goes: its left edge and its line.
    struct Placed: Equatable {
        var x: Double
        var line: Int
        var width: Double
    }

    /// Greedy line breaking: as many tokens on a line as fit in `maxWidth`.
    /// It only ever looks back, so the first n tokens land in the same places
    /// whatever follows them, and a caption can grow word by word without
    /// anything before moving.
    @MainActor static func layout(_ tokens: [CaptionToken], maxWidth: Double) -> [Placed] {
        var placed: [Placed] = []
        placed.reserveCapacity(tokens.count)
        var x = 0.0, line = 0
        let space = spaceWidth
        for (i, t) in tokens.enumerated() {
            let w = width(t.text)
            let gap = i > 0 && tokens[i - 1].spaceAfter ? space : 0
            if x > 0, x + gap + w > maxWidth + 0.5 {
                line += 1
                x = 0
                placed.append(Placed(x: 0, line: line, width: w))
                x = w
            } else {
                placed.append(Placed(x: x + gap, line: line, width: w))
                x += gap + w
            }
        }
        return placed
    }
}

// MARK: - Words coming and going

/// One word as drawn this frame.
struct CaptionGlyph: Identifiable, Equatable {
    var id: Int
    var text: String
    /// Top-left of its line box, in the layer's space.
    var x: Double
    var y: Double
    var opacity: Double
    var blur: Double
}

/// The words in the card, each with when it came in (or started to go),
/// and the size of the text they make so far.
@MainActor
final class CaptionReveal {
    struct Word {
        let id: Int
        var token: CaptionToken
        var appear: Double
    }

    struct Leaving {
        let id: Int
        var text: String
        var x: Double
        var line: Int
        var leave: Double
        var duration: Double
    }

    /// How long a word takes to come in, and to go.
    static let inTime = 0.5
    static let outTime = 0.26

    private(set) var words: [Word] = []
    private(set) var leaving: [Leaving] = []
    private(set) var role: SiriGlassCaption.Role?
    private var text: String?
    private var placed: [CaptionTypesetter.Placed] = []
    private var placedFor = 0.0
    private var nextID = 0
    /// The text's size when it last changed: while new words come in, the
    /// glass does not shrink below it (unless the new text is smaller
    /// still), so replacing text never makes the glass dip and grow again.
    private var held = (width: 0.0, lines: 0)

    var isEmpty: Bool { words.isEmpty && leaving.isEmpty }

    /// Takes the caption's newest text. Words already there stay put; Siri's
    /// corrections dissolve; new words come in one after another, none
    /// before `notBefore` (the glass has to open first).
    func update(_ caption: SiriGlassCaption, maxWidth: Double, at now: Double, notBefore: Double) {
        relayout(maxWidth)
        guard caption.text != text || caption.role != role else { return }
        held = revealed(at: now)
        let next = CaptionTypesetter.tokens(caption.text)
        var keep = 0
        if caption.role == role {
            while keep < min(words.count, next.count), words[keep].token == next[keep] { keep += 1 }
            // A word still being spoken ("hel" → "hello"): the same word, grown.
            if keep < words.count, keep < next.count, keep == words.count - 1,
               next[keep].text.hasPrefix(words[keep].token.text) {
                words[keep].token = next[keep]
                keep += 1
            }
        }
        let gone = words.count - keep
        for i in keep..<words.count where i < placed.count {
            leaving.append(Leaving(id: words[i].id, text: words[i].token.text, x: placed[i].x,
                                   line: placed[i].line, leave: now, duration: Self.outTime))
        }
        words.removeSubrange(keep...)
        // New words follow one another: quicker when there are many, so a
        // long answer still arrives promptly; after a beat when some went.
        let fresh = next.count - keep
        let stagger = min(0.05, 0.9 / Double(max(fresh, 1)))
        var start = max(now + (gone > 0 ? 0.14 : 0), notBefore)
        if let last = words.last { start = max(start, last.appear) }
        for (j, token) in next[keep...].enumerated() {
            words.append(Word(id: nextID, token: token, appear: start + Double(j) * stagger))
            nextID += 1
        }
        text = caption.text
        role = caption.role
        placed = CaptionTypesetter.layout(words.map(\.token), maxWidth: maxWidth)
        placedFor = maxWidth
    }

    /// Every word goes, at once and quickly: the glass folds right after.
    func clear(at now: Double) {
        for (i, w) in words.enumerated() where i < placed.count && w.appear < now {
            leaving.append(Leaving(id: w.id, text: w.token.text, x: placed[i].x, line: placed[i].line,
                                   leave: now, duration: 0.2))
        }
        words.removeAll()
        placed.removeAll()
        text = nil
        role = nil
    }

    private func relayout(_ maxWidth: Double) {
        guard maxWidth != placedFor else { return }
        placedFor = maxWidth
        placed = CaptionTypesetter.layout(words.map(\.token), maxWidth: maxWidth)
    }

    /// The words in by `now`: their widest line (the full width once they
    /// wrap) and how many lines.
    private func revealed(at now: Double, all: Bool = false) -> (width: Double, lines: Int) {
        var width = 0.0, lines = 0
        for (i, w) in words.enumerated() where i < placed.count && (all || w.appear <= now) {
            width = max(width, placed[i].x + placed[i].width)
            lines = max(lines, placed[i].line + 1)
        }
        return (lines > 1 ? placedFor : width, lines)
    }

    /// The text the glass should hold: the words in `lead` seconds from now
    /// (so it opens just ahead of each word), and while some are still to
    /// come, no less than it held before they started (or the whole new
    /// text, if that is smaller).
    func extent(at now: Double, lead: Double = 0.06) -> (width: Double, lines: Int) {
        let shown = revealed(at: now + lead)
        guard let last = words.last, last.appear > now + lead else { return shown }
        let final = revealed(at: now, all: true)
        return (max(shown.width, min(held.width, final.width)), max(shown.lines, min(held.lines, final.lines)))
    }

    /// The words as drawn now, their text block's top-left at `origin`,
    /// scrolled up by `scroll`.
    func glyphs(at now: Double, origin: CGPoint, scroll: Double, fadeAll: Double) -> [CaptionGlyph] {
        leaving.removeAll { now - $0.leave > $0.duration }
        let lh = CaptionGeometry.lineHeight
        var out: [CaptionGlyph] = []
        out.reserveCapacity(words.count + leaving.count)
        func scrolled(_ line: Int) -> (y: Double, alpha: Double) {
            let top = Double(line) * lh - scroll
            // Lines scrolling up out of the glass fade under the island; lines
            // still below the six in view (an answer being read from its
            // start) wait out of sight.
            let above = min(max((top + lh * 0.75) / (lh * 0.75), 0), 1)
            let below = min(max(1 - (top + lh - Double(CaptionGeometry.maxLines) * lh) / (lh * 0.75), 0), 1)
            let alpha = above * below
            return (Double(origin.y) + top, alpha)
        }
        for l in leaving {
            let u = min(max((now - l.leave) / l.duration, 0), 1)
            let e = u * u
            let (y, a) = scrolled(l.line)
            out.append(CaptionGlyph(id: l.id, text: l.text, x: Double(origin.x) + l.x, y: y - 5 * e,
                                    opacity: (1 - e) * a * fadeAll, blur: 7 * e))
        }
        for (i, w) in words.enumerated() where i < placed.count {
            let u = (now - w.appear) / Self.inTime
            guard u > 0 else { continue }
            // Out of a blur, rising into place: quick at first, then
            // settling, like iOS's own streaming text.
            let t = min(u, 1)
            let ease = 1 - pow(1 - t, 3)
            let (y, a) = scrolled(placed[i].line)
            guard a > 0.001 else { continue }
            out.append(CaptionGlyph(id: w.id, text: w.token.text, x: Double(origin.x) + placed[i].x,
                                    y: y + 6 * (1 - ease), opacity: min(t * 1.6, 1) * a * fadeAll,
                                    blur: 8 * (1 - ease)))
        }
        return out
    }
}

/// A spring for one number, stepped with each frame: it follows its target
/// with a little overshoot, carrying its speed through changes of target, so
/// the glass never jumps.
struct CaptionSpring {
    var value: Double
    var velocity = 0.0

    init(_ value: Double) { self.value = value }

    mutating func step(to target: Double, dt: Double, response: Double = 0.42, damping: Double = 0.8) {
        guard dt > 0 else { return }
        let k = pow(2 * .pi / response, 2)
        let c = 4 * .pi * damping / response
        // Small substeps keep it stable through a slow frame.
        let n = max(1, Int((dt / (1.0 / 240)).rounded(.up)))
        let h = dt / Double(n)
        for _ in 0..<n {
            velocity += (-k * (value - target) - c * velocity) * h
            value += velocity * h
        }
    }

    mutating func snap(_ target: Double) {
        value = target
        velocity = 0
    }
}

/// The words in the glass, each drawn on its own so it can come in and go
/// by itself.
/// A blur only when there is one to draw.
private struct CaptionBlur: ViewModifier {
    let radius: Double
    func body(content: Content) -> some View {
        if radius > 0.05 { content.blur(radius: radius) } else { content }
    }
}

struct CaptionWordsView: View {
    let glyphs: [CaptionGlyph]

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Only the words that can be seen; a blur only on the ones still
            // coming in or going (a long answer is hundreds of words, and a
            // blur each, every frame, made the glass stutter).
            ForEach(glyphs.filter { $0.opacity > 0.005 }) { g in
                Text(g.text)
                    .font(Font(CaptionGeometry.font))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(height: CaptionGeometry.lineHeight)
                    .modifier(CaptionBlur(radius: g.blur))
                    .opacity(g.opacity)
                    .offset(x: g.x, y: g.y)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
