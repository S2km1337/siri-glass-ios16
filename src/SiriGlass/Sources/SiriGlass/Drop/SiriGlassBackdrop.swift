//
//  SiriGlassBackdrop.swift
//  SiriGlass
//
//  Lets a host that can see more than the drop's own window (a jailbreak
//  tweak in SpringBoard) supply the picture the glass bends. By default the
//  drop captures its own window.
//

import CoreGraphics

public enum SiriGlassBackdrop {
    /// Returns the whole screen as an image, in points-to-pixels of the
    /// screen's own scale (as `UIScreen` would draw it). Called on the main
    /// thread when the drop appears, and every `refreshInterval` seconds
    /// after that. When nil, the drop captures its own window.
    @MainActor public static var provider: (() -> CGImage?)?
    /// Seconds between calls to `provider` while the drop is out; 0 asks for
    /// one capture per appearance.
    @MainActor public static var refreshInterval: Double = 0
    /// The provider's picture leaves the drop's own window out, so it may
    /// be taken again while a caption is up (the screen under the glass
    /// can change: Siri opens an app). Otherwise the picture taken before
    /// the caption is kept, since a new one would hold the caption itself.
    @MainActor public static var excludesGlass = false
    /// A fresh picture is wanted now (CACurrentMediaTime), whatever the
    /// interval: the screen under the glass has just changed.
    @MainActor public static var requestedAt = -Double.infinity
}

extension SiriGlassIsland {
    /// The Dynamic Island's actual frame in window coordinates, when a host
    /// can see it (a live activity makes it wider or taller than the plain
    /// pill). When nil, the drop assumes the plain island.
    @MainActor public static var override: CGRect?
}
