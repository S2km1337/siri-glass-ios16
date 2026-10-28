// SiriGlassTweak: shows SiriGlass's drop (pouring out of the Dynamic Island)
// in place of Siri's orb. It runs in SpringBoard, where iOS 16 keeps the orb
// (SUICOrbView, inside the SBAssistantWindow). The orb is kept, invisible, as
// the source of Siri's state: its `mode` and `power` drive the drop.
//
// The drop itself is SiriGlassHost.framework (Swift, SwiftUI + Metal), loaded
// at runtime and reached through the SGHost class.
//
// Mode numbers are read from /var/mobile/siriglass-modes.txt ("0=idle
// 1=listening 2=thinking 3=listening"), so they can be corrected without
// rebuilding.
//
// It also runs in Siri.app, which draws Siri's words (what you said, and
// Siri's answer) at the bottom of the screen in a scene SpringBoard only
// hosts. There it hides those words and hands them to SpringBoard, which
// shows them in the drop, grown across the top of the screen as iOS 27 does.
// Siri.app is sandboxed: the words go through a small file in a directory
// its sandbox may write (see CaptionPaths) and a Darwin notification.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <CoreFoundation/CoreFoundation.h>
#import <roothide.h>
#import <notify.h>

@interface SUICOrbView : UIView
@end

@interface SBSystemApertureContainerView : UIView
@end

@interface AFUITouchPassThroughView : UIView
@end

static void DismissByUser(NSString *why);
BOOL SGSiriBusy(void);

@interface NSObject (SGAssistant)
- (void)stopSpeech;   // AFConnection
@end

static void Log(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void Log(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[SiriGlass] %@", line);
}

/// Debug logging to files is off unless the `DebugLog` preference
/// (com.local.siriglasstweak) is set: the logs hold what Siri and the glass
/// did, so they are not written by default. Never what you said.
static BOOL DebugLogging(void) {
    static BOOL on;
    static CFTimeInterval checked = -10;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - checked < 2) return on;
    checked = now;
    CFTypeRef v = CFPreferencesCopyAppValue(CFSTR("DebugLog"), CFSTR("com.local.siriglasstweak"));
    on = v && CFGetTypeID(v) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)v);
    if (v) CFRelease(v);
    return on;
}

static void SGDebug(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void SGDebug(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    if (!DebugLogging()) return;
    NSLog(@"[SiriGlass] %@", line);
    FILE *f = fopen("/var/tmp/siriglass-debug.log", "a");
    if (f) { fprintf(f, "%.3f %s\n", CACurrentMediaTime(), line.UTF8String); fclose(f); }
}

// The Preferences switch (com.local.siriglasstweak Enabled). Cached briefly:
// the hooks run often, and CFPreferences is a file read.
static BOOL enabledCache = YES;
static CFTimeInterval enabledChecked = 0;
static BOOL TweakEnabled(void) {
    CFTimeInterval now = CACurrentMediaTime();
    if (now - enabledChecked < 0.5) return enabledCache;
    enabledChecked = now;
    CFTypeRef value = CFPreferencesCopyAppValue(CFSTR("Enabled"), CFSTR("com.local.siriglasstweak"));
    if (!value) {
        enabledCache = YES;
    } else if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
        enabledCache = CFBooleanGetValue((CFBooleanRef)value);
    } else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        int b = 1;
        CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &b);
        enabledCache = b != 0;
    } else {
        enabledCache = YES;
    }
    if (value) CFRelease(value);
    return enabledCache;
}
static void InvalidateEnabledCache(void) { enabledChecked = 0; }

// The status bar's way out of the glass (see "the status bar makes way").
static void ApplyGlassAvoidance(CGRect avoid);
static CGRect glassAvoid;

// SGHost is main-actor isolated: every call goes through the main queue.
// Always asynchronous, so nothing runs inside UIKit's own view-move code, and
// an exception in the host can never take SpringBoard down with it.
static void OnMain(dispatch_block_t block) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try { block(); }
        @catch (NSException *e) { Log(@"host exception: %@ %@", e.name, e.reason); }
    });
}

static UIWindow *OverlayForCapture(void);
static BOOL backdropChecked = NO;     // this Siri session
static CGRect HostRect(NSString *selector);
static BOOL backdropExcludes = NO;

static UIImage *WholeScreen(void) {
    typedef id (*ScreenImage)(void);
    static ScreenImage fn;
    if (!fn) fn = (ScreenImage)dlsym(RTLD_DEFAULT, "_UICreateScreenUIImage");
    id image = fn ? fn() : nil;
    return [image isKindOfClass:UIImage.class] ? image : nil;
}

/// The newest picture of the screen without the glass, and when it was taken.
static UIImage *lastBackdrop;
static CFAbsoluteTime backdropTakenAt = 0;
static BOOL backdropWanted = NO;
static int backdropFailures = 0;

/// The screen without the glass's own window: the window is marked, for
/// the moment of the capture, as one screenshots leave out (the layer flag
/// screen-recording protection uses; it stays on screen meanwhile).
static UIImage *CaptureWithoutGlass(void) {
    UIWindow *glass = OverlayForCapture();
    CALayer *layer = glass.layer;
    SEL get = NSSelectorFromString(@"disableUpdateMask"), set = NSSelectorFromString(@"setDisableUpdateMask:");
    if (!layer || ![layer respondsToSelector:get] || ![layer respondsToSelector:set]) return nil;
    unsigned int before = ((unsigned int (*)(id, SEL))objc_msgSend)(layer, get);
    ((void (*)(id, SEL, unsigned int))objc_msgSend)(layer, set, before | 0x12);
    [CATransaction flush];
    UIImage *image = WholeScreen();
    ((void (*)(id, SEL, unsigned int))objc_msgSend)(layer, set, before);
    [CATransaction flush];
    return image;
}

/// The average colour of part of a picture (`rect` in points), 4x4 samples.
static BOOL AverageColour(UIImage *image, CGRect rect, double rgba[4]) {
    CGImageRef whole = image.CGImage;
    if (!whole) return NO;
    CGFloat k = image.scale;
    CGImageRef part = CGImageCreateWithImageInRect(whole, CGRectMake(rect.origin.x * k, rect.origin.y * k, rect.size.width * k, rect.size.height * k));
    if (!part) return NO;
    uint8_t px[4 * 4 * 4] = {0};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(px, 4, 4, 8, 16, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (c) {
        CGContextSetInterpolationQuality(c, kCGInterpolationMedium);
        CGContextDrawImage(c, CGRectMake(0, 0, 4, 4), part);
        CGContextRelease(c);
    }
    CGImageRelease(part);
    if (!c) return NO;
    for (int i = 0; i < 4; i++) {
        double sum = 0;
        for (int j = 0; j < 16; j++) sum += px[j * 4 + i];
        rgba[i] = sum / 16 / 255;
    }
    return YES;
}

/// The picture at 1x (what the glass works at): made off the main thread,
/// so the glass draws a small picture rather than a 3x screen.
static UIImage *Shrunk(UIImage *image) {
    if (!image) return nil;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = YES;
    CGSize size = image.size;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *c) {
        [image drawInRect:CGRectMake(0, 0, size.width, size.height)];
    }];
}

static dispatch_queue_t BackdropQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("siriglass.backdrop", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0)); });
    return q;
}

static void HostRefreshBackdrop(void) {
    Class host = NSClassFromString(@"SGHost");
    SEL sel = NSSelectorFromString(@"refreshBackdrop");
    if ([host respondsToSelector:sel]) ((void (*)(Class, SEL))objc_msgSend)(host, sel);
}

/// What the glass bends: the newest picture without the glass once that is
/// known to work; otherwise the whole screen (the old way: taken as the drop
/// appears, kept while there are words).
static UIImage *BackdropImage(void) {
    if (backdropExcludes && lastBackdrop) return lastBackdrop;
    return Shrunk(WholeScreen());
}

/// Run by the watchdog (every 0.15 s while Siri or its words are up). First
/// it checks, while the caption glass is out, that pictures without the
/// glass really leave it out (the glass's patch differs from the same patch
/// of the whole screen); after that it keeps the picture fresh: every second
/// and whenever the screen under the glass has just changed.
static void PumpBackdrop(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!backdropExcludes) {
        if (backdropChecked || backdropFailures >= 6) return;
        CGRect glass = HostRect(@"captionGlassNow");
        if (glass.size.width < 120 || glass.size.height < 90) return;
        backdropChecked = YES;
        // The glass's middle, under the words' first line.
        CGRect patch = CGRectMake(CGRectGetMidX(glass) - 60, glass.origin.y + 50, 120, MIN(60, glass.size.height - 55));
        UIImage *without = CaptureWithoutGlass(), *with = WholeScreen();
        double a[4] = {0}, b[4] = {0};
        BOOL measured = without && with && AverageColour(without, patch, a) && AverageColour(with, patch, b);
        double off = fabs(a[0] - b[0]) + fabs(a[1] - b[1]) + fabs(a[2] - b[2]);
        BOOL ok = measured && off > 0.06;
        SGDebug(@"backdrop: %@ (patch differs by %.3f)", ok ? @"live, without the glass" :
                (measured ? @"whole screen: the glass did not leave the picture" : @"whole screen: no picture"), off);
        if (!ok) { backdropFailures++; return; }
        backdropExcludes = YES;
        lastBackdrop = Shrunk(without);
        backdropTakenAt = now;
        Class host = NSClassFromString(@"SGHost");
        SEL sel = NSSelectorFromString(@"setBackdropExcludesGlass:interval:");
        if ([host respondsToSelector:sel]) ((void (*)(Class, SEL, BOOL, double))objc_msgSend)(host, sel, YES, 2.0);
        HostRefreshBackdrop();
        return;
    }
    // Every two seconds, and when the screen has just changed. The capture
    // itself has to be on the main thread; making it small is not.
    static BOOL shrinking;
    if (shrinking || (!backdropWanted && now - backdropTakenAt < 2.0)) return;
    backdropWanted = NO;
    CFTimeInterval started = CACurrentMediaTime();
    UIImage *image = CaptureWithoutGlass();
    CFTimeInterval took = CACurrentMediaTime() - started;
    if (!image) return;
    backdropTakenAt = now;
    shrinking = YES;
    dispatch_async(BackdropQueue(), ^{
        UIImage *small = Shrunk(image);
        dispatch_async(dispatch_get_main_queue(), ^{
            shrinking = NO;
            if (small) lastBackdrop = small;
            HostRefreshBackdrop();
        });
    });
    static int logged;
    if (logged++ % 15 == 0) SGDebug(@"backdrop: capture took %.1f ms", took * 1000);
}

/// The screen under the glass has just changed (a new Siri session, Siri
/// gone, an app opening): fresh pictures now and once things have settled.
static void RefreshBackdropSoon(void) {
    for (NSNumber *delay in @[@0.0, @0.35, @1.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (backdropExcludes) { backdropWanted = YES; PumpBackdrop(); }
            else if (delay.doubleValue == 0) HostRefreshBackdrop();
        });
    }
}

static Class SGHost(void) {
    static Class host;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = jbroot(@"/Library/Frameworks/SiriGlassHost.framework/SiriGlassHost");
        void *handle = dlopen(path.UTF8String, RTLD_NOW);
        if (!handle) { Log(@"dlopen failed: %s", dlerror()); return; }
        host = NSClassFromString(@"SGHost");
        // The screen, for the glass to bend. Taken without the drop's own
        // window when SpringBoard can (then it follows the screen while a
        // caption is up); otherwise the whole screen, once per appearance.
        id (^provider)(void) = ^id { return BackdropImage(); };
        OnMain(^{ ((void (*)(Class, SEL, id))objc_msgSend)(host, NSSelectorFromString(@"setBackdropProvider:"), provider); });
    });
    return host;
}

