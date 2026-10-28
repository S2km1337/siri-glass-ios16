//
//  SGHost.swift
//  SiriGlassHost
//
//  The bridge a SpringBoard tweak calls (from Objective-C) to show the drop
//  in the Siri window. The tweak watches Siri's own orb (SUICOrbView) and
//  forwards its mode and audio power here; the drop is SiriGlass.
//

@_spi(Recording) import SiriGlass
import SwiftUI
import UIKit

@MainActor
final class SGModel: ObservableObject {
    @Published var state: SiriGlassState = .idle {
        didSet { if state != .idle { activeUntil = .infinity } else { activeUntil = CACurrentMediaTime() + 1.5 } }
    }
    /// Bumped every frame while the drop is out, to keep SwiftUI redrawing it
    /// even when its own timeline has not started (in SpringBoard, the first
    /// seconds of a Siri session showed nothing until the state next changed).
    @Published var beat = 0
    /// What the island card says (iOS 27: Siri's text lives in the island).
    @Published var caption: SiriGlassCaption? {
        didSet {
            if caption != nil { activeUntil = .infinity }
            else {
                if oldValue != nil { captionGoneAt = CACurrentMediaTime() }
                if state == .idle { activeUntil = CACurrentMediaTime() + 2 }
            }
        }
    }
    /// When the caption last went: the drop waits for its glass to fold
    /// before it goes home, so the two never happen at once.
    var captionGoneAt = -Double.infinity

    /// Siri's result card (weather, a calendar…) at its natural size, and
    /// its corner radius: the glass makes room for it under the words.
    @Published var attachment: CGSize? {
        didSet {
            if attachment != nil { activeUntil = .infinity }
            else if oldValue != nil, caption == nil { captionGoneAt = CACurrentMediaTime() }
        }
    }
    var attachmentRadius = 20.0
    /// The words and the card together, as the glass shows them.
    var shown: SiriGlassCaption? {
        guard caption != nil || attachment != nil else { return nil }
        return SiriGlassCaption(caption?.text ?? "", role: caption?.role ?? .siri,
                                attachment: attachment, attachmentRadius: attachmentRadius)
    }

    /// What the drop is asked to do: out while there are words (Siri done
    /// talking, its answer still up), and a moment longer while they fold.
    var dropState: SiriGlassState {
        guard state == .idle else { return state }
        if shown != nil || CACurrentMediaTime() - captionGoneAt < 0.5 { return .listening }
        return .idle
    }
    var activeUntil = 0.0
    let feed = SiriGlassAudio.Feed()
}

private struct SGRoot: View {
    @ObservedObject var model: SGModel

    var body: some View {
        let _ = model.beat
        Color.clear
            .ignoresSafeArea()
            // Siri done talking, its answer still up: the drop stays out to
            // hold the words until they go.
            .siriGlass(Binding(get: { model.dropState }, set: { model.state = $0 }),
                       audio: .feed(model.feed))
            .siriGlassCaption(model.shown)
    }
}

/// Siri keeps adding views (its remote scene, the response cards) after the
/// drop's overlay went in, which covered it. Keeps the overlay on top.
@MainActor
final class SGRaiser: NSObject {
    weak var view: UIView?
    var model: SGModel?
    private var link: CADisplayLink?

    func start() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(frame))
        l.preferredFramesPerSecond = 30
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc func frame() {
        guard let model, CACurrentMediaTime() < model.activeUntil else { return }
        model.beat &+= 1
    }

    @objc func tick() {
        guard let view, let parent = view.superview, parent.subviews.last !== view else { return }
        parent.bringSubviewToFront(view)
    }
}

@MainActor
@objc(SGHost) public final class SGHost: NSObject {
    private static let raiser = SGRaiser()
    private static var raiseTimer: Timer?
    private static let model = SGModel()
    private static var host: UIHostingController<SGRoot>?
    private static var level: Float = 0