// MARK: - Siri's words, from Siri.app to SpringBoard

#define kCaptionNotification "com.local.siriglasstweak/caption"
// Siri's result card: Siri.app says how big it is; SpringBoard says where in
// the glass it goes. Both files live where Siri.app may write.
#define kCardNotification "com.local.siriglasstweak/card"
#define kLayoutNotification "com.local.siriglasstweak/layout"
static NSString *const kCardPath = @"/var/mobile/Library/Logs/CrashReporter/Assistant/CardLogs/siriglass-card.plist";
static NSString *const kLayoutPath = @"/var/mobile/Library/Logs/CrashReporter/Assistant/CardLogs/siriglass-layout.plist";

// Where Siri.app may write: its sandbox allows ~/Library/Logs/CrashReporter/
// Assistant/CardLogs/ (read-write); the directory above it is tried too.
static NSArray<NSString *> *CaptionPaths(void) {
    return @[@"/var/mobile/Library/Logs/CrashReporter/Assistant/CardLogs/siriglass-caption.plist",
             @"/var/mobile/Library/Logs/CrashReporter/Assistant/siriglass-caption.plist"];
}

/// The text in whatever Siri hands over: a string, an attributed string, or
/// an object with a `text` (SAUIAssistantUtteranceView, a label).
static NSString *TextOf(id value) {
    if (!value) return nil;
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSAttributedString.class]) return [(NSAttributedString *)value string];
    for (NSString *key in @[@"attributedText", @"text", @"string"]) {
        SEL sel = NSSelectorFromString(key);
        if (![value respondsToSelector:sel]) continue;
        id inner = ((id (*)(id, SEL))objc_msgSend)(value, sel);
        if (inner && inner != value) {
            NSString *t = TextOf(inner);
            if (t.length) return t;
        }
    }
    return nil;
}

// Siri's answer, straight from the commands Siri gets back from its server
// (AFConnection), so it is there whether or not Siri shows its captions:
// AddViews carries AssistantUtteranceView items whose `text` is what Siri
// says; AddDialogs carries dialogs with `printedText`.
static NSDictionary *AceDictionary(id object) {
    @try {
        id d = [object valueForKey:@"dictionary"];
        return [d isKindOfClass:NSDictionary.class] ? d : nil;
    } @catch (NSException *e) { return nil; }
}

static NSString *FindAceText(id node, int depth) {
    if (depth > 5 || !node) return nil;
    if ([node isKindOfClass:NSDictionary.class]) {
        for (NSString *key in @[@"printedText", @"text"]) {
            id v = node[key];
            if ([v isKindOfClass:NSString.class] && [(NSString *)v length]) return v;
        }
        for (id v in [node allValues]) { NSString *t = FindAceText(v, depth + 1); if (t) return t; }
    } else if ([node isKindOfClass:NSArray.class]) {
        for (id v in node) { NSString *t = FindAceText(v, depth + 1); if (t) return t; }
    }
    return nil;
}

static NSString *AnswerFromCommand(id command) {
    NSDictionary *d = AceDictionary(command);
    if (!d) return nil;
    NSString *cls = [d[@"$class"] isKindOfClass:NSString.class] ? d[@"$class"] : NSStringFromClass([command class]);
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if ([cls hasSuffix:@"AddViews"]) {
        for (id view in d[@"views"]) {
            if (![view isKindOfClass:NSDictionary.class]) continue;
            if (![view[@"$class"] isKindOfClass:NSString.class] || ![view[@"$class"] hasSuffix:@"AssistantUtteranceView"]) continue;
            NSString *t = [view[@"text"] isKindOfClass:NSString.class] ? view[@"text"] : view[@"speakableText"];
            if ([t isKindOfClass:NSString.class] && t.length) [parts addObject:t];
        }
    } else if ([cls hasSuffix:@"AddDialogs"]) {
        for (id dialog in d[@"dialogs"]) {
            NSString *t = FindAceText(dialog, 0);
            if (t.length) [parts addObject:t];
        }
    }
    return parts.count ? [parts componentsJoinedByString:@" "] : nil;
}

static BOOL EndsCJK(NSString *s) {
    if (!s.length) return NO;
    unichar c = [s characterAtIndex:s.length - 1];
    return (c >= 0x2E80 && c <= 0x9FFF) || (c >= 0x3000 && c <= 0x303F) || (c >= 0xFF00 && c <= 0xFFEF);
}

/// The answer so far in this turn: Siri may send it in several pieces.
static NSMutableArray<NSString *> *answerParts;
static CFAbsoluteTime answerAt = 0;

static void ResetAnswer(void) { answerParts = nil; }

static NSString *AppendAnswer(NSString *piece) {
    piece = [piece stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!piece.length) return nil;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!answerParts || now - answerAt > 20) answerParts = [NSMutableArray array];
    answerAt = now;
    if (![answerParts containsObject:piece]) [answerParts addObject:piece];
    NSMutableString *out = [NSMutableString string];
    for (NSString *p in answerParts) {
        if (out.length && !(EndsCJK(out) && EndsCJK([p substringToIndex:1]))) [out appendString:@" "];
        [out appendString:p];
    }
    return out;
}

// MARK: - Swipe down from the island to call Siri

// The system's own Siri path: SiriActivationService in SpringBoard.
// SASRequestSourceMotionDownGesture is 7 in the iOS 16.5 enum (read from the
// SiriActivation binary; the names are in SASRequestSourceGetName).
static BOOL siriActive = NO;

static UIView *IslandView(void);
static void FindApertures(UIView *v, NSMutableArray<UIView *> *found);
static void InstallSiriGesture(UIView *view);

static CGRect IslandRectInView(UIView *view) {
    UIView *island = IslandView();
    if (!island || !view) return CGRectZero;
    return [island.superview convertRect:island.frame toView:view];
}

static void DetachHost(void) {
    // Do not dlopen the host just to switch it off.
    Class host = NSClassFromString(@"SGHost");
    SEL sel = NSSelectorFromString(@"detach");
    if (host && [host respondsToSelector:sel]) OnMain(^{ ((void (*)(Class, SEL))objc_msgSend)(host, sel); });
}

static id siriClientSource;   // keep the BSService connection alive

static void TriggerSiriViaClient(void) {
    Class srcCls = NSClassFromString(@"SiriSimpleActivationSource");
    SGDebug(@"client source class %@", srcCls);
    if (!srcCls) return;
    if (!siriClientSource)
        siriClientSource = ((id (*)(id, SEL))objc_msgSend)([srcCls alloc], NSSelectorFromString(@"init"));
    SEL sel = NSSelectorFromString(@"activateFromSource:");
    if (siriClientSource && [siriClientSource respondsToSelector:sel]) {
        ((void (*)(id, SEL, long long))objc_msgSend)(siriClientSource, sel, 7);
        SGDebug(@"activateFromSource:7 sent via %@", siriClientSource);
    } else {
        SGDebug(@"client source unavailable: %@", siriClientSource);
    }
}

static void TriggerSiri(NSString *why) {
    SGDebug(@"trigger via %@ (active=%d enabled=%d)", why, siriActive, TweakEnabled());
    if (!TweakEnabled() || siriActive) return;
    Class serviceClass = NSClassFromString(@"SiriActivationService");
    SGDebug(@"SiriActivationService class %@", serviceClass);
    if (!serviceClass) { TriggerSiriViaClient(); return; }
    id service = ((id (*)(Class, SEL))objc_msgSend)(serviceClass, NSSelectorFromString(@"service"));
    SGDebug(@"service instance %@", service);
    if (!service) { TriggerSiriViaClient(); return; }
    @try {
        BOOL handled = NO;
        Class reqClass = NSClassFromString(@"SASActivationRequest");
        id req = nil;
        if (reqClass)
            req = ((id (*)(id, SEL, long long))objc_msgSend)([reqClass alloc],
                    NSSelectorFromString(@"initWithSimpleActivation:"), 7);
        SGDebug(@"request %@", req);
        if (req) {
            SEL h = NSSelectorFromString(@"handleActivationRequest:");
            if ([service respondsToSelector:h]) {
                handled = ((BOOL (*)(id, SEL, id))objc_msgSend)(service, h, req);
                SGDebug(@"handleActivationRequest: -> %d", handled);
            }
            SEL hs = NSSelectorFromString(@"handleActivationRequest:systemState:");
            if (!handled && [service respondsToSelector:hs]) {
                id state = [service respondsToSelector:NSSelectorFromString(@"systemState")]
                    ? ((id (*)(id, SEL))objc_msgSend)(service, NSSelectorFromString(@"systemState")) : nil;
                handled = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(service, hs, req, state);
                SGDebug(@"handleActivationRequest:systemState: -> %d (state %@)", handled, state);
            }
        }
        SEL simple = NSSelectorFromString(@"activationRequestFromSimpleActivation:");
        if (!handled && [service respondsToSelector:simple]) {
            ((void (*)(id, SEL, long long))objc_msgSend)(service, simple, 7);
            SGDebug(@"activationRequestFromSimpleActivation:7 sent");
        }
        if (!handled) TriggerSiriViaClient();
    } @catch (NSException *e) {
        SGDebug(@"Siri activation exception: %@ %@", e.name, e.reason);
    }
}

@interface SGSiriGesture : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic) BOOL fired;
@end

@implementation SGSiriGesture
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;   // leave the island's own tap/long-press alone
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    UIView *view = g.view;
    CGPoint p = [g locationInView:view];
    CGRect area = CGRectInset(IslandRectInView(view), -14, -14);
    BOOL inside = CGRectContainsPoint(area, p);
    CGPoint v = CGPointZero;
    BOOL down = YES, up = NO;
    if ([g isKindOfClass:[UIPanGestureRecognizer class]]) {
        v = [(UIPanGestureRecognizer *)g velocityInView:view];
        down = v.y >= 0 && v.y > fabs(v.x);
        // Up, while the glass is out: send it away.
        up = v.y < 0 && -v.y > fabs(v.x) && SGSiriBusy();
    }
    SGDebug(@"shouldBegin %@ at %@ island=%@ inside=%d v=%@",
            NSStringFromClass(g.class), NSStringFromCGPoint(p), NSStringFromCGRect(area), inside, NSStringFromCGPoint(v));
    return inside && (down || up);
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    if (pan.state == UIGestureRecognizerStateBegan) self.fired = NO;
    CGPoint t = [pan translationInView:pan.view];
    if (pan.state == UIGestureRecognizerStateChanged)
        SGDebug(@"pan changed t=%@", NSStringFromCGPoint(t));
    if (!self.fired && t.y > 20 && fabs(t.x) < 50) {
        self.fired = YES;
        TriggerSiri(@"pan");
    } else if (!self.fired && t.y < -20 && fabs(t.x) < 50 && SGSiriBusy()) {
        self.fired = YES;
        DismissByUser(@"swipe up on the island");
    }
}

- (void)handleSwipe:(UISwipeGestureRecognizer *)swipe {
    if (swipe.state == UIGestureRecognizerStateEnded) TriggerSiri(@"swipe");
}
@end

static SGSiriGesture *siriGesture;
static char kSiriGestureKey;

static void InstallSiriGestureOn(UIView *view, NSString *where) {
    if (!view || !TweakEnabled()) return;
    if (objc_getAssociatedObject(view, &kSiriGestureKey)) return;
    if (!siriGesture) siriGesture = [SGSiriGesture new];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:siriGesture action:@selector(handlePan:)];
    pan.delegate = siriGesture;
    pan.cancelsTouchesInView = NO;
    pan.delaysTouchesBegan = NO;
    pan.delaysTouchesEnded = NO;
    [view addGestureRecognizer:pan];
    UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc] initWithTarget:siriGesture action:@selector(handleSwipe:)];
    swipe.direction = UISwipeGestureRecognizerDirectionDown;
    swipe.delegate = siriGesture;
    [view addGestureRecognizer:swipe];
    objc_setAssociatedObject(view, &kSiriGestureKey, pan, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SGDebug(@"pan+swipe installed on %@ %@", where, NSStringFromClass(view.class));
}

static void InstallSiriGesture(UIView *island) {
    if (!island) return;
    InstallSiriGestureOn(island, @"island");
    InstallSiriGestureOn(island.window, @"window");
}

static void EnsureSiriGestureInstalled(void) {
    if (!TweakEnabled()) return;
    BOOL any = NO;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (w.hidden) continue;
        if (![NSStringFromClass(w.class) isEqualToString:@"SBSystemApertureWindow"]) continue;
        any = YES;
        InstallSiriGestureOn(w, @"aperture-window");
        NSMutableArray<UIView *> *found = [NSMutableArray array];
        FindApertures(w, found);
        for (UIView *v in found) {
            InstallSiriGestureOn(v, @"aperture-container");
            UIView *island = v;
            CGRect r = [island.superview convertRect:island.frame toView:w];
            CGPoint c = CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r));
            UIView *hit = [w hitTest:c withEvent:nil];
            (void)hit;
        }
    }
    if (!any) SGDebug(@"no SBSystemApertureWindow yet");
}

static NSTimer *gestureWatch;
static void StartGestureWatch(void) {
    if (gestureWatch) return;
    gestureWatch = [NSTimer scheduledTimerWithTimeInterval:3.0 repeats:YES block:^(NSTimer *t) {
        EnsureSiriGestureInstalled();
    }];
    SGDebug(@"gesture watch started");
}

// The drop has a window of its own, over Siri's and under the Dynamic
// Island's. It used to be drawn in Siri's window (SBAssistantWindow), which
// iOS hides the moment Siri goes: the drop was cut off mid-way home. In its
// own window it always finishes, and the window hides once it has.
static void DismissByUser(NSString *why);
BOOL SGSiriBusy(void);

/// Where the caption glass is now (window coordinates), and its card's hole.
static CGRect HostRect(NSString *selector) {
    Class host = NSClassFromString(@"SGHost");
    SEL sel = NSSelectorFromString(selector);
    return [host respondsToSelector:sel] ? ((CGRect (*)(Class, SEL))objc_msgSend)(host, sel) : CGRectZero;
}

/// Takes the touches that land on the glass (they used to fall through to
/// the app under it): a swipe up sends the glass away at once, whatever it
/// is doing; so does a tap once Siri itself has gone (an answer being read).
@interface SGGlassCatcher : UIView <UIGestureRecognizerDelegate>
@end

@implementation SGGlassCatcher
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)];
        pan.delegate = self;
        [self addGestureRecognizer:pan];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tap:)];
        [tap requireGestureRecognizerToFail:pan];
        [self addGestureRecognizer:tap];
    }
    return self;
}
- (void)pan:(UIPanGestureRecognizer *)pan {
    if (pan.state != UIGestureRecognizerStateEnded && pan.state != UIGestureRecognizerStateChanged) return;
    CGPoint t = [pan translationInView:self], v = [pan velocityInView:self];
    BOOL up = -t.y > fabs(t.x) && (-t.y > 28 || (pan.state == UIGestureRecognizerStateEnded && v.y < -350));
    if (up) { pan.enabled = NO; pan.enabled = YES; DismissByUser(@"swipe up on the glass"); }
}
- (void)tap:(UITapGestureRecognizer *)tap {
    extern BOOL SGSiriListening(void);
    if (tap.state == UIGestureRecognizerStateEnded && !SGSiriListening()) DismissByUser(@"tap on the glass");
}
@end

@interface SGOverlayWindow : UIWindow
@property (nonatomic, strong) SGGlassCatcher *catcher;
@end

@implementation SGOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    // Everything goes through but the glass itself; its card's hole goes
    // through too, to Siri's card under it.
    if (!self.catcher || self.hidden || !SGSiriBusy()) return nil;
    CGRect glass = HostRect(@"captionGlassNow");
    if (glass.size.width < 1 || !CGRectContainsPoint(glass, point)) return nil;
    CGRect hole = HostRect(@"attachmentFrame");
    if (hole.size.width > 1 && CGRectContainsPoint(hole, point)) return nil;
    if (self.catcher.superview != self) [self addSubview:self.catcher];
    return self.catcher;
}
- (BOOL)canBecomeKeyWindow { return NO; }
// Like SpringBoard's own pass-through windows (Siri's, Control Center's):
// the window server asks this window, point by point, whether it takes a
// touch. Without this it went by the drop layer's bounds, and every touch
// on the top of the screen (the card in the glass included) ended up in
// SpringBoard instead of Siri or the app under it.
- (BOOL)_usesWindowServerHitTesting { return YES; }
- (UIView *)_hitTest:(CGPoint)point withEvent:(UIEvent *)event windowServerHitTestWindow:(UIWindow *)window {
    UIView *result = [self hitTest:point withEvent:event];
    extern void SGLogGlassProbe(CGPoint point, UIView *result);
    SGLogGlassProbe(point, result);
    return result;
}
@end

static SGOverlayWindow *overlay;
static UIWindow *OverlayForCapture(void) { return overlay; }

static UIWindow *OverlayWindow(UIWindow *siriWindow) {
    UIWindowScene *scene = siriWindow.windowScene;
    if (!scene) return siriWindow;
    if (!overlay || overlay.windowScene != scene) {
        overlay.hidden = YES;
        overlay = [[SGOverlayWindow alloc] initWithWindowScene:scene];
        overlay.backgroundColor = UIColor.clearColor;
        overlay.opaque = NO;
        overlay.catcher = [[SGGlassCatcher alloc] initWithFrame:overlay.bounds];
        [overlay addSubview:overlay.catcher];
    }
    // Above Siri, below the island (so the island stays on top of the glass).
    UIWindowLevel level = siriWindow.windowLevel + 1;
    for (UIWindow *w in scene.windows)
        if ([NSStringFromClass(w.class) isEqualToString:@"SBSystemApertureWindow"] && w.windowLevel <= level)
            level = (siriWindow.windowLevel + w.windowLevel) / 2;
    overlay.windowLevel = level;
    overlay.frame = siriWindow.screen.bounds;
    overlay.hidden = NO;
    return overlay;
}

/// Hides the drop's window once nothing is left in it: Siri gone, the
/// words gone, and the drop home.
static void HideOverlaySoon(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        extern BOOL SGSiriBusy(void);
        if (SGSiriBusy() || !overlay) return;
        overlay.hidden = YES;
    });
}

// The Siri window may not have a root view controller yet when the orb first
// reaches it (that is how the drop used to appear only at "thinking"), so keep
// trying for a few seconds.
static void EnsureAttach(UIWindow *siriWindow, int tries) {
    Class host = SGHost();
    if (!host || !siriWindow) return;
    UIWindow *window = OverlayWindow(siriWindow);
    OnMain(^{
        BOOL ok = ((BOOL (*)(Class, SEL, id))objc_msgSend)(host, NSSelectorFromString(@"attachToWindow:"), window);
        if (ok) return;
        if (tries > 0) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ EnsureAttach(siriWindow, tries - 1); });
        else Log(@"  attach gave up: no root view controller");
    });
}

// The old Siri at the bottom: the orb sits in a 66 x 66 container with a
// sibling of the same size next to it. Make both (and everything in them)
// invisible, and keep them that way: Siri resets their alpha as it animates.
static void HideOldSiri(UIView *orb) {
    UIView *container = orb.superview;
    UIView *host = container.superview;
    for (UIView *v in host.subviews) {
        CGSize sz = v.bounds.size;
        if (v == container || (fabs(sz.width - 66) < 1 && fabs(sz.height - 66) < 1)) {
            v.layer.opacity = 0.011;
            for (UIView *s in v.subviews) s.layer.opacity = 0.011;
        }
    }
    orb.layer.opacity = 0.011;
}

// Put the old orb back when the tweak is switched off.
static void RestoreOldSiri(UIView *orb) {
    UIView *container = orb.superview;
    UIView *host = container.superview;
    for (UIView *v in host.subviews) {
        CGSize sz = v.bounds.size;
        if (v == container || (fabs(sz.width - 66) < 1 && fabs(sz.height - 66) < 1)) {
            v.layer.opacity = 1.0;
            for (UIView *s in v.subviews) s.layer.opacity = 1.0;
        }
    }
    orb.layer.opacity = 1.0;
}

static __weak SUICOrbView *currentOrb;
static UIView *IslandView(void);

static void PreferencesChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                               const void *object, CFDictionaryRef userInfo) {
    InvalidateEnabledCache();
    if (TweakEnabled()) {
        // The island may already be on screen; give it the swipe now.
        OnMain(^{ EnsureSiriGestureInstalled(); });
        return;
    }
    OnMain(^{
        if (currentOrb) RestoreOldSiri(currentOrb);
        DetachHost();
        // Switched off: the status bar is the island's alone again.
        if (!CGRectIsEmpty(glassAvoid)) ApplyGlassAvoidance(CGRectZero);
    });
}

static NSInteger StateForMode(long long mode) {
    // 0 idle, 1 listening, 2 thinking
    static NSDictionary *map;
    static NSDate *loaded;
    if (!map || [[NSDate date] timeIntervalSinceDate:loaded] > 2) {
        NSMutableDictionary *m = [@{@0: @0, @1: @1, @2: @2, @3: @1} mutableCopy];
        NSString *text = [NSString stringWithContentsOfFile:@"/var/mobile/siriglass-modes.txt" encoding:NSUTF8StringEncoding error:nil];
        for (NSString *pair in [text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
            NSArray *kv = [pair componentsSeparatedByString:@"="];
            if (kv.count != 2) continue;
            NSString *v = [kv[1] lowercaseString];
            m[@([kv[0] integerValue])] = @([v isEqualToString:@"listening"] ? 1 : [v isEqualToString:@"thinking"] ? 2 : 0);
        }
        map = m; loaded = [NSDate date];
    }
    NSNumber *s = map[@(mode)];
    return s ? s.integerValue : 0;
}

static void Push(SUICOrbView *orb, long long mode) {
    Class host = SGHost();
    if (!host) return;
    HideOldSiri(orb);
    UIWindow *window = orb.window;
    NSInteger state = StateForMode(mode);
    EnsureAttach(window, 60);
    OnMain(^{
        ((void (*)(Class, SEL, NSInteger))objc_msgSend)(host, NSSelectorFromString(@"setState:"), state);
    });
}

// The Dynamic Island's live frame: a timer or another live activity makes it
// wider (or taller) than the plain pill, and the drop has to cover it. The
// island is measured the moment Siri is called up, then every frame while
// Siri is up, from the island view's presentation layer, so the drop follows
// even while the island is animating between shapes.
static void FindApertures(UIView *v, NSMutableArray<UIView *> *found) {
    if (v.hidden || v.alpha < 0.01) return;
    if ([NSStringFromClass(v.class) isEqualToString:@"SBSystemApertureContainerView"]) { [found addObject:v]; return; }
    for (UIView *s in v.subviews) FindApertures(s, found);
}

/// The island view's frame on screen as it is drawn right now (mid-animation
/// included), or zero.
static CGRect OnScreenFrame(UIView *v) {
    CALayer *shown = v.layer.presentationLayer ?: v.layer;
    UIView *parent = v.superview;
    return parent ? [parent convertRect:shown.frame toView:nil] : CGRectZero;
}

static __weak UIView *islandView;
static CFTimeInterval islandLookedUp;

/// The widest visible island view, looked up again at most twice a second.
static UIView *IslandView(void) {
    UIView *v = islandView;
    if (v && v.window && !v.hidden && CACurrentMediaTime() - islandLookedUp < 0.5) return v;
    islandLookedUp = CACurrentMediaTime();
    UIView *best = nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (w.hidden || ![NSStringFromClass(w.class) isEqualToString:@"SBSystemApertureWindow"]) continue;
        NSMutableArray<UIView *> *found = [NSMutableArray array];
        FindApertures(w, found);
        for (UIView *f in found) if (!best || OnScreenFrame(f).size.width > OnScreenFrame(best).size.width) best = f;
    }
    islandView = best;
    return best;
}