    /// Puts the drop's overlay on top of `window`. It is added straight to the
    /// window, with no parent view controller: SBAssistantWindow's root view
    /// controller only gets its view into the window a few seconds into a Siri
    /// session, and a hosting view outside a window does not render at all,
    /// which kept the drop from appearing until "thinking". (Making it a
    /// child of that controller while placing the view elsewhere made UIKit
    /// raise.) Safe to call repeatedly.
    @discardableResult
    @objc(attachToWindow:) public static func attach(to window: UIWindow) -> Bool {
        if let host, host.view.superview === window {
            window.bringSubviewToFront(host.view)
            return true
        }
        tearDown()   // not detach(): that would reset the state the tweak already set
        let controller = UIHostingController(rootView: SGRoot(model: model))
        controller.view.backgroundColor = .clear
        controller.view.isOpaque = false
        controller.view.isUserInteractionEnabled = false
        controller.view.frame = window.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(controller.view)
        host = controller
        raiser.view = controller.view
        raiser.model = model
        raiser.start()
        raiseTimer?.invalidate()
        raiseTimer = Timer.scheduledTimer(timeInterval: 0.1, target: raiser, selector: #selector(SGRaiser.tick), userInfo: nil, repeats: true)
        return true
    }

    @objc(detach) public static func detach() {
        model.state = .idle
        model.caption = nil
        model.attachment = nil
        tearDown()
    }

    private static func tearDown() {
        raiseTimer?.invalidate()
        raiseTimer = nil
        raiser.stop()
        guard let host else { return }
        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        host.removeFromParent()
        self.host = nil
    }

    /// 0 idle, 1 listening, 2 thinking.
    @objc(setState:) public static func setState(_ raw: Int) {
        let next: SiriGlassState = raw == 1 ? .listening : raw == 2 ? .thinking : .idle
        if model.state != next { model.state = next }
    }

    /// The orb's audio power. Accepts 0…1, or dB (negative, about -50…0).
    @objc(setPower:) public static func setPower(_ power: Float) {
        var p = power
        if p < 0 { p = max(0, (p + 50) / 50) }
        level = p
        model.feed.send(SiriGlassLevels(loudness: p))
    }

    /// Shows `text` in the island card: role 0 what the user said, 1 Siri's
    /// answer. Empty or nil folds the card back into the drop.
    @objc(setCaption:role:) public static func setCaption(_ text: String?, role: Int) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let next = trimmed.isEmpty ? nil : SiriGlassCaption(trimmed, role: role == 1 ? .siri : .user)
        if model.caption != next { model.caption = next }
    }

    /// Siri's result card at its natural size (points) and corner radius;
    /// 0 x 0 takes it away. The glass makes room for it under the words.
    @objc(setAttachmentWidth:height:radius:) public static func setAttachment(width: Double, height: Double, radius: Double) {
        let size = width > 1 && height > 1 ? CGSize(width: width, height: height) : nil
        if model.attachment != size { model.attachment = size }
        if radius > 0 { model.attachmentRadius = radius }
    }

    /// Where the card should sit, in screen points, once the glass has made
    /// room for it; zero until then (and when there is none).
    @objc public static var attachmentFrame: CGRect { SiriGlassAttachment.frame ?? .zero }
    @objc public static var attachmentCornerRadius: Double { SiriGlassAttachment.cornerRadius }

    /// Where the caption's glass is heading (screen points), zero when there
    /// is none: the status bar gets out of its way.
    @objc public static var captionGlassFrame: CGRect { SiriGlassCaptionGlass.frame ?? .zero }
    @objc public static var captionGlassNow: CGRect { SiriGlassCaptionGlass.current ?? .zero }

    /// Supplies the screen picture the glass bends (see `SiriGlassBackdrop`).
    /// The Dynamic Island's live frame in window coordinates (width 0 clears it).
    @objc(setIslandX:y:width:height:) public static func setIsland(x: Double, y: Double, width: Double, height: Double) {
        let rect = width > 0 ? CGRect(x: x, y: y, width: width, height: height) : nil
        if SiriGlassIsland.override != rect { SiriGlassIsland.override = rect }
    }

    /// The provider's picture leaves the drop's window out: it may be taken
    /// again while a caption is up, every `interval` seconds.
    @objc(setBackdropExcludesGlass:interval:) public static func setBackdropExcludesGlass(_ excludes: Bool, interval: Double) {
        SiriGlassBackdrop.excludesGlass = excludes
        SiriGlassBackdrop.refreshInterval = interval
    }

    /// The screen under the glass has just changed: a fresh picture now.
    @objc public static func refreshBackdrop() {
        SiriGlassBackdrop.requestedAt = CACurrentMediaTime()
    }

    @objc(setBackdropProvider:) public static func setBackdropProvider(_ provider: (@convention(block) () -> UIImage?)?) {
        guard let provider else { SiriGlassBackdrop.provider = nil; return }
        SiriGlassBackdrop.provider = { provider()?.cgImage }
    }
}