static CGRect lastIsland;
static void PumpCardLayout(void);
static void PumpStatusBar(void);
static void ReadCard(void);
static void SetHostAttachment(double w, double h, double r);
static BOOL cardShown = NO;
static int sbProbesLogged = 0, sbTouchesLogged = 0;
void SGLogGlassProbe(CGPoint point, UIView *result) {
    if (!cardShown || sbProbesLogged >= 16) return;
    sbProbesLogged++;
    SGDebug(@"server asks the glass at %@ -> %@", NSStringFromCGPoint(point), result ? NSStringFromClass(result.class) : @"nil (through)");
}
BOOL SGSiriBusy(void);
static void EndSiri(NSString *why);

static void PushIsland(void) {
    UIView *v = IslandView();
    CGRect f = v ? OnScreenFrame(v) : CGRectZero;
    if (CGRectEqualToRect(f, lastIsland)) return;
    lastIsland = f;
    Class host = SGHost();
    SEL sel = NSSelectorFromString(@"setIslandX:y:width:height:");
    if ([host respondsToSelector:sel])
        ((void (*)(Class, SEL, double, double, double, double))objc_msgSend)(host, sel, f.origin.x, f.origin.y, f.size.width, f.size.height);
}

@interface SGIslandTracker : NSObject
@property (nonatomic) CFTimeInterval until;
@property (nonatomic, strong) CADisplayLink *link;
- (void)tick:(CADisplayLink *)link;
@end

@implementation SGIslandTracker
- (void)tick:(CADisplayLink *)link {
    PushIsland();
    PumpCardLayout();
    PumpStatusBar();
    if (CACurrentMediaTime() > self.until) { [link invalidate]; self.link = nil; }
}
@end

static SGIslandTracker *islandTracker;

/// Measures the island now, and every frame from here on while Siri is up
/// (and for a moment after it leaves, while the drop goes home).
static void TrackIsland(BOOL active) {
    if (!islandTracker) islandTracker = [SGIslandTracker new];
    EnsureSiriGestureInstalled();
    islandTracker.until = active ? INFINITY : CACurrentMediaTime() + 1.5;
    if (active) { islandView = nil; lastIsland = CGRectNull; PushIsland(); }
    if (islandTracker.link) return;
    islandTracker.link = [CADisplayLink displayLinkWithTarget:islandTracker selector:@selector(tick:)];
    [islandTracker.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

// MARK: - SpringBoard: the words into the drop

static CFAbsoluteTime sessionStart = 0;
static CFAbsoluteTime lastCaptionTime = 0;
static BOOL captionShown = NO;
static NSTimer *captionWatch;
static CFTimeInterval lastActive = 0;

/// What the island shows now, and since when.
static NSString *shownText;
static NSInteger shownRole = -1;
static CFAbsoluteTime shownAt = 0;
/// The last words of yours shown this turn: Siri sends them once more,
/// final, right after its answer, and that must not replace the answer.
static NSString *lastUserText;
/// When your words for the newest turn came (Siri.app's clock): cards
/// reported before it belong to an earlier turn.
static double cardTurnAt = 0;


static void SetHostCaption(NSString *text, NSInteger role) {
    Class host = NSClassFromString(@"SGHost");
    SEL sel = NSSelectorFromString(@"setCaption:role:");
    if (!host || ![host respondsToSelector:sel]) return;
    if (role == 0 && text.length && shownRole == 1 && [text isEqualToString:lastUserText]) {
        SGDebug(@"ignored: your words again after the answer");
        return;
    }
    if (role == 0 && text.length) lastUserText = text;
    if (text.length && !(role == shownRole && [text isEqualToString:shownText])) shownAt = CFAbsoluteTimeGetCurrent();
    shownText = text;
    shownRole = text.length ? role : -1;
    captionShown = text.length > 0;
    OnMain(^{ ((void (*)(Class, SEL, id, NSInteger))objc_msgSend)(host, sel, text, role); });
}

/// The newest caption Siri.app wrote in this Siri session, if it changed.
static void ReadCaption(void) {
    if (!TweakEnabled()) return;
    NSDictionary *newest = nil;
    for (NSString *path in CaptionPaths()) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
        if (![d isKindOfClass:NSDictionary.class]) continue;
        if (!newest || [d[@"time"] doubleValue] > [newest[@"time"] doubleValue]) newest = d;
    }
    double time = [newest[@"time"] doubleValue];
    if (!newest || time <= lastCaptionTime) return;
    lastCaptionTime = time;
    // Left over from an earlier Siri session.
    if (time < sessionStart - 0.5) return;
    if ([newest[@"gone"] boolValue]) {
        // Siri.app's view has gone. Unless something new comes in the next
        // half second, Siri has gone.
        SGDebug(@"Siri.app says its view has gone");
        double seen = lastCaptionTime;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (lastCaptionTime == seen) EndSiri(@"Siri.app view gone");
        });
        return;
    }
    NSString *text = [newest[@"text"] isKindOfClass:NSString.class] ? newest[@"text"] : @"";
    NSInteger role = [newest[@"role"] integerValue];
    if (role == 0 && text.length) ResetAnswer();
    SGDebug(@"caption from Siri.app role=%ld len=%lu", (long)role, (unsigned long)text.length);
    // Your words for a new turn (not Siri repeating the last ones): the last
    // turn's card leaves the glass now, and nothing older than this comes back.
    if (role == 0 && text.length && cardShown && lastUserText.length && ![text isEqualToString:lastUserText]) {
        SGDebug(@"new turn: the last card leaves the glass");
        SetHostAttachment(0, 0, 0);
        cardTurnAt = time;
    }
    SetHostCaption(text, role);
}

static void CaptionNotified(CFNotificationCenterRef center, void *observer, CFStringRef name,
                            const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{ ReadCaption(); });
}

/// Whether Siri is on screen, by SpringBoard's own account
/// (SBAssistantController) and by its window still showing. Either one
/// saying no is enough.
/// SBAssistantController's answer counts once it has said yes this session,
/// in case it means something slightly different on this iOS.
static BOOL controllerSawVisible = NO;

static BOOL AssistantVisible(void) {
    BOOL visible = YES;
    Class controller = NSClassFromString(@"SBAssistantController");
    SEL isVisible = NSSelectorFromString(@"isVisible");
    if ([controller respondsToSelector:isVisible]) {
        BOOL says = ((BOOL (*)(Class, SEL))objc_msgSend)(controller, isVisible);
        if (says) controllerSawVisible = YES;
        if (controllerSawVisible) visible = says;
    }
    UIView *orb = currentOrb;
    if (orb) {
        UIWindow *w = orb.window;
        if (!w || w.hidden || w.alpha < 0.01) visible = NO;
    }
    return visible;
}

/// Siri has gone, whatever its orb last said (leaving for an app, the lock
/// screen, a swipe away: the orb is not always told). Sends the drop home.
static CFAbsoluteTime endedAt = 0;

static void EndSiri(NSString *why) {
    if (!siriActive) return;
    SGDebug(@"Siri ended: %@", why);
    siriActive = NO;
    RefreshBackdropSoon();
    endedAt = CFAbsoluteTimeGetCurrent();
    // Siri's card leaves with Siri's window: no hole left onto the screen.
    if (cardShown) SetHostAttachment(0, 0, 0);
    Class host = NSClassFromString(@"SGHost");
    SEL sel = NSSelectorFromString(@"setState:");
    if ([host respondsToSelector:sel]) OnMain(^{ ((void (*)(Class, SEL, NSInteger))objc_msgSend)(host, sel, 0); });
    TrackIsland(NO);
}

static CFAbsoluteTime lastVisible = 0;

/// The watchdog, while Siri or its words are up: reads Siri.app's words
/// (in case a notification was missed), ends Siri once it has been off
/// screen for a moment, and takes the words away once Siri is gone (an
/// answer stays a few seconds to be read), so nothing is ever left out.
static void WatchCaption(void) {
    lastVisible = CFAbsoluteTimeGetCurrent();
    if (captionWatch) return;
    captionWatch = [NSTimer scheduledTimerWithTimeInterval:0.15 repeats:YES block:^(NSTimer *t) {
        ReadCaption();
        ReadCard();
        PumpCardLayout();
        PumpStatusBar();
        PumpBackdrop();
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (AssistantVisible()) lastVisible = now;
        if (siriActive) lastActive = CACurrentMediaTime();
        BOOL gone = now - lastVisible > 0.4;
        if (gone) EndSiri(@"not on screen");
        if (gone && cardShown) SetHostAttachment(0, 0, 0);
        // Nothing lasts for ever, whatever went wrong.
        BOOL stale = !siriActive && CACurrentMediaTime() - lastActive > 25;
        if (stale && captionShown) SGDebug(@"stale: clearing");
        if (captionShown && (gone || stale)) {
            // Siri closes itself a moment after it has spoken; its answer stays
            // up long enough to read (longer for a longer answer) and then goes.
            double readFor = MIN(MAX(1.2 + 0.08 * shownText.length, 2.5), 6.0);
            BOOL reading = !stale && shownRole == 1 && now - shownAt < readFor && now - lastVisible < 6.5;
            if (!reading) {
                SetHostCaption(nil, 0);
                SGDebug(@"Siri gone: words cleared");
            }
        }
        if (!captionShown && (gone || stale) && !siriActive) {
            [t invalidate];
            captionWatch = nil;
            // The status bar comes back with the glass as it folds (its own
            // follower runs till then, see PumpStatusBar), not before.
            HideOverlaySoon();
        }
    }];
}

// MARK: - SpringBoard: Siri's result card, set into the glass

static double cardTime = 0;
static CGRect lastLayout = {{-1, -1}, {0, 0}};

static void SetHostAttachment(double w, double h, double r) {
    Class host = NSClassFromString(@"SGHost");
    SEL sel = NSSelectorFromString(@"setAttachmentWidth:height:radius:");
    if (![host respondsToSelector:sel]) return;
    if (!cardShown && w > 1 && h > 1) { sbProbesLogged = 0; sbTouchesLogged = 0; }
    cardShown = w > 1 && h > 1;
    OnMain(^{ ((void (*)(Class, SEL, double, double, double))objc_msgSend)(host, sel, w, h, r); });
}

/// Siri.app's newest word on its card (this session only).
static void ReadCard(void) {
    if (!TweakEnabled()) return;
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kCardPath];
    double time = [d[@"time"] doubleValue];
    if (!d || time <= cardTime) return;
    cardTime = time;
    if (time < sessionStart - 0.5 || time < cardTurnAt) return;
    BOOL present = [d[@"present"] boolValue] && SGSiriBusy();
    SGDebug(@"card from Siri.app present=%d %.0fx%.0f", present, [d[@"w"] doubleValue], [d[@"h"] doubleValue]);
    if (present) SetHostAttachment([d[@"w"] doubleValue], [d[@"h"] doubleValue], [d[@"radius"] doubleValue]);
    else if (cardShown) SetHostAttachment(0, 0, 0);
}

static void CardNotified(CFNotificationCenterRef center, void *observer, CFStringRef name,
                         const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{ ReadCard(); });
}

/// Tells Siri.app where its card goes, whenever the glass's answer changes
/// (checked every frame while Siri is up).
static void PumpCardLayout(void) {
    Class host = NSClassFromString(@"SGHost");
    SEL sel = NSSelectorFromString(@"attachmentFrame");
    if (![host respondsToSelector:sel]) return;
    CGRect f = ((CGRect (*)(Class, SEL))objc_msgSend)(host, sel);
    if (fabs(f.origin.x - lastLayout.origin.x) < 0.5 && fabs(f.origin.y - lastLayout.origin.y) < 0.5 &&
        fabs(f.size.width - lastLayout.size.width) < 0.5 && fabs(f.size.height - lastLayout.size.height) < 0.5) return;
    // A file and a notification each: at most thirty a second while it moves
    // (Siri.app springs the card to each), straight away when it shows or goes.
    static CFAbsoluteTime writtenAt;
    BOOL showChanges = (f.size.width > 1) != (lastLayout.size.width > 1);
    if (!showChanges && CFAbsoluteTimeGetCurrent() - writtenAt < 1.0 / 30) return;
    writtenAt = CFAbsoluteTimeGetCurrent();
    lastLayout = f;
    double radius = 0;
    SEL rsel = NSSelectorFromString(@"attachmentCornerRadius");
    if ([host respondsToSelector:rsel]) radius = ((double (*)(Class, SEL))objc_msgSend)(host, rsel);
    BOOL show = f.size.width > 1 && f.size.height > 1;
    NSDictionary *d = @{@"show": @(show), @"x": @(f.origin.x), @"y": @(f.origin.y), @"w": @(f.size.width),
                        @"h": @(f.size.height), @"radius": @(radius), @"time": @(CFAbsoluteTimeGetCurrent())};
    [d writeToFile:kLayoutPath atomically:YES];
    notify_post(kLayoutNotification);
    static CFAbsoluteTime loggedAt;
    if (showChanges || writtenAt - loggedAt > 0.5) { loggedAt = writtenAt; SGDebug(@"card goes to %@ show=%d", NSStringFromCGRect(f), show); }
}

// MARK: - SpringBoard: the status bar makes way for the glass

// When the Dynamic Island expands, SpringBoard gives every status bar an
// "avoidance frame" and the items under it shrink, blur and fade away
// (SBSystemApertureViewController -_calculateStatusBarAvoidanceFrame,
// pushed by -_updateStatusBarAvoidanceFrameWithAnimationSettings:). The
// glass joins that: while it is out, its frame is added to the island's,
// so the status bar makes way for it exactly as for the island.
@interface SBSystemApertureViewController : UIViewController
- (void)_updateStatusBarAvoidanceFrameWithAnimationSettings:(id)settings;
@end

static __weak SBSystemApertureViewController *apertureController;
static CFAbsoluteTime glassAvoidAt = 0;

static SBSystemApertureViewController *ApertureController(void) {
    SBSystemApertureViewController *c = apertureController;
    if (c) return c;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (![NSStringFromClass(w.class) isEqualToString:@"SBSystemApertureWindow"]) continue;
        UIViewController *root = w.rootViewController;
        if ([root isKindOfClass:NSClassFromString(@"SBSystemApertureViewController")]) { apertureController = (id)root; return (id)root; }
        for (UIViewController *child in root.childViewControllers)
            if ([child isKindOfClass:NSClassFromString(@"SBSystemApertureViewController")]) { apertureController = (id)child; return (id)child; }
    }
    return nil;
}

/// The springs the status bar moves on. What the island hands it is an
/// SBFFluidBehaviorSettings (the status bar asks it for -BSAnimationSettings),
/// so the same kind, made here. A plain BSAnimationSettings has no such
/// method, and no spring for the items to shrink and fade along.
static id GlassSpring(double response, double dampingRatio) {
    Class cls = NSClassFromString(@"SBFFluidBehaviorSettings");
    if (!cls) return nil;
    id s = [cls alloc];
    SEL defaults = NSSelectorFromString(@"initWithDefaultValues");
    s = [s respondsToSelector:defaults] ? ((id (*)(id, SEL))objc_msgSend)(s, defaults) : [s init];
    SEL ratio = NSSelectorFromString(@"setDampingRatio:"), resp = NSSelectorFromString(@"setResponse:");
    if (![s respondsToSelector:ratio] || ![s respondsToSelector:resp]
        || ![s respondsToSelector:NSSelectorFromString(@"BSAnimationSettings")]) return nil;
    ((void (*)(id, SEL, double))objc_msgSend)(s, ratio, dampingRatio);
    ((void (*)(id, SEL, double))objc_msgSend)(s, resp, response);
    return s;
}

static void PumpStatusBar(void);

/// Moves the status bar every frame for as long as it is out of the glass's
/// way, whoever else is running (the island tracker stops 1.5 s after Siri,
/// the watchdog when the words go, while the glass is still folding).
@interface SGStatusBarFollower : NSObject
@property (nonatomic, strong) CADisplayLink *link;
- (void)tick:(CADisplayLink *)link;
@end

@implementation SGStatusBarFollower
- (void)tick:(CADisplayLink *)link {
    PumpStatusBar();
    if (CGRectIsEmpty(glassAvoid)) { [link invalidate]; self.link = nil; }
}
@end

static SGStatusBarFollower *statusBarFollower;

static void FollowGlass(void) {
    if (!statusBarFollower) statusBarFollower = [SGStatusBarFollower new];
    if (statusBarFollower.link) return;
    statusBarFollower.link = [CADisplayLink displayLinkWithTarget:statusBarFollower selector:@selector(tick:)];
    [statusBarFollower.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

static void ApplyGlassAvoidance(CGRect avoid) {
    BOOL giveBack = CGRectIsEmpty(avoid);
    if (!giveBack) FollowGlass();
    glassAvoid = avoid;
    glassAvoidAt = CFAbsoluteTimeGetCurrent();
    SBSystemApertureViewController *c = ApertureController();
    if (![c respondsToSelector:@selector(_updateStatusBarAvoidanceFrameWithAnimationSettings:)]) {
        static BOOL said;
        if (!said) { said = YES; SGDebug(@"status bar: no aperture controller"); }
        return;
    }
    // Following the glass: critically damped and quick, so each new edge
    // takes over from where the items are (the status bar animates from
    // their current state). Giving the room back: the island's own feel.
    static id follow, release;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        follow = GlassSpring(0.32, 1.0);
        release = GlassSpring(0.45, 0.9);
        if (!follow || !release) SGDebug(@"status bar: no fluid spring settings, moving without animation");
    });
    @try { [c _updateStatusBarAvoidanceFrameWithAnimationSettings:giveBack ? release : follow]; }
    @catch (NSException *e) { SGDebug(@"status bar: %@", e.reason); }
    static CFAbsoluteTime lastLogged;
    if (giveBack || glassAvoidAt - lastLogged > 0.5) {
        lastLogged = glassAvoidAt;
        SGDebug(@"status bar avoids %@", NSStringFromCGRect(avoid));
    }
}

/// Run every frame while Siri is up (the island tracker's display link, and
/// the watchdog): keeps the status bar out of the glass as it is drawn now,
/// the way it gives way to the island while that grows. As the glass widens
/// the items shrink, then go one by one; as it folds they come back the
/// same way.
static void PumpStatusBar(void) {
    Class host = NSClassFromString(@"SGHost");
    SEL sel = NSSelectorFromString(@"captionGlassNow");
    CGRect g = [host respondsToSelector:sel] ? ((CGRect (*)(Class, SEL))objc_msgSend)(host, sel) : CGRectZero;
    BOOL want = TweakEnabled() && g.size.width > 1 && g.size.height > 1;
    // The glass folds within about a second of Siri and its words going; if
    // it is somehow still there long after, the status bar comes back anyway.
    static CFAbsoluteTime idleSince;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (SGSiriBusy()) idleSince = 0;
    else if (!idleSince) idleSince = now;
    if (want && idleSince && now - idleSince > 2.5) want = NO;
    // The status bar only cares how far across the glass reaches.
    CGRect avoid = want ? CGRectMake(g.origin.x, 0, g.size.width, MAX(CGRectGetMaxY(g), 54)) : CGRectZero;
    BOOL had = !CGRectIsEmpty(glassAvoid);
    if (!want && !had) return;
    if (want && had) {
        if (fabs(avoid.origin.x - glassAvoid.origin.x) < 2 && fabs(avoid.size.width - glassAvoid.size.width) < 4) return;
        // About twelve steps a second, each retargeting the spring (every
        // step reaches every app's status bar, so not every frame).
        if (CFAbsoluteTimeGetCurrent() - glassAvoidAt < 1.0 / 12) return;
    }
    ApplyGlassAvoidance(avoid);
}

/// The orb's mode, unless it is a last word from a Siri that has already
/// gone (its orb is sometimes set going again as Siri closes).
static CFAbsoluteTime controllerShownAt = 0;   // SpringBoard last put Siri on screen

static long long EffectiveMode(long long mode) {
    if (StateForMode(mode) != 0 && CFAbsoluteTimeGetCurrent() - endedAt < 1.5 && !AssistantVisible()) {
        SGDebug(@"ignored mode %lld: Siri already gone", mode);
        return 0;
    }
    return mode;
}

BOOL SGSiriBusy(void) { return siriActive || captionShown || captionWatch != nil; }

static __weak id aceConnection;   // the AFConnection seen last, in this process

/// Siri itself is on screen (listening, or showing its answer).
BOOL SGSiriListening(void) { return siriActive && AssistantVisible(); }

/// You sent the glass away (a swipe up, a tap once Siri has gone, the
/// phone locking): everything stops now. Siri if it is still up, its card,
/// the words; the glass folds home.
static void DismissByUser(NSString *why) {
    if (!SGSiriBusy()) return;
    SGDebug(@"dismissed: %@", why);
    BOOL siriUp = SGSiriListening();
    if (cardShown) SetHostAttachment(0, 0, 0);
    if (captionShown) SetHostCaption(nil, 0);
    // Anything Siri.app says from here on belongs to the Siri just sent away.
    lastCaptionTime = MAX(lastCaptionTime, CFAbsoluteTimeGetCurrent());
    if (siriUp) {
        @try { [aceConnection stopSpeech]; } @catch (NSException *e) {}
        Class c = NSClassFromString(@"SBAssistantController");
        SEL shared = NSSelectorFromString(@"sharedInstanceIfExists");
        id controller = [c respondsToSelector:shared] ? ((id (*)(Class, SEL))objc_msgSend)(c, shared) : nil;
        SEL dismiss = NSSelectorFromString(@"dismissAssistantViewInEverySceneIfNecessary");
        if ([controller respondsToSelector:dismiss]) ((void (*)(id, SEL))objc_msgSend)(controller, dismiss);
    }
    EndSiri(why);
}

static void LockNotified(CFNotificationCenterRef center, void *observer, CFStringRef name,
                         const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{ DismissByUser(@"the phone locked"); });
}

/// A new Siri session: forget the last one's words.
static void BeginSession(void) {
    sessionStart = CFAbsoluteTimeGetCurrent();
    backdropChecked = NO;
    // The drop may still be out from the last time, over another app.
    RefreshBackdropSoon();
    ResetAnswer();
    lastUserText = nil;
    controllerSawVisible = NO;
    SGDebug(@"session begins");
    if (captionShown) SetHostCaption(nil, 0);
    WatchCaption();
}

%group SpringBoardHooks

// Where touches go while Siri's card is in the glass (a few per card): which
// windows the window server asks, what they answer, and who gets the touch.
%hook UIWindow
- (UIView *)_hitTest:(CGPoint)point withEvent:(UIEvent *)event windowServerHitTestWindow:(UIWindow *)window {
    UIView *result = %orig;
    if (cardShown && sbProbesLogged < 16) {
        sbProbesLogged++;
        SGDebug(@"server asks %@ (level %.0f) at %@ -> %@", NSStringFromClass(self.class), self.windowLevel,
                NSStringFromCGPoint(point), result ? NSStringFromClass(result.class) : @"nil");
    }
    return result;
}
%end

%hook UIApplication
- (void)sendEvent:(UIEvent *)event {
    if (cardShown && sbTouchesLogged < 8 && event.type == UIEventTypeTouches) {
        for (UITouch *t in event.allTouches) {
            if (t.phase != UITouchPhaseBegan || sbTouchesLogged >= 8) continue;
            sbTouchesLogged++;
            SGDebug(@"SpringBoard got a touch at %@ in %@ -> %@", NSStringFromCGPoint([t locationInView:nil]),
                    NSStringFromClass(t.window.class), NSStringFromClass(t.view.class));
        }
    }
    %orig;
}
%end

%hook SBSystemApertureViewController
- (void)viewDidLoad {
    %orig;
    apertureController = self;
}
- (CGRect)_calculateStatusBarAvoidanceFrame {
    CGRect r = %orig;
    if (CGRectIsEmpty(glassAvoid) || !TweakEnabled()) return r;
    return CGRectIsEmpty(r) ? glassAvoid : CGRectUnion(r, glassAvoid);
}
%end

// SpringBoard's own word that Siri is (no longer) on screen: the first and
// quickest way the drop learns it should go home.
%hook SBAssistantController
- (void)_setVisible:(BOOL)visible {
    %orig;
    SGDebug(@"SBAssistantController visible=%d", visible);
    if (visible) controllerShownAt = CFAbsoluteTimeGetCurrent();
    if (!visible) dispatch_async(dispatch_get_main_queue(), ^{ EndSiri(@"SBAssistantController hidden"); });
}
// Every way SpringBoard sends Siri away, including handing over to an app
// (a "punchout": "open Settings").
- (void)siriPresentation:(id)presentation requestsPunchout:(id)punchout withHandler:(id)handler {
    %orig;
    SGDebug(@"Siri punchout");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ EndSiri(@"punchout"); });
}
- (void)siriPresentation:(id)presentation requestsDismissalWithOptions:(id)options withHandler:(id)handler {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{ EndSiri(@"presentation asked to dismiss"); });
}
- (void)_dismissAssistantViewIfNecessaryWithAnimation:(long long)animation factory:(id)factory dismissalOptions:(id)options windowScene:(id)scene completion:(id)completion {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{ EndSiri(@"dismissAssistantView"); });
}
- (void)dismissAssistantViewInEverySceneIfNecessaryWithAnimation:(long long)animation factory:(id)factory completion:(id)completion {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{ EndSiri(@"dismissAssistantView (every scene)"); });
}
%end

%hook SUICOrbView

- (void)setMode:(long long)mode {
    %orig;
    currentOrb = self;
    mode = EffectiveMode(mode);
    BOOL wasActive = siriActive;
    siriActive = StateForMode(mode) != 0;
    // The orb going quiet is an end too (for the flicker check above).
    if (wasActive && !siriActive) endedAt = CFAbsoluteTimeGetCurrent();
    if (siriActive && !wasActive && TweakEnabled()) BeginSession();
    if (!TweakEnabled()) { RestoreOldSiri(self); DetachHost(); return; }
    // The island first, so the drop's very first frame already fits it.
    BOOL active = siriActive;
    if (NSThread.isMainThread) TrackIsland(active);
    else dispatch_async(dispatch_get_main_queue(), ^{ TrackIsland(active); });
    Push(self, mode);
}

- (void)_setMode:(long long)mode {
    %orig;
    currentOrb = self;
    mode = EffectiveMode(mode);
    BOOL wasActive = siriActive;
    siriActive = StateForMode(mode) != 0;
    // The orb going quiet is an end too (for the flicker check above).
    if (wasActive && !siriActive) endedAt = CFAbsoluteTimeGetCurrent();
    if (siriActive && !wasActive && TweakEnabled()) BeginSession();
    if (!TweakEnabled()) { RestoreOldSiri(self); DetachHost(); return; }
    Push(self, mode);
}

- (void)setPower:(float)power {
    %orig;
    if (!TweakEnabled()) return;
    Class host = SGHost();
    if (host) OnMain(^{ ((void (*)(Class, SEL, float))objc_msgSend)(host, NSSelectorFromString(@"setPower:"), power); });
}

- (void)setPowerLevel:(float)power {
    %orig;
    if (!TweakEnabled()) return;
    Class host = SGHost();
    if (host) OnMain(^{ ((void (*)(Class, SEL, float))objc_msgSend)(host, NSSelectorFromString(@"setPower:"), power); });
}

- (void)didMoveToWindow {
    %orig;
    if (!self.window) return;
    currentOrb = self;
    if (!TweakEnabled()) { RestoreOldSiri(self); return; }
    HideOldSiri(self);
    Class host = SGHost();
    if (host) EnsureAttach(self.window, 60);
}

// The orb stays, as the source of Siri's state, but is not drawn. A hair
// above zero keeps it hit-testable, so tapping where it was still works.
- (void)setAlpha:(CGFloat)alpha {
    if (!TweakEnabled()) {
        %orig;
    } else {
        %orig(0.011);
        HideOldSiri(self);
    }
}

- (void)setHidden:(BOOL)hidden {
    if (!TweakEnabled()) {
        %orig;
    } else {
        %orig(NO);
    }
}

%end

// The island's own view. Install the swipe once per view; live activities
// create new container views, and each one gets its own recognizer.
%hook SBSystemApertureContainerView

- (void)didMoveToWindow {
    %orig;
    SGDebug(@"aperture didMoveToWindow window=%@", self.window);
    if (self.window) InstallSiriGesture(self);
}

%end

%end   // SpringBoardHooks

// MARK: - Siri.app: take the words, hide them at the bottom

@interface SiriSharedUICompactConversationView : UIView
- (NSArray *)conversationSnippetViews;
@end
@interface SiriSharedUICompactUserUtteranceView : UIView
@end
@interface SiriSharedUICompactServerUtteranceView : UIView
@end
@interface SiriSharedUICompactView : UIView
@end

static NSString *lastSentText;
static NSInteger lastSentRole = -1;
static void RetireCard(NSString *why);
/// Your newest words, and the words of the turn the card on the glass
/// belongs to (Siri says them once more with its answer: same turn).
static NSString *heardWords;
static NSString *cardTurnWords;
/// When Siri's answer last came from its commands: the answer view's text
/// then only fills in if the commands had none.
static CFAbsoluteTime aceAnsweredAt = 0;

/// A small log Siri.app can write (its sandbox allows this directory), for
/// reading over SSH: which commands came, what text was taken.
static void SiriLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void SiriLog(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    if (!DebugLogging()) return;
    NSLog(@"[SiriGlass] %@", line);
    NSString *path = @"/var/mobile/Library/Logs/CrashReporter/Assistant/CardLogs/siriglass-siri.log";
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    if ([attrs fileSize] > 256 * 1024) [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    FILE *f = fopen(path.UTF8String, "a");
    if (f) { fprintf(f, "%.3f %s\n", CFAbsoluteTimeGetCurrent(), line.UTF8String); fclose(f); }
}

static void SendCaption(NSString *text, NSInteger role) {
    if (!TweakEnabled()) return;
    text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    if (role == lastSentRole && [text isEqualToString:lastSentText ?: @""]) return;
    // Siri hands over your words once more, final, right after its answer:
    // the same words, not a new question. Keep the answer up.
    static NSString *lastUserWords;
    if (role == 0 && text.length && lastSentRole == 1 && [text isEqualToString:lastUserWords ?: @""]) return;
    if (role == 0) lastUserWords = text.length ? text : nil;
    // Your words again, after a card: a new turn, and the card was the last
    // turn's. Siri empties it without taking it off the glass's stage.
    if (role == 0 && text.length && ![text isEqualToString:cardTurnWords ?: @""]) RetireCard(@"you started a new turn");
    if (role == 0 && text.length) heardWords = text;
    lastSentText = text;
    lastSentRole = role;
    if (role == 0 && text.length) { ResetAnswer(); aceAnsweredAt = 0; }
    SiriLog(@"send role=%ld len=%lu", (long)role, (unsigned long)text.length);
    NSDictionary *d = @{@"text": text, @"role": @(role), @"time": @(CFAbsoluteTimeGetCurrent())};
    BOOL wrote = NO;
    for (NSString *path in CaptionPaths()) {
        [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                                withIntermediateDirectories:NO attributes:nil error:nil];
        if ([d writeToFile:path atomically:YES]) { wrote = YES; break; }
    }
    if (!wrote) Log(@"caption: no writable path");
    notify_post(kCaptionNotification);
}

/// Siri's answer, as its labels show it now.
static NSString *ServerText(UIView *view, id utterances) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSArray *labels = nil;
    @try { labels = [view valueForKey:@"_serverLabels"]; } @catch (NSException *e) {}
    SEL textFor = NSSelectorFromString(@"_textForLabel:");
    for (id label in labels) {
        id t = [view respondsToSelector:textFor] ? ((id (*)(id, SEL, id))objc_msgSend)(view, textFor, label) : nil;
        NSString *s = TextOf(t) ?: TextOf(label);
        if (s.length) [parts addObject:s];
    }
    if (!parts.count && [utterances isKindOfClass:NSArray.class])
        for (id u in utterances) { NSString *s = TextOf(u); if (s.length) [parts addObject:s]; }
    return [parts componentsJoinedByString:@" "];
}

static void HideWords(UIView *v) {
    if (TweakEnabled() && v.alpha > 0) v.alpha = 0;
}

static void SiriPreferencesChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                   const void *object, CFDictionaryRef userInfo) {
    InvalidateEnabledCache();
}

// MARK: Siri.app: its result card, moved into the glass

@interface SiriSharedUICompactResultView : UIView
- (UIView *)snippetView;
@end

static __weak UIView *resultView;
static CGSize reportedCardSize;
static BOOL reportedCard = NO;
static CFAbsoluteTime cardReportedAt = 0;
static NSDictionary *cardLayout;
static int touchesLogged = 0;
static int serverProbesLogged = 0;
/// The card of a turn that is over, and what it held then: not to come
/// back unless Siri fills it with something new.
static __weak UIView *retiredCard;
static __weak UIView *retiredSnippet;

/// The card under a touch at `point` (in `root`), when the card is in its
/// place in the glass and the touch is inside that place.
static UIView *CardHit(UIView *root, CGPoint point, UIEvent *event) {
    UIView *card = resultView;
    if (!card || !TweakEnabled() || card.window != root.window || card.hidden || card.alpha < 0.5) return nil;
    NSDictionary *l = cardLayout;
    if (![l[@"show"] boolValue]) return nil;
    CGRect place = CGRectMake([l[@"x"] doubleValue], [l[@"y"] doubleValue], [l[@"w"] doubleValue], [l[@"h"] doubleValue]);
    CGPoint inWindow = root.window == root ? point : [root convertPoint:point toView:nil];
    if (!CGRectContainsPoint(place, inWindow)) return nil;
    CGPoint p = [card convertPoint:inWindow fromView:nil];
    return [card hitTest:p withEvent:event] ?: card;
}
/// Our own changes to the card's alpha get through; Siri's do not while
/// the card is ours.
static BOOL placingCard = NO;

/// The card itself (its platter) inside the result view.
static UIView *CardPlatter(UIView *result) {
    UIView *snippet = [result respondsToSelector:@selector(snippetView)] ? [(SiriSharedUICompactResultView *)result snippetView] : nil;
    return snippet.bounds.size.height > 1 ? snippet : result;
}

static double CardRadius(UIView *platter) {
    UIView *pl = nil;
    @try { pl = [platter valueForKey:@"platterView"]; } @catch (NSException *e) {}
    double r = [pl isKindOfClass:UIView.class] ? pl.layer.cornerRadius : platter.layer.cornerRadius;
    return r > 1 ? r : 22;
}

static void PlaceCard(UIView *result);

/// Tells SpringBoard the card is here (and how big), or gone.
static void ReportCard(UIView *result) {
    if (!TweakEnabled()) return;
    UIView *platter = result ? CardPlatter(result) : nil;
    CGSize size = platter.bounds.size;
    BOOL present = result.window && !result.hidden && size.width > 50 && size.height > 20;
    // A card Siri has emptied (its snippet gone), or one from a turn that
    // is over, is no card.
    if (present && [result respondsToSelector:@selector(snippetView)]) {
        UIView *snippet = [(SiriSharedUICompactResultView *)result snippetView];
        if (!snippet || !snippet.window || snippet.hidden) present = NO;
    }
    if (present && retiredCard && result == retiredCard) {
        UIView *snippet = [result respondsToSelector:@selector(snippetView)] ? [(SiriSharedUICompactResultView *)result snippetView] : nil;
        if (!snippet || snippet == retiredSnippet) present = NO;
    }
    if (present == reportedCard && (!present || (fabs(size.width - reportedCardSize.width) < 0.5 &&
                                                  fabs(size.height - reportedCardSize.height) < 0.5))) return;
    if (present && !reportedCard) cardTurnWords = heardWords;
    reportedCard = present;
    reportedCardSize = size;
    if (present) { touchesLogged = 0; serverProbesLogged = 0; }
    cardReportedAt = CFAbsoluteTimeGetCurrent();
    NSDictionary *d = @{@"present": @(present), @"w": @(size.width), @"h": @(size.height),
                        @"radius": @(present ? CardRadius(platter) : 0), @"time": @(cardReportedAt)};
    [d writeToFile:kCardPath atomically:YES];
    notify_post(kCardNotification);
    SiriLog(@"card %@ %.0fx%.0f", present ? @"here" : @"gone", size.width, size.height);
    // If SpringBoard never finds it a place, Siri's card shows as Siri put it.
    if (present) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        PlaceCard(resultView);
    });
}

static void SetCardAlpha(UIView *result, CGFloat alpha, NSTimeInterval duration) {
    if (fabs(result.alpha - alpha) < 0.001) return;
    void (^change)(void) = ^{ placingCard = YES; result.alpha = alpha; placingCard = NO; };
    if (duration > 0) [UIView animateWithDuration:duration delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:change completion:nil];
    else change();
}

/// Puts the card where SpringBoard's glass made room for it: the whole
/// result view moves (its tap target with it), scaled so its platter lands
/// exactly on the room. Its look is left alone. Until there is a place,
/// it stays out of sight; if none comes, it is shown where Siri put it.
/// A view of ours in Siri's window, exactly where the glass made room for
/// the card, and the card moved into it. Moving the card there with only a
/// transform looked right but touches never reached it: the system sends a
/// touch to Siri only where Siri's views are, and the containers the card
/// sat in stayed near the bottom of the screen. On this stage the card is
/// where it looks to be, so its lists scroll and its rows and buttons work.
@interface SGCardStage : UIView
@end

@implementation SGCardStage
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;
}
- (UIView *)_hitTest:(CGPoint)point withEvent:(UIEvent *)event windowServerHitTestWindow:(UIWindow *)window {
    return [self hitTest:point withEvent:event];
}
@end

static SGCardStage *cardStage;
/// Where Siri keeps the card, to put it back if the glass never takes it.
static __weak UIView *cardHome;
static NSUInteger cardHomeIndex = 0;
static BOOL cardHomeArranged = NO;
static CGRect cardHomeFrame;
static NSTimer *cardHomeWatch;

static BOOL CardOnStage(UIView *result) { return result && cardStage && result.superview == cardStage; }

/// Siri took the card's place away (a new answer, Siri leaving) while the
/// card was on our stage: the card goes too, never left behind.
static void WatchCardHome(void) {
    if (cardHomeWatch) return;
    cardHomeWatch = [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *t) {
        UIView *home = cardHome;
        NSArray<UIView *> *onStage = cardStage.subviews;
        if (!onStage.count) { [t invalidate]; cardHomeWatch = nil; return; }
        if (home && home.window) return;
        SiriLog(@"card's place in Siri went: card goes too");
        for (UIView *v in onStage) [v removeFromSuperview];
        cardStage.hidden = YES;
        ReportCard(nil);
        [t invalidate];
        cardHomeWatch = nil;
    }];
}

static void ReturnCardHome(UIView *result) {
    if (!CardOnStage(result)) { result.transform = CGAffineTransformIdentity; return; }
    UIView *home = cardHome;
    result.transform = CGAffineTransformIdentity;
    if (!home.window) { [result removeFromSuperview]; return; }
    if (cardHomeArranged && [home isKindOfClass:UIStackView.class])
        [(UIStackView *)home insertArrangedSubview:result atIndex:MIN(cardHomeIndex, ((UIStackView *)home).arrangedSubviews.count)];
    else
        [home insertSubview:result atIndex:MIN(cardHomeIndex, home.subviews.count)];
    result.frame = cardHomeFrame;
    SiriLog(@"card back where Siri put it");
}

static void MoveCardToStage(UIView *result) {
    UIWindow *w = result.window;
    if (!w || CardOnStage(result)) return;
    UIView *home = result.superview;
    cardHome = home;
    cardHomeIndex = [home.subviews indexOfObject:result];
    cardHomeArranged = [home isKindOfClass:UIStackView.class] && [((UIStackView *)home).arrangedSubviews containsObject:result];
    CGAffineTransform t = result.transform;
    result.transform = CGAffineTransformIdentity;
    cardHomeFrame = result.frame;
    CGRect bounds = result.bounds;
    SiriLog(@"card moves to the glass from %@ in %@ (%@)", NSStringFromCGRect([home convertRect:cardHomeFrame toView:nil]),
            NSStringFromClass(home.class), cardHomeArranged ? @"arranged" : @"subview");
    [cardStage addSubview:result];
    result.translatesAutoresizingMaskIntoConstraints = YES;
    result.autoresizingMask = UIViewAutoresizingNone;
    result.bounds = bounds;
    result.transform = t;
    WatchCardHome();
}

/// Puts the card where SpringBoard's glass made room for it, scaled so its
/// platter lands exactly on the room. Its look is left alone. Until there
/// is a place, it stays out of sight; if none comes, it is shown where
/// Siri put it.
static void PlaceCard(UIView *result) {
    if (!result || !TweakEnabled()) return;
    if (!result.window) return;
    NSDictionary *l = cardLayout;
    BOOL show = [l[@"show"] boolValue] && [l[@"time"] doubleValue] >= cardReportedAt - 0.05 && reportedCard;
    if (!show) {
        if (CFAbsoluteTimeGetCurrent() - cardReportedAt > 1.5 && reportedCard && ![l[@"show"] boolValue]) {
            // SpringBoard never answered: Siri's own card, where Siri put it.
            ReturnCardHome(result);
            cardStage.hidden = YES;
            SetCardAlpha(result, 1, 0.2);
        } else {
            SetCardAlpha(result, 0, 0.12);
            // Out of the way of touches once it is out of sight.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (resultView.alpha < 0.01) cardStage.hidden = YES;
            });
        }
        return;
    }
    UIView *platter = CardPlatter(result);
    if (platter.bounds.size.width < 1) return;
    CGRect target = CGRectMake([l[@"x"] doubleValue], [l[@"y"] doubleValue], [l[@"w"] doubleValue], [l[@"h"] doubleValue]);
    UIWindow *w = result.window;
    if (!cardStage) cardStage = [SGCardStage new];
    cardStage.backgroundColor = UIColor.clearColor;
    cardStage.clipsToBounds = NO;
    CGRect stageFrame = [w convertRect:target fromWindow:nil];
    BOOL settled = CardOnStage(result) && result.alpha > 0.01 && !cardStage.hidden;
    if (!settled) cardStage.frame = stageFrame;
    cardStage.hidden = NO;
    if (cardStage.superview != w) [w addSubview:cardStage];
    else if (w.subviews.lastObject != cardStage) [w bringSubviewToFront:cardStage];
    if (!CardOnStage(result)) {
        // Not in the middle of the card's own layout pass.
        dispatch_async(dispatch_get_main_queue(), ^{
            if (resultView != result || CardOnStage(result) || !result.window) return;
            MoveCardToStage(result);
            PlaceCard(result);
        });
        return;
    }
    CGRect inResult = [platter convertRect:platter.bounds toView:result];
    CGPoint offset = CGPointMake(CGRectGetMidX(inResult) - CGRectGetMidX(result.bounds),
                                 CGRectGetMidY(inResult) - CGRectGetMidY(result.bounds));
    CGFloat k = target.size.width / platter.bounds.size.width;
    CGAffineTransform t = CGAffineTransformMakeScale(k, k);
    CGPoint centre = CGPointMake(target.size.width / 2 - k * offset.x, target.size.height / 2 - k * offset.y);
    BOOL wasHidden = result.alpha < 0.01;
    if (!CGAffineTransformEqualToTransform(result.transform, t) || !CGPointEqualToPoint(result.center, centre)
        || !CGRectEqualToRect(cardStage.frame, stageFrame)) {
        void (^move)(void) = ^{ cardStage.frame = stageFrame; result.transform = t; result.center = centre; };
        if (wasHidden) move();
        else [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.86 initialSpringVelocity:0
                                 options:UIViewAnimationOptionBeginFromCurrentState animations:move completion:nil];
    }
    SetCardAlpha(result, 1, 0.22);
}

/// The card goes from the glass for good: a new turn has begun (Siri
/// empties the old card in place rather than removing it, which left its
/// room standing blank in the glass).
static void RetireCard(NSString *why) {
    UIView *result = resultView;
    if (!result || !reportedCard) return;
    if (result == retiredCard) return;
    retiredCard = result;
    retiredSnippet = [result respondsToSelector:@selector(snippetView)] ? [(SiriSharedUICompactResultView *)result snippetView] : nil;
    SiriLog(@"card retired: %@", why);
    ReportCard(result);   // now "gone"
    SetCardAlpha(result, 0, 0.15);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.16 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (resultView.alpha < 0.01 || resultView != result) cardStage.hidden = YES;
    });
}

static void LayoutNotified(CFNotificationCenterRef center, void *observer, CFStringRef name,
                           const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        cardLayout = [NSDictionary dictionaryWithContentsOfFile:kLayoutPath];
        // Logged when it shows or goes, and at most twice a second while it moves.
        static BOOL loggedShow;
        static CFAbsoluteTime loggedAt;
        BOOL show = [cardLayout[@"show"] boolValue];
        if (show != loggedShow || CFAbsoluteTimeGetCurrent() - loggedAt > 0.5) {
            loggedShow = show;
            loggedAt = CFAbsoluteTimeGetCurrent();
            SiriLog(@"layout show=%@ %@,%@ %@x%@", cardLayout[@"show"], cardLayout[@"x"], cardLayout[@"y"], cardLayout[@"w"], cardLayout[@"h"]);
        }
        PlaceCard(resultView);
    });
}

%group SiriHooks

// What you said, as Siri hears it.
%hook SiriSharedUICompactUserUtteranceView
- (void)_setStreamingText:(id)text {
    %orig;
    SendCaption(TextOf(text), 0);
    HideWords(self);
}
- (void)layoutSubviews {
    %orig;
    HideWords(self);
}
- (void)didMoveToWindow {
    %orig;
    HideWords(self);
}
- (void)setAlpha:(CGFloat)alpha {
    if (!TweakEnabled()) {
        %orig;
    } else {
        %orig(0.0);
    }
}
%end

// Siri's answer.
%hook SiriSharedUICompactServerUtteranceView
- (void)setUtterances:(id)utterances {
    %orig;
    NSString *t = ServerText(self, utterances);
    SiriLog(@"server utterance view: %lu items, text len %lu", (unsigned long)[utterances count], (unsigned long)t.length);
    if (CFAbsoluteTimeGetCurrent() - aceAnsweredAt > 20 && t.length) SendCaption(t, 1);
    HideWords(self);
}
- (void)_setTextForLabel:(id)label text:(id)text {
    %orig;
    NSString *t = ServerText(self, nil);
    if (CFAbsoluteTimeGetCurrent() - aceAnsweredAt > 20 && t.length) SendCaption(t, 1);
}
- (void)layoutSubviews {
    %orig;
    HideWords(self);
}
- (void)didMoveToWindow {
    %orig;
    HideWords(self);
}
- (void)setAlpha:(CGFloat)alpha {
    if (!TweakEnabled()) {
        %orig;
    } else {
        %orig(0.0);
    }
}
%end

// With the words gone, the platter they sat on is empty unless it holds a
// card (weather, a calendar…): hide it then, and its grabber.
%hook SiriSharedUICompactConversationView
- (void)layoutSubviews {
    %orig;
    if (!TweakEnabled()) return;
    NSArray *cards = [self respondsToSelector:@selector(conversationSnippetViews)] ? [self conversationSnippetViews] : nil;
    CGFloat a = cards.count ? 1 : 0;
    for (NSString *key in @[@"_platterView", @"_grabberView"]) {
        UIView *v = nil;
        @try { v = [self valueForKey:key]; } @catch (NSException *e) {}
        if ([v isKindOfClass:UIView.class] && v.alpha != a) v.alpha = a;
    }
}
%end

// Siri's compact view leaving the screen: Siri is gone, and so are its
// words and its card. SpringBoard takes this as Siri having gone, too (it
// is not always told otherwise: leaving for Settings, say).
%hook SiriSharedUICompactView
- (void)didMoveToWindow {
    %orig;
    if (!self.window) {
        lastSentText = nil; lastSentRole = -1;
        SendCaption(@"", 0);
        if (TweakEnabled()) {
            NSDictionary *d = @{@"text": @"", @"role": @0, @"gone": @YES, @"time": @(CFAbsoluteTimeGetCurrent())};
            [d writeToFile:CaptionPaths().firstObject atomically:YES];
            notify_post(kCaptionNotification);
        }
        ReportCard(nil);
    }
}
%end

// A card in the glass is the same view, moved with a transform. Touches on
// it must still reach it: the containers it sat in did not move, and their
// bounds no longer cover where it is, so UIKit would give up on the way
// down and Siri's root (AFUITouchPassThroughView) would let the touch fall
// through to nothing. Inside the card's place in the glass, the card gets
// the touch directly, and its lists scroll and its rows and buttons work.
%hook AFUITouchPassThroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = CardHit(self, point, event);
    return hit ?: %orig;
}
%end

%hook UIWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *card = resultView;
    UIView *hit = card && card.window == self ? CardHit(self, point, event) : nil;
    return hit ?: %orig;
}
// The window server's own question (it may not go through -hitTest:).
- (UIView *)_hitTest:(CGPoint)point withEvent:(UIEvent *)event windowServerHitTestWindow:(UIWindow *)window {
    UIView *card = resultView;
    UIView *hit = card && card.window == self ? CardHit(self, point, event) : nil;
    UIView *result = hit ?: %orig;
    if (card && reportedCard && serverProbesLogged < 8) {
        serverProbesLogged++;
        SiriLog(@"server asks %@ at %@ -> %@%@", NSStringFromClass(self.class), NSStringFromCGPoint(point),
                NSStringFromClass(result.class), hit ? @" (card)" : @"");
    }
    return result;
}
- (void)sendEvent:(UIEvent *)event {
    %orig;
    // Where touches go while a card is in the glass (a few per card), in
    // any of Siri's windows.
    UIView *card = resultView;
    if (!card || !reportedCard || event.type != UIEventTypeTouches) return;
    for (UITouch *t in event.allTouches) {
        if (t.phase != UITouchPhaseBegan || touchesLogged >= 8) continue;
        touchesLogged++;
        SiriLog(@"touch at %@ in %@ -> %@ (card %@)", NSStringFromCGPoint([t locationInView:nil]), NSStringFromClass(self.class),
                NSStringFromClass(t.view.class), [t.view isDescendantOfView:card] ? @"yes" : @"no");
    }
}
%end

// Siri's result card (weather, a calendar, music…): into the glass.
%hook SiriSharedUICompactResultView
- (void)layoutSubviews {
    %orig;
    if (!TweakEnabled()) return;
    resultView = self;
    ReportCard(self);
    PlaceCard(self);
}
- (void)didMoveToWindow {
    %orig;
    if (!TweakEnabled()) return;
    if (self.window) {
        resultView = self;
        // Out of sight until it has its place in the glass.
        if (!reportedCard) SetCardAlpha(self, 0, 0);
        ReportCard(self);
        PlaceCard(self);
    } else if (resultView == self) {
        ReportCard(nil);
    }
}
- (void)setAlpha:(CGFloat)alpha {
    if (!TweakEnabled() || placingCard) {
        %orig;
    } else {
        // Siri fades its card in and out by itself; while the card is in the
        // glass, the glass decides.
        %orig(self.alpha);
    }
}
%end

%end   // SiriHooks

// Siri's answer from its commands, in whichever process receives them.
static BOOL inSiriApp = NO;

%group AceHooks
%hook AFConnection
- (void)_handleCommand:(id)command reply:(id)reply {
    %orig;
    aceConnection = self;
    if (!TweakEnabled()) return;
    @try {
        NSString *cls = NSStringFromClass([command class]);
        NSString *answer = AnswerFromCommand(command);
        if (inSiriApp && ([cls hasPrefix:@"SAUI"] || answer))
            SiriLog(@"command %@%@", cls, answer ? [NSString stringWithFormat:@" answer len %lu", (unsigned long)answer.length] : @"");
        if (!answer) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *full = AppendAnswer(answer);
            if (!full) return;
            if (inSiriApp) {
                aceAnsweredAt = CFAbsoluteTimeGetCurrent();
                SendCaption(full, 1);
            } else {
                SGDebug(@"answer from SpringBoard's AFConnection len=%lu", (unsigned long)full.length);
                if (SGSiriBusy()) SetHostCaption(full, 1);
            }
        });
    } @catch (NSException *e) {
        Log(@"answer: %@", e.reason);
    }
}
%end
%end

static void SpringBoardInit(void);

%ctor {
    @autoreleasepool {
        if ([NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.siri"]) {
            dlopen("/System/Library/PrivateFrameworks/SiriSharedUI.framework/SiriSharedUI", RTLD_NOW);
            dlopen("/System/Library/PrivateFrameworks/AssistantServices.framework/AssistantServices", RTLD_NOW);
            inSiriApp = YES;
            %init(SiriHooks);
            SiriLog(@"Siri.app hooks in (AFConnection %@)", NSClassFromString(@"AFConnection"));
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, LayoutNotified,
                                            CFSTR(kLayoutNotification), NULL,
                                            CFNotificationSuspensionBehaviorDeliverImmediately);
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                            SiriPreferencesChanged,
                                            CFSTR("com.local.siriglasstweak/preferencesChanged"), NULL,
                                            CFNotificationSuspensionBehaviorDeliverImmediately);
        } else {
            SpringBoardInit();
        }
        // Siri's answer from its commands, in either process.
        if (NSClassFromString(@"AFConnection")) %init(AceHooks);
    }
}

static void SpringBoardInit(void) {
    {
        SGDebug(@"tweak loading; SiriActivation preloaded=%d", NSClassFromString(@"SiriActivationService") != nil);
        dlopen("/System/Library/PrivateFrameworks/SiriUICore.framework/SiriUICore", RTLD_NOW);
        dlopen("/System/Library/PrivateFrameworks/SiriActivation.framework/SiriActivation", RTLD_NOW);
        %init(SpringBoardHooks);
        dlopen("/System/Library/PrivateFrameworks/AssistantServices.framework/AssistantServices", RTLD_NOW);
        // Siri.app writes its words here; make sure the directory is there.
        [NSFileManager.defaultManager createDirectoryAtPath:CaptionPaths().firstObject.stringByDeletingLastPathComponent
                                withIntermediateDirectories:YES attributes:nil error:nil];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, CaptionNotified,
                                        CFSTR(kCaptionNotification), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, CardNotified,
                                        CFSTR(kCardNotification), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, LockNotified,
                                        CFSTR("com.apple.springboard.lockcomplete"), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        SGDebug(@"after dlopen: SiriActivationService=%@ SimpleSource=%@ Container=%@",
                NSClassFromString(@"SiriActivationService"),
                NSClassFromString(@"SiriSimpleActivationSource"),
                NSClassFromString(@"SBSystemApertureContainerView"));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            EnsureSiriGestureInstalled();
            StartGestureWatch();
        });
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, PreferencesChanged,
                                        CFSTR("com.local.siriglasstweak/preferencesChanged"), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}
